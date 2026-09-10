import 'guide_ui.dart';
import 'boarding_status_panel.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'boarding_guide_page.dart';

class DriverRequestPage extends StatefulWidget {
  const DriverRequestPage({
    super.key,
    required this.getJson,
    required this.postJson,
    this.route,
    this.isTest = false,
    this.previewOnly = false,
    this.autoSend = false,
  });
  final GetBoardingJson getJson;
  final PostBoardingJson postJson;
  final Map<String, dynamic>? route;
  final bool isTest;
  final bool previewOnly;
  // Set only after the boarding guide has received explicit boarding consent.
  final bool autoSend;
  @override
  State<DriverRequestPage> createState() => _DriverRequestPageState();
}

class _DriverRequestPageState extends State<DriverRequestPage> {
  final routeNo = TextEditingController();
  final stop = TextEditingController();
  final dropoff = TextEditingController();
  final requestId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  final passengerToken = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  List<dynamic> vehicles = [];
  String? selected;
  String? matchToken;
  Map<String, dynamic>? vehicleMatch;
  bool busy = false, sent = false;
  bool allTest = false;
  bool autoSendAttempted = false;
  Map<String, dynamic>? submitted;
  String message = '차량 목록을 조회하고 탑승할 차량을 선택하세요.';
  @override
  void initState() {
    super.initState();
    allTest = widget.isTest;
    routeNo.text = '${widget.route?['routeNo'] ?? '747'}';
    stop.text = '${widget.route?['boardingStop'] ?? '테스트 승차 정류장'}';
    dropoff.text = '${widget.route?['dropoffStop'] ?? '테스트 하차 정류장'}';
    if (allTest) {
      WidgetsBinding.instance.addPostFrameCallback((_) => fetch());
    }
    if (!widget.isTest) {
      message = '도착 예정 차량과 기사 앱 등록 정보를 확인합니다.';
      WidgetsBinding.instance.addPostFrameCallback((_) => fetch());
    }
  }

  Future<void> fetch() async {
    if (busy) return;
    setState(() {
      busy = true;
      selected = null;
      vehicles = [];
      matchToken = null;
      vehicleMatch = null;
    });
    try {
      if (allTest) {
        if (routeNo.text.trim().isEmpty) throw StateError('버스 번호를 입력해주세요.');
        Map<String, dynamic>? live;
        if (widget.route != null) {
          try {
            final result = await widget.getJson('/driver/matched-vehicle', {
              'testMode': 'true',
              'routeNo': routeNo.text.trim(),
              'nodeId': '${widget.route?['nodeId'] ?? ''}',
              'routeId': '${widget.route?['routeId'] ?? ''}',
              'cityCode': '${widget.route?['cityCode'] ?? '33010'}',
            });
            if (result['match'] is Map)
              live = Map<String, dynamic>.from(result['match'] as Map);
            matchToken = result['matchToken'] as String?;
          } catch (_) {
            /* An explicitly labelled test may run without a live vehicle. */
          }
        }
        if (!mounted) return;
        setState(() {
          vehicleMatch = live;
          selected =
              live?['vehicleNo'] as String? ?? 'TEST-${routeNo.text.trim()}';
          vehicles = [
            {'vehicleNo': selected, 'routeNo': routeNo.text.trim()},
          ];
          message = live == null
              ? '테스트 기사앱으로 연결합니다. 실차 번호판은 확인되지 않아 차량 미지정으로 시험합니다. 차량 등록은 필요 없습니다.'
              : '조회된 차량번호를 시험에 사용합니다. 실제 기사 등록 없이 테스트 기사앱에서 요청을 처리합니다.';
        });
        return;
      }
      final data = await widget.getJson(
        widget.isTest ? '/driver/vehicles' : '/driver/matched-vehicle',
        {
          'routeNo': routeNo.text.trim(),
          if (!widget.isTest) 'nodeId': '${widget.route?['nodeId'] ?? ''}',
          if (!widget.isTest) 'routeId': '${widget.route?['routeId'] ?? ''}',
          if (!widget.isTest)
            'cityCode': '${widget.route?['cityCode'] ?? '33010'}',
        },
      );
      if (!mounted) return;
      setState(() {
        vehicles = data['vehicles'] as List<dynamic>;
        if (!widget.isTest) {
          vehicleMatch = data['match'] is Map
              ? Map<String, dynamic>.from(data['match'] as Map)
              : null;
          matchToken = data['matchToken'] as String?;
          if (vehicles.length == 1 && matchToken != null)
            selected = '${vehicles.first['vehicleNo']}';
          message = '${data['message'] ?? '차량 연결 정보를 확인하지 못했습니다.'}';
          return;
        }
        message = vehicles.isEmpty
            ? '등록된 차량이 없습니다. 기사 앱에서 같은 버스 번호로 요청 수신 화면을 먼저 열어주세요.'
            : '실제 도착 차량을 자동 확인한 목록이 아닙니다. 연결할 차량번호를 선택하세요.';
      });
    } catch (e) {
      if (mounted) setState(() => message = '조회 실패: $e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (widget.autoSend &&
            !widget.previewOnly &&
            !autoSendAttempted &&
            selected != null) {
          autoSendAttempted = true;
          await send();
        }
      }
    }
  }

  Future<void> send() async {
    if (widget.previewOnly || busy || sent || selected == null) return;
    if (stop.text.trim().isEmpty || dropoff.text.trim().isEmpty) {
      setState(() => message = '승차·하차 정류장을 입력해주세요.');
      return;
    }
    setState(() => busy = true);
    submitted ??= {
      'passengerToken': passengerToken,
      'requestId': requestId,
      'consent': true,
      'vehicleNo': selected,
      'routeNo': routeNo.text.trim(),
      'boardingStop': stop.text.trim(),
      'dropoffStop': dropoff.text.trim(),
      'nodeId': '${widget.route?['nodeId'] ?? 'TEST-STOP'}',
      'isTest': widget.isTest || allTest,
      if (allTest) 'testAllVehicles': true,
      if (allTest && matchToken != null) 'trackingToken': matchToken,
      if (widget.route?['dropoffNodeId'] != null)
        'dropoffNodeId': '${widget.route!['dropoffNodeId']}',
      if (!widget.isTest && !allTest) 'matchToken': matchToken,
    };
    try {
      final data = await widget.postJson('/driver-notifications', submitted!);
      if (data['ok'] != true || data['status'] != 'queued')
        throw StateError('접수 확인 실패');
      if (!mounted) return;
      if (widget.route != null) {
        Navigator.pop(context, submitted);
        return;
      }
      setState(() {
        sent = true;
        message = '서버 접수 완료. 기사 앱의 요청 수신 화면에서 확인하세요. 기사 확인 완료를 뜻하지는 않습니다.';
      });
    } catch (e) {
      if (mounted)
        setState(() {
          message = '접수 확인 실패: $e';
          // Only a definitive server rejection may release the idempotent retry body.
          if ('$e'.contains('만료') ||
              '$e'.contains('바뀌었습니다') ||
              '$e'.contains('다릅니다')) {
            submitted = null;
            selected = null;
            matchToken = null;
            vehicles = [];
            message += '\n도착 차량 다시 확인을 눌러주세요.';
          } else {
            message += '\n통신 결과가 불확실하면 동일 요청으로 다시 시도해주세요.';
          }
        });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    routeNo.dispose();
    stop.dispose();
    dropoff.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
        toolbarHeight: guideToolbarHeight(context),
      title: Text(
        widget.previewOnly
            ? '연결 확인'
            : widget.isTest
            ? '테스트 탑승 요청'
            : '탑승 지원 요청',
      ),
    ),
    body: GuideBody(
      children: [
        if (allTest || widget.isTest) const GuideTestBadge(),
        if (sent && submitted != null)
          BoardingStatusPanel(request: submitted!, postJson: widget.postJson),
        if (widget.route != null)
          GuideCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${routeNo.text}번',
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    color: GuideColors.primary,
                  ),
                ),
                GuideFact('타는 곳', stop.text),
                GuideFact('내리는 곳', dropoff.text),
                if (selected != null) GuideFact('연결할 차량', selected!),
              ],
            ),
          ),
        if (widget.route == null) ...[
          TextField(
            controller: routeNo,
            enabled: !busy && submitted == null,
            decoration: const InputDecoration(labelText: '버스 번호'),
            onChanged: (_) => setState(() {
              vehicles = [];
              selected = null;
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: stop,
            enabled: !busy && submitted == null,
            decoration: const InputDecoration(labelText: '승차 정류장'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: dropoff,
            enabled: !busy && submitted == null,
            decoration: const InputDecoration(labelText: '하차 정류장'),
          ),
        ],
        const SizedBox(height: 20),
        if (busy) const LinearProgressIndicator(),
        if (!sent)
          Text(
            busy
                ? '차량과 연결을 확인하고 있어요…'
                : selected != null
                ? (allTest
                      ? '테스트 기사앱에 탑승 지원을 요청합니다.'
                      : '이 차량의 기사님께 탑승 지원을 요청합니다.')
                : message,
          ),
        if (submitted != null && !sent && !busy) Text(message),
        if (selected == null || widget.route == null || widget.previewOnly)
          GuideAction(
            '차량 다시 확인',
            onPressed: busy || submitted != null ? null : fetch,
            icon: Icons.refresh,
            secondary: true,
          ),
        if (vehicles.length > 1)
          for (final v in vehicles)
            GuideAction(
              '${selected == v['vehicleNo'] ? '선택됨 · ' : ''}${v['vehicleNo']}',
              onPressed: busy || submitted != null
                  ? null
                  : () => setState(() => selected = v['vehicleNo'] as String),
              secondary: true,
              icon: Icons.directions_bus,
            ),
        const SizedBox(height: 16),
        if (!widget.previewOnly && !sent)
          GuideAction(
            submitted != null ? '요청 다시 보내기' : '탑승 지원 요청하기',
            onPressed: busy || selected == null ? null : send,
            icon: Icons.support_agent,
          ),
        if (widget.previewOnly) const Text('지금은 연결 정보만 확인합니다. 요청은 전송하지 않습니다.'),
        const SizedBox(height: 24),
        ExpansionTile(
          title: const Text('테스트 및 상세 정보'),
          tilePadding: EdgeInsets.zero,
          children: [
            SwitchListTile(
              title: const Text('테스트 기사앱 사용'),
              subtitle: const Text('실제 기사에게 전송되지 않습니다.'),
              value: allTest,
              onChanged: busy || submitted != null
                  ? null
                  : (value) {
                      setState(() {
                        allTest = value;
                        selected = null;
                        vehicles = [];
                      });
                      fetch();
                    },
            ),
            Text(message),
            if (vehicleMatch != null)
              Text(
                '차량 ${vehicleMatch!['vehicleNo']} · 정류장 ${vehicleMatch!['stopNumber']}\n조회 ${vehicleMatch!['checkedAt']}',
              ),
          ],
        ),
      ],
    ),
  );
}
