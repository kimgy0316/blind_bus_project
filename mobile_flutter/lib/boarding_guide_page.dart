import 'pedestrian_panel.dart';
import 'guide_ui.dart';
import 'live_bus_page.dart';
import 'boarding_status_panel.dart';
import 'driver_request_page.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'boarding_flow.dart';

typedef GetBoardingJson =
    Future<Map<String, dynamic>> Function(String, Map<String, String>);
typedef PostBoardingJson =
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>);

class BoardingGuidePage extends StatefulWidget {
  const BoardingGuidePage({
    super.key,
    required this.route,
    required this.getJson,
    required this.postJson,
  });
  final Map<String, dynamic> route;
  final GetBoardingJson getJson;
  final PostBoardingJson postJson;

  @override
  State<BoardingGuidePage> createState() => _BoardingGuidePageState();
}

class _BoardingGuidePageState extends State<BoardingGuidePage>
    with WidgetsBindingObserver {
  static const _tts = MethodChannel('blind_bus_guide/tts');
  static const _speech = MethodChannel('blind_bus_guide/speech');
  // Native 비콘/카메라 구현이 이벤트를 공급할 연결 지점입니다.
  static const _events = EventChannel('blind_bus_guide/boarding_events');
  static const _demo = bool.fromEnvironment(
    'BOARDING_DEMO',
    defaultValue: false,
  );
  final String _session = DateTime.now().microsecondsSinceEpoch.toString();
  BoardingPhase _phase = BoardingPhase.walking;
  StreamSubscription<dynamic>? _subscription;
  Timer? _poll;
  Map<String, dynamic>? _driverRequest;
  bool _closed = false;
  bool _demoStop = false;
  bool _listening = false;
  bool _refreshing = false;
  bool _speaking = false;
  int? _seconds;
  DateTime? _checkedAt;
  String _message = '';
  String _driverStatus = '탑승 의사 확인 전';
  String _sensorStatus = '비콘·카메라 연결 확인 중';
  String _arrivalStatus = '정류장 도착 후 다시 조회합니다.';

  String get _node => '${widget.route['nodeId'] ?? ''}';
  String get _routeNo => '${widget.route['routeNo'] ?? ''}';
  String get _stop => '${widget.route['boardingStop'] ?? '탑승 정류장'}';
  bool get _active => mounted && !_closed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final steps = widget.route['steps'] as List<dynamic>? ?? [];
    _message = steps.isEmpty
        ? '$_stop 정류장까지 이동하세요.'
        : '${steps.first['speech']}';
    _subscription = _events
        .receiveBroadcastStream({
          'sessionId': _session,
          'nodeId': _node,
          'routeNo': _routeNo,
        })
        .listen(
          _sensorEvent,
          onError: (Object error) {
            if (_active) setState(() => _sensorStatus = '비콘·카메라 미연결');
          },
        );
    // PedestrianPanel speaks the actual TMAP route when ready.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _phase == BoardingPhase.waiting)
      _refresh();
  }

  Future<void> _say(String message) async {
    if (!_active) return;
    setState(() {
      _message = message;
      _speaking = true;
    });
    try {
      await _tts
          .invokeMethod('speak', {'text': message})
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      // 음성 출력 실패 시에도 문장과 응답 버튼은 유지합니다.
    } finally {
      if (_active) setState(() => _speaking = false);
    }
  }

  void _sensorEvent(dynamic data) {
    if (!_active || data is! Map || data['sessionId'] != _session) return;
    setState(() => _sensorStatus = '센서 이벤트 수신 중');
    if (data['type'] == 'stopBeacon' && data['nodeId'] == _node) {
      _onStop();
    } else if (_phase == BoardingPhase.waiting &&
        isMatchingArrival(data, _session, _node, _routeNo)) {
      _onBusArrival();
    }
  }

  Future<void> _onStop({bool simulated = false}) async {
    if (!_active || _phase != BoardingPhase.walking) return;
    if (_node.isEmpty || _routeNo.isEmpty) {
      await _say('정류장 또는 노선 정보가 없습니다. 서버를 업데이트한 뒤 경로를 다시 검색해주세요.');
      return;
    }
    setState(() {
      _phase = BoardingPhase.refreshing;
      _demoStop = simulated;
    });
    await _say(
      '${simulated ? '시연입니다. ' : ''}$_stop 정류장에 도착했습니다. 최신 버스 도착정보를 조회합니다.',
    );
    if (_active) await _refresh(ask: true);
  }

  Future<void> _refresh({bool ask = false}) async {
    if (!_active || _refreshing || !(ModalRoute.of(context)?.isCurrent ?? true))
      return;
    _refreshing = true;
    try {
      final data = await widget.getJson('/arrivals', {
        'nodeId': _node,
        'routeNo': _routeNo,
        'cityCode': '${widget.route['cityCode'] ?? '33010'}',
      });
      if (!_active ||
          _phase == BoardingPhase.arrived ||
          _phase == BoardingPhase.riding ||
          _phase == BoardingPhase.completed)
        return;
      final arrival = data['arrival'];
      if (data['ok'] != true ||
          data['nodeId'] != _node ||
          data['routeNo'] != _routeNo) {
        throw StateError('도착정보 응답이 선택한 정류장·노선과 다릅니다.');
      }
      final value = arrival is Map && arrival['route_no'] == _routeNo
          ? int.tryParse('${arrival['arrival_seconds']}')
          : null;
      setState(() {
        _seconds = value;
        _checkedAt = DateTime.now();
        _arrivalStatus = value == null ? '현재 도착 예정 정보 없음' : _eta(value);
        if (ask)
          _phase = value == null
              ? BoardingPhase.refreshing
              : BoardingPhase.asking;
      });
      if (ask) {
        if (value == null) {
          await _say('현재 $_routeNo번 도착정보가 없습니다. 다시 조회하거나 다른 경로를 선택해주세요.');
        } else {
          await _ask();
        }
      }
    } catch (error) {
      if (!_active) return;
      setState(() {
        _seconds = null;
        _checkedAt = null;
        _arrivalStatus = '조회 실패 — 이전 시간은 사용하지 않습니다.';
        if (ask) _phase = BoardingPhase.refreshing;
      });
      if (ask) await _say('버스 도착정보 조회에 실패했습니다. 다시 조회해주세요.');
    } finally {
      if (_active) {
        setState(() => _refreshing = false);
      } else {
        _refreshing = false;
      }
    }
  }

  String _eta(int seconds) =>
      seconds < 60 ? '1분 이내 도착 예정' : '약 ${(seconds / 60).ceil()}분 후 도착 예정';

  Future<void> _ask() async {
    final seconds = _seconds;
    if (!_active || seconds == null || _phase != BoardingPhase.asking) return;
    await _say(
      '$_routeNo번 버스가 ${_eta(seconds)}입니다. '
      '${seconds < 180 ? '도착까지 시간이 짧습니다. ' : ''}'
      '이 버스를 타시겠습니까? 예 또는 아니요로 말씀해주세요.',
    );
    if (_active) await _listen();
  }

  Future<void> _listen() async {
    if (!_active || _listening || _speaking || _phase != BoardingPhase.asking)
      return;
    setState(() => _listening = true);
    BoardingAnswer answer = BoardingAnswer.unknown;
    try {
      final result = await _speech
          .invokeMethod<String>('listen', {
            'prompt': '$_routeNo번 버스를 타시겠습니까? 예 / 아니요',
          })
          .timeout(const Duration(seconds: 30));
      answer = parseBoardingAnswer(result ?? '');
    } catch (_) {
      // 인식 실패는 동의로 간주하지 않습니다.
    } finally {
      if (_active) setState(() => _listening = false);
    }
    if (!_active || _phase != BoardingPhase.asking) return;
    if (answer == BoardingAnswer.yes) {
      await _accept();
    } else if (answer == BoardingAnswer.no) {
      _leave();
    } else {
      await _say('응답을 확인하지 못했습니다. 음성으로 다시 답하거나 예, 아니요 버튼을 눌러주세요.');
    }
  }

  Future<void> _testRequest() async {
    final accepted = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => DriverRequestPage(
          route: widget.route,
          getJson: widget.getJson,
          postJson: widget.postJson,
          isTest: true,
        ),
      ),
    );
    if (!_active || accepted == null) return;
    _poll?.cancel();
    setState(() {
      _driverRequest = accepted;
      _phase = BoardingPhase.waiting;
      _driverStatus = '테스트 요청 접수';
      _message = '테스트 기사님께 탑승 요청을 보냈습니다. 확인을 기다려주세요.';
    });
  }

  Future<void> _accept() async {
    if (!_active || _phase != BoardingPhase.asking || _listening || _speaking)
      return;
    if (_checkedAt == null ||
        DateTime.now().difference(_checkedAt!).inSeconds > 60) {
      setState(() => _phase = BoardingPhase.refreshing);
      // 오랜 시간이 지난 응답은 최신 시간을 들려준 뒤 다시 동의를 받습니다.
      await _refresh(ask: true);
      return;
    }
    setState(() {
      _phase = BoardingPhase.notifying;
      _driverStatus = '지원 요청 중';
    });
    final accepted = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => DriverRequestPage(
          getJson: widget.getJson,
          postJson: widget.postJson,
          route: widget.route,
          isTest: _demoStop,
          autoSend: true,
        ),
      ),
    );
    if (!_active) return;
    if (accepted == null) {
      setState(() {
        _phase = BoardingPhase.asking;
        _driverStatus = '서버 접수 미확인';
      });
      return;
    }
    _driverRequest = accepted;
    _driverStatus = '서버 접수 완료';
    if (!_active) return;
    setState(() => _phase = BoardingPhase.waiting);
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    await _say('기사님께 탑승 요청을 보냈습니다. 확인을 기다려주세요.');
  }

  Future<void> _onBusArrival({bool simulated = false}) async {
    if (!_active || _phase != BoardingPhase.waiting) return;
    _poll?.cancel();
    setState(() {
      _phase = BoardingPhase.arrived;
    });
    await _say(
      '${simulated ? '도착 감지 시연입니다. ' : ''}'
      '탑승하실 $_routeNo번 버스가 도착했습니다. 기사님의 탑승 확인을 기다려주세요.',
    );
  }

  void _leave() {
    if (!_active) return;
    _closed = true;
    _poll?.cancel();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _closed = true;
    _poll?.cancel();
    _subscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_phase) {
      BoardingPhase.walking => '정류장으로 이동',
      BoardingPhase.refreshing => '도착정보 확인',
      BoardingPhase.asking => '탑승 선택',
      BoardingPhase.notifying => '기사님께 요청',
      BoardingPhase.waiting => '버스 기다리기',
      BoardingPhase.arrived => '버스 도착',
      BoardingPhase.riding => '버스로 이동 중',
      BoardingPhase.completed => '하차 완료',
    };
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: guideToolbarHeight(context),
        title: Text(title),
        actions: [
          PopupMenuButton<String>(
            tooltip: '테스트 및 연결 확인',
            icon: const Icon(Icons.more_horiz),
            onSelected: (value) {
              if (value == 'test') _testRequest();
              if (value == 'stop') _onStop(simulated: true);
              if (value == 'arrival') _onBusArrival(simulated: true);
              if (value == 'live')
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LiveBusPage(
                      route: widget.route,
                      getJson: widget.getJson,
                    ),
                  ),
                );
              if (value == 'driver')
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DriverRequestPage(
                      route: widget.route,
                      getJson: widget.getJson,
                      postJson: widget.postJson,
                      previewOnly: true,
                    ),
                  ),
                );
              if (value == 'sensor')
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('연결 상태'),
                    content: Text(
                      '자동 감지: $_sensorStatus\n기사 요청: $_driverStatus',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('닫기'),
                      ),
                    ],
                  ),
                );
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'live', child: Text('실제 운행 정보')),
              const PopupMenuItem(value: 'driver', child: Text('차량·기사 연결 확인')),
              const PopupMenuItem(value: 'sensor', child: Text('연결 상태')),
              if (_driverRequest == null)
                const PopupMenuItem(value: 'test', child: Text('테스트: 기사앱 연결')),
              if (_demo && _phase == BoardingPhase.walking)
                const PopupMenuItem(value: 'stop', child: Text('테스트: 정류장 도착')),
              if (_demo && _phase == BoardingPhase.waiting)
                const PopupMenuItem(
                  value: 'arrival',
                  child: Text('테스트: 버스 도착'),
                ),
            ],
          ),
        ],
      ),
      body: GuideBody(
        children: [
          if (_driverRequest?['isTest'] == true || _demoStop)
            const GuideTestBadge(),
          Text(
            '$_routeNo번',
            style: const TextStyle(
              fontSize: 44,
              color: GuideColors.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 16),
          if (_phase == BoardingPhase.walking) ...[
            PedestrianPanel(route: widget.route, postJson: widget.postJson),
            const SizedBox(height: 16),
          ],
          if (_phase != BoardingPhase.riding &&
              _phase != BoardingPhase.completed) ...[
            GuideCard(
              color: GuideColors.soft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _phase == BoardingPhase.walking
                        ? Icons.directions_walk
                        : Icons.directions_bus,
                    size: 40,
                    color: GuideColors.primary,
                  ),
                  const SizedBox(height: 16),
                  GuideHeading(_stop),
                  const SizedBox(height: 12),
                  if ((_driverRequest == null &&
                          _phase != BoardingPhase.walking) ||
                      _phase == BoardingPhase.arrived)
                    Text(_message),
                  if (_phase == BoardingPhase.walking) ...[
                    const SizedBox(height: 16),
                    Text(
                      _sensorStatus.contains('미연결')
                          ? '정류장 자동 감지가 연결되지 않았습니다.'
                          : '정류장 도착 확인을 기다리고 있어요.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_checkedAt != null)
              GuideCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '버스 도착 예정',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    GuideHeading(_arrivalStatus),
                    Text(
                      '${_checkedAt!.toLocal().toString().substring(11, 19)} 확인',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
          ],
          if (_driverRequest != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: BoardingStatusPanel(
                request: _driverRequest!,
                postJson: widget.postJson,
                onAlighted: () {
                  if (!_active) return;
                  _poll?.cancel();
                  setState(() {
                    _phase = BoardingPhase.completed;
                    _checkedAt = null;
                    _arrivalStatus = '하차 완료';
                    _driverStatus = '기사 하차 완료 확인';
                    _message = '하차가 확인되었습니다. 이 버스의 안내를 마칩니다.';
                  });
                },
                onBoarded: () {
                  if (!_active) return;
                  _poll?.cancel();
                  setState(() {
                    _phase = BoardingPhase.riding;
                    _driverStatus = '기사 탑승 완료 확인';
                    _arrivalStatus = '탑승 완료';
                    _message = '${widget.route['dropoffStop']}에서 하차합니다.';
                  });
                },
              ),
            ),
          const SizedBox(height: 20),
          if (_phase == BoardingPhase.refreshing)
            GuideAction(
              _refreshing ? '도착정보 확인 중' : '도착정보 다시 확인',
              onPressed: _refreshing || _speaking
                  ? null
                  : () => _refresh(ask: true),
              icon: Icons.refresh,
            ),
          if (_phase == BoardingPhase.asking) ...[
            if (_listening) const Text('답변을 듣고 있어요…'),
            GuideAction(
              '네, 탈게요',
              onPressed: _listening || _speaking ? null : _accept,
              icon: Icons.check,
            ),
            GuideAction(
              '다른 버스 선택',
              onPressed: _listening || _speaking ? null : _leave,
              secondary: true,
            ),
            if (!_listening)
              GuideAction(
                '음성으로 답하기',
                onPressed: _speaking ? null : _listen,
                icon: Icons.mic,
                secondary: true,
              ),
          ],
          if (_driverRequest == null &&
              _phase != BoardingPhase.notifying &&
              _phase != BoardingPhase.walking)
            GuideAction(
              '안내 다시 듣기',
              onPressed: _speaking || _listening ? null : () => _say(_message),
              icon: Icons.volume_up,
              secondary: true,
            ),
          if (_phase == BoardingPhase.completed)
            GuideAction('경로 화면으로 돌아가기', onPressed: _leave, icon: Icons.check),
        ],
      ),
    );
  }
}
