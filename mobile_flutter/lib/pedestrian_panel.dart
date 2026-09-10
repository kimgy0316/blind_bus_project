import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'guide_ui.dart';
import 'walking_progress.dart';

class PedestrianPanel extends StatefulWidget {
  const PedestrianPanel({
    super.key,
    required this.route,
    required this.postJson,
  });
  final Map<String, dynamic> route;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  postJson;
  @override
  State<PedestrianPanel> createState() => _PedestrianPanelState();
}

class _PedestrianPanelState extends State<PedestrianPanel>
    with WidgetsBindingObserver {
  static const _location = MethodChannel('blind_bus_guide/location');
  static const _compass = MethodChannel('blind_bus_guide/compass');
  static const _tts = MethodChannel('blind_bus_guide/tts');
  static const _beacon = MethodChannel('blind_bus_guide/beacon');

  static const String _targetBeaconUuid =
      'E2C56DB5-DFFB-48D2-B060-D0F5A71096E0';
  static const int _targetBeaconMajor = 40011;
  static const int _targetBeaconMinor = 56412;

  Timer? _beaconTimer;

  bool _beaconStarted = false;
  bool _beaconArrived = false;
  bool _beaconCheckBusy = false;

  int _beaconCloseCount = 0;
  int? _lastBeaconRssi;

  Timer? _timer;
  WalkingProgress? _walk;
  bool _busy = false, _foreground = true, _speaking = false;
  String _message = '현재 위치에서 이동 경로를 찾고 있어요.';
  String? _error;
  String? _spoken;
  double? _accuracy, _heading;
  int _lastFix = 0, _generation = 0;
  DateTime? _lastRoute, _lastSpeech, _lastErrorSpeech;
  String? _lastErrorSpoken;
  bool get _visible =>
      mounted && _foreground && (ModalRoute.of(context)?.isCurrent ?? true);

  bool get _walkingOnly => widget.route['walkingOnly'] == true;

  String get _walkTargetLabel =>
      _walkingOnly ? '목적지' : '정류장';

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tick();
    });

    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _tick(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _generation++;
    if (_foreground) {
      _tick();
    } else {
      _stopCompass();
    }
  }

  Future<void> _stopCompass() async {
    try {
      await _location.invokeMethod(
        'cancel',
        {'owner': 'walking'},
      );
    } catch (_) {}

    try {
      await _compass.invokeMethod('stop');
    } catch (_) {}

    try {
      await _tts.invokeMethod(
        'stop',
        {'owner': 'walking'},
      );
    } catch (_) {}

    try {
      await _beacon.invokeMethod('stop');
    } catch (_) {}

    _beaconTimer?.cancel();
    _beaconTimer = null;

    _beaconStarted = false;
    _beaconCheckBusy = false;
    _beaconCloseCount = 0;
    _lastBeaconRssi = null;
  }

  Future<void> _say(String text) async {
    if (!_visible || _speaking) return;
    setState(() => _speaking = true);
    try {
      await _tts
          .invokeMethod('speak', {'text': text, 'owner': 'walking'})
          .timeout(const Duration(seconds: 40));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _speaking = false);
    }
  }

  Future<void> _startBeaconMonitoring() async {
    if (!_visible || _beaconStarted || _beaconArrived) {
      return;
    }

    // 시작 요청이 중복되지 않도록 먼저 true
    _beaconStarted = true;

    try {
      debugPrint('[BEACON_MONITOR] E7 연속 탐지 시작');

      await _beacon.invokeMethod('startMonitor');

      if (!_visible) {
        return;
      }

      _beaconTimer?.cancel();

      _beaconTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _checkBeacon(),
      );

      await _checkBeacon();
    } on PlatformException catch (error) {
      _beaconStarted = false;

      debugPrint(
        '[BEACON_ERROR] '
        'code=${error.code} '
        'message=${error.message}',
      );
    } catch (error) {
      _beaconStarted = false;

      debugPrint(
        '[BEACON_ERROR] $error',
      );
    }
  }

  Future<void> _checkBeacon() async {
    if (!_visible ||
        !_beaconStarted ||
        _beaconArrived ||
        _beaconCheckBusy) {
      return;
    }

    _beaconCheckBusy = true;

    try {
      final result =
          await _beacon.invokeMapMethod<String, dynamic>(
        'latest',
      );

      final beacons = result?['beacons'];

      if (beacons is! List) {
        return;
      }

      Map<dynamic, dynamic>? target;

      for (final item in beacons) {
        if (item is! Map) {
          continue;
        }

        final uuid =
            '${item['uuid'] ?? ''}'.toUpperCase();

        final major =
            (item['major'] as num?)?.toInt();

        final minor =
            (item['minor'] as num?)?.toInt();

        if (uuid == _targetBeaconUuid &&
            major == _targetBeaconMajor &&
            minor == _targetBeaconMinor) {
          target = item;
          break;
        }
      }

      if (target == null) {
        _lastBeaconRssi = null;
        _beaconCloseCount = 0;

        debugPrint(
          '[BEACON_E7] 현재 감지되지 않음',
        );

        return;
      }

      final rssi =
          (target['rssi'] as num?)?.toInt();

      _lastBeaconRssi = rssi;

      if (rssi != null && rssi >= -60) {
        _beaconCloseCount++;
      } else {
        _beaconCloseCount = 0;
      }

      debugPrint(
        '[BEACON_E7] '
        'rssi=$rssi '
        'closeCount=$_beaconCloseCount',
      );

      if (_beaconCloseCount >= 2) {
        await _onBeaconArrival();
      }
    } on PlatformException catch (error) {
      debugPrint(
        '[BEACON_ERROR] '
        '${error.code} ${error.message}',
      );
    } finally {
      _beaconCheckBusy = false;
    }
  }

  Future<void> _onBeaconArrival() async {
    if (_beaconArrived) {
      return;
    }

    _beaconArrived = true;

    _beaconTimer?.cancel();
    _beaconTimer = null;

    try {
      await _beacon.invokeMethod('stop');
    } catch (_) {}

    debugPrint(
      '[BEACON_ARRIVAL] 정류장 도착 확인',
    );

    if (mounted) {
      setState(() {
        _error = null;
        _message =
            '정류장 비콘이 확인되었습니다. 정류장에 도착했습니다.';
      });
    }

    await _say(
      '정류장 비콘이 확인되었습니다. 정류장에 도착했습니다.',
    );
  }

  Future<void> _tick() async {
    if (!_visible) {
      _stopCompass();
      return;
    }
    if (_busy) return;
    _busy = true;
    final generation = _generation;
    try {
      final raw = await _location
          .invokeMapMethod<String, dynamic>('current', {
            'maxAgeMs': 5000,
            'owner': 'walking',
          })
          .timeout(const Duration(seconds: 32));
      if (!_visible || generation != _generation) return;
      if (raw == null) throw const FormatException('위치를 받지 못했습니다.');
      final fix = WalkFix(
        (raw['longitude'] as num).toDouble(),
        (raw['latitude'] as num).toDouble(),
        (raw['accuracy'] as num).toDouble(),
        (raw['timestamp'] as num).toInt(),
      );
      debugPrint('[WALK_LOCATION] accuracy=${fix.accuracy.toStringAsFixed(1)} ageMs=${raw['ageMs']} provider=${raw['provider']}');
      if (!fix.reliable ||
          DateTime.now().millisecondsSinceEpoch - fix.timestamp > 5000 ||
          fix.timestamp > DateTime.now().millisecondsSinceEpoch + 2000) {
        setState(() {
          _accuracy = fix.accuracy;
          _heading = null;
          _error = '정확한 위치를 확인하고 있어요. 회전 안내는 위치가 안정되면 자동으로 이어집니다.';
        });
        return;
      }
      if (fix.timestamp <= _lastFix) return;
      _lastFix = fix.timestamp;
      _accuracy = fix.accuracy;
      if (_walk == null) {
        // Automatic failures are rate limited; the retry button is immediate.
        if (_lastRoute == null ||
            DateTime.now().difference(_lastRoute!).inSeconds >= 30) {
          await _load(fix);
        }
        if (!_visible || generation != _generation) return;
      }
      final walk = _walk;
      if (walk == null) return;
      if (!walk.update(fix)) {
        setState(() {
          _heading = null;
          _error = '현재 위치와 보행 경로를 확인하고 있어요. 회전 안내를 잠시 멈춥니다.';
        });
        return;
      }
      if (walk.needsReroute) {
        setState(() {
          _heading = null;
          _message = '경로를 벗어났어요. 현재 위치에서 다시 찾고 있어요.';
        });
        if (_lastRoute == null ||
            DateTime.now().difference(_lastRoute!).inSeconds >= 30) {
          await _load(fix);
        }
        return;
      }
      if (walk.offRoute) {
        setState(() {
          _heading = null;
          _error = '경로와 현재 위치가 달라요. 위치를 다시 확인하고 있어요.';
        });
        return;
      }
      if (!_walkingOnly &&
          walk.remaining <= 25 &&
          !_beaconStarted &&
          !_beaconArrived) {

        debugPrint(
          '[BEACON_TRIGGER] 정류장까지 '
          '${walk.remaining.toStringAsFixed(1)}m '
          '- 비콘 연속 탐지 시작',
        );

        unawaited(
          _startBeaconMonitoring(),
        );
      }
      double? heading;
      try {
        final sensor = await _compass.invokeMapMethod<String, dynamic>(
          'current',
          {'latitude': fix.lat, 'longitude': fix.lon},
        );
        heading = (sensor?['heading'] as num?)?.toDouble();
      } catch (_) {}
      if (!_visible || generation != _generation) return;
      final instruction = walk.next;
      final distance = (walk.nextDistance / 5).round() * 5;

      debugPrint(
        '[WALK_PROGRESS] '
        'lat=${fix.lat.toStringAsFixed(7)} '
        'lon=${fix.lon.toStringAsFixed(7)} '
        'progress=${walk.progress.toStringAsFixed(1)}m '
        'remaining=${walk.remaining.toStringAsFixed(1)}m '
        'next=${walk.nextDistance.toStringAsFixed(1)}m '
        'action=${instruction.action} '
        'crossTrack=${walk.crossTrack.toStringAsFixed(1)}m '
        'offRoute=${walk.offRoute} '
        'reroute=${walk.needsReroute} '
        'nearStop=${walk.nearStop}',
      );
      final text = walk.nearStop
          ? (_walkingOnly
              ? '목적지 근처입니다.'
              : '정류장 근처입니다. 정확한 정류장 도착은 비콘으로 확인합니다.')
          : instruction.turn == 201
              ? '$_walkTargetLabel까지 경로를 따라 약 '
                '${walk.remaining.ceil()}미터 남았어요.'
              : '약 ${math.max(5, distance)}미터 앞 '
                '${instruction.action} 안내 지점입니다.';
      final start = walk.instructions.isEmpty
          ? ''
          : walk.instructions.first.description;
      final message = walk.progress < 10 && !walk.nearStop && start.isNotEmpty
          ? '$start\n$text'
          : text;
      setState(() {
        _error = null;
        _message = message;
        _heading = heading;
      });
      final band = walk.nearStop
          ? 'nearStop'
          : '${instruction.offset}:${walk.nextDistance <= 15 ? 'near' : 'ahead'}';
      if (_spoken != band &&
          !_speaking &&
          (_lastSpeech == null ||
              DateTime.now().difference(_lastSpeech!).inSeconds >= 8)) {
        _spoken = band;
        _lastSpeech = DateTime.now();
        final crossing = instruction.turn >= 211 && instruction.turn <= 217
            ? ' 신호와 주변 상황을 확인해주세요.'
            : '';
        unawaited(_say('$message$crossing'));
      }
    } on PlatformException catch (error) {
      debugPrint('[WALK_LOCATION_ERROR] ${error.code}');
      if (_visible)
        setState(() {
          _heading = null;
          _error = error.code == 'LOCATION_TIMEOUT'
              ? '정확한 GPS 위치를 기다리고 있어요. 위치가 잡히면 자동으로 안내합니다.'
              : '위치를 확인하지 못했어요. 위치 권한과 GPS를 확인해주세요.';
        });
    } catch (error) {
      if (_visible)
        setState(() {
          _heading = null;
          _error = error is FormatException
              ? error.message.toString()
              : error.toString().contains('TMAP')
              ? '서버의 TMAP 앱 키, API 이용 권한과 조회 한도를 확인해주세요.'
              : '도보 경로를 받지 못했어요. 서버 연결을 확인하고 다시 시도해주세요.';
        });
    } finally {
      _busy = false;
      if (_visible && _error != null && _lastErrorSpoken != _error && !_speaking &&
          (_lastErrorSpeech == null || DateTime.now().difference(_lastErrorSpeech!).inSeconds >= 60)) {
        _lastErrorSpoken = _error;
        _lastErrorSpeech = DateTime.now();
        unawaited(_say(_error!));
      }
    }
  }

  Future<void> _load(WalkFix fix) async {
    _lastRoute = DateTime.now();
    final generation = _generation;

    final rawX = _walkingOnly
        ? widget.route['destinationX']
        : widget.route['boardingX'];

    final rawY = _walkingOnly
        ? widget.route['destinationY']
        : widget.route['boardingY'];

    final x = double.tryParse('$rawX');
    final y = double.tryParse('$rawY');

    if (x == null ||
        y == null ||
        !x.isFinite ||
        !y.isFinite) {
      throw FormatException(
        _walkingOnly
            ? '목적지 좌표가 없습니다.'
            : '정류장 좌표가 없습니다. 서버를 업데이트한 뒤 경로를 다시 검색해주세요.',
      );
    }

    final nodeId = widget.route['nodeId'];

    final requestBody = <String, dynamic>{
      'startX': fix.lon,
      'startY': fix.lat,
      'endX': x,
      'endY': y,
    };

    if (nodeId != null) {
      requestBody['nodeId'] = nodeId;
    }

    final data = await widget.postJson(
      '/pedestrian-route',
      requestBody,
    );

    if (!_visible || generation != _generation) {
      return;
    }

    if (data['ok'] != true) {
      throw FormatException(
        '${data['error'] ?? '보행 경로를 받지 못했습니다.'}',
      );
    }

    if (nodeId != null &&
        data['nodeId'] != nodeId) {
      throw FormatException(
        _walkingOnly
            ? '다른 목적지 경로를 받았습니다.'
            : '다른 정류장 경로를 받았습니다.',
      );
    }

    setState(() {
      _walk = WalkingProgress(data);
      _spoken = null;
      _lastSpeech = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    _generation++;

    _timer?.cancel();
    _beaconTimer?.cancel();

    _stopCompass();

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final walk = _walk;
    final angle = walk == null || _heading == null
        ? null
        : ((walk.bearing - _heading! + 540) % 360 - 180);
    return GuideCard(
      color: GuideColors.soft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GuideHeading(
            _walkingOnly
                ? '목적지까지 도보 안내'
                : '정류장까지 도보 안내',
          ),
          const SizedBox(height: 16),
          if (walk != null)
            Text(
              '약 ${walk.remaining.ceil()}m',
              style: const TextStyle(
                fontSize: 42,
                fontWeight: FontWeight.w900,
                color: GuideColors.primary,
              ),
            ),
          if (angle != null && _error == null) ...[
            Center(
              child: Semantics(
                label: '휴대폰 위쪽 기준 경로 방향 ${angle.round()}도',
                child: Transform.rotate(
                  angle: angle * math.pi / 180,
                  child: const Icon(
                    Icons.navigation,
                    size: 72,
                    color: GuideColors.primary,
                  ),
                ),
              ),
            ),
            const Text('휴대폰 위쪽을 기준으로 경로 방향을 표시해요.'),
            const SizedBox(height: 12),
          ],
          Text(_error ?? _message),
          if (_error != null && walk != null)
            Text('마지막 안내 · $_message', style: Theme.of(context).textTheme.bodySmall),
          if (_accuracy != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '위치 오차 약 ${_accuracy!.round()}m',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_error != null)
            GuideAction(
              '도보 안내 다시 연결',
              icon: Icons.refresh,
              onPressed: () {
                _lastRoute = null;
                _lastFix = 0;
                _tick();
              },
            ),
          GuideAction(
            '길 안내 다시 듣기',
            icon: Icons.volume_up,
            secondary: true,
            onPressed: _speaking ? null : () => _say(_error ?? _message),
          ),
        ],
      ),
    );
  }
}