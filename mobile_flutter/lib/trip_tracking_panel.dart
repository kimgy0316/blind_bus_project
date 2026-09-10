import 'guide_ui.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'alighting_alert.dart';

class TripTrackingPanel extends StatefulWidget {
  const TripTrackingPanel({
    super.key,
    required this.request,
    required this.postJson,
    this.allowSpeech = true,
    this.onAlighted,
  });
  final Map<String, dynamic> request;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  postJson;
  final bool allowSpeech;
  final VoidCallback? onAlighted;
  @override
  State<TripTrackingPanel> createState() => _TripTrackingPanelState();
}

class _TripTrackingPanelState extends State<TripTrackingPanel>
    with WidgetsBindingObserver {
  static const tts = MethodChannel('blind_bus_guide/tts');
  final alerts = AlightingAlert();
  Timer? timer;
  DateTime? attempted;
  bool ended = false;
  int? announcedOrder;
  int get interval =>
      progress?['state'] == 'riding' &&
          (progress?['remainingStops'] as num? ?? 99) <= 3
      ? 3
      : 5;
  bool busy = false, speaking = false;
  Map<String, dynamic>? position;
  Map<String, dynamic>? binding;
  String? speechError;
  String message = '탑승 요청에 연결된 차량 위치를 조회합니다.';
  Map<String, dynamic>? get progress => position?['progress'] is Map
      ? Map<String, dynamic>.from(position!['progress'] as Map)
      : null;
  bool get foreground =>
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (attempted == null ||
          DateTime.now().difference(attempted!).inSeconds >= interval)
        refresh();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  String guidance() {
    final value = progress;
    if (value == null) return '위치를 다시 조회해 주세요.';
    if (value['available'] != true || value['state'] != 'riding') {
      return '${value['message'] ?? '남은 정류장을 확인하지 못했습니다.'}';
    }
    final stop = widget.request['dropoffStop'];
    final count = value['remainingStops'];
    if (count == 1) return '다음 정류장은 $stop입니다. 하차를 준비해주세요.';
    if (count == 2) return '두 정류장 뒤 $stop에서 하차합니다.';
    return '다음 정류장은 ${value['nextStop'] ?? '확인 중'}입니다.';
  }

  Future<bool> say() async {
    if (!mounted || !foreground || speaking || !widget.allowSpeech)
      return false;
    final checked = DateTime.tryParse('${position?['checkedAt']}');
    if (checked == null || DateTime.now().difference(checked).inSeconds > 30)
      return false;
    setState(() {
      speaking = true;
      speechError = null;
    });
    try {
      await tts
          .invokeMethod('speak', {
            'text':
                '${widget.request['isTest'] == true ? '테스트 안내입니다. ' : ''}${guidance()}',
          })
          .timeout(const Duration(seconds: 45));
      return true;
    } catch (_) {
      if (mounted)
        setState(() => speechError = '음성 출력 실패 · 화면 안내를 확인하거나 다시 듣기를 눌러주세요.');
      return false;
    } finally {
      if (mounted) setState(() => speaking = false);
    }
  }

  Future<void> refresh() async {
    if (!mounted || busy || ended || !foreground) return;
    attempted = DateTime.now();
    setState(() => busy = true);
    try {
      final result = await widget
          .postJson('/boarding/location', {
            'requestId': widget.request['requestId'],
            'passengerToken': widget.request['passengerToken'],
          })
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (result['status'] == 'alighted') {
        ended = true;
        timer?.cancel();
        widget.onAlighted?.call();
        return;
      }
      if (result['ok'] != true) throw StateError('위치 응답 오류');
      setState(() {
        binding = result['binding'] is Map
            ? Map<String, dynamic>.from(result['binding'] as Map)
            : null;
        position = result['available'] == true && result['position'] is Map
            ? Map<String, dynamic>.from(result['position'] as Map)
            : null;
        message = '${result['message'] ?? '위치를 확인하지 못했습니다.'}';
      });
      unawaited(announce());
    } catch (_) {
      if (mounted)
        setState(() {
          position = null;
          message = '차량 위치 연결이 끊겼습니다. 같은 차량으로 다시 조회합니다.';
        });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> announce() async {
    final value = progress;
    final level = alerts.candidate(value);
    final order = value?['currentOrder'] as int?;
    final moved =
        value?['available'] == true &&
        value?['state'] == 'riding' &&
        order != null &&
        announcedOrder != null &&
        order > announcedOrder!;
    if (announcedOrder == null && order != null) announcedOrder = order;
    if ((level != 0 || moved) && await say()) {
      if (level != 0) alerts.delivered(level);
      announcedOrder = order;
    }
  }

  String checkedTime() {
    final parsed = DateTime.tryParse('${position?['checkedAt']}');
    return parsed == null
        ? '확인되지 않음'
        : parsed.toLocal().toString().split('.').first;
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = progress;
    final reliable = value?['available'] == true;
    final count = reliable && value?['state'] == 'riding'
        ? value!['remainingStops']
        : null;
    final near = count is num && count <= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GuideCard(
          color: near ? GuideColors.yellow : GuideColors.soft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('내릴 때까지', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              Text(
                count != null
                    ? '$count개 정류장'
                    : value?['state'] == 'at_stop'
                    ? '하차 정류장'
                    : value?['state'] == 'passed'
                    ? '정류장 통과'
                    : '위치 확인 중',
                style: const TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 18),
              if (position != null)
                Text(
                  guidance(),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (position == null) Text(message),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GuideCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GuideFact('내리는 곳', '${widget.request['dropoffStop']}'),
              if (reliable && value?['nextStop'] != null)
                GuideFact('다음 정류장', '${value!['nextStop']}'),
              if (binding != null)
                GuideFact('탑승 차량', '${binding!['vehicleNo']}'),
              if (position != null)
                Text(
                  '${checkedTime().split(' ').last} 확인 · 자동 갱신',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        if (speechError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(speechError!),
          ),
        const SizedBox(height: 16),
        GuideAction(
          '안내 다시 듣기',
          onPressed: speaking || !widget.allowSpeech || position == null
              ? null
              : () async {
                  if (await say()) {
                    final level = alerts.candidate(progress);
                    if (level != 0) alerts.delivered(level);
                  }
                },
          icon: Icons.volume_up,
          secondary: true,
        ),
        if (position == null)
          GuideAction(
            '연결 다시 확인',
            onPressed: busy ? null : refresh,
            icon: Icons.refresh,
            secondary: true,
          ),
      ],
    );
  }
}
