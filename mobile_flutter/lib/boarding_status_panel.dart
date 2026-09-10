import 'guide_ui.dart';
import 'trip_tracking_panel.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BoardingStatusPanel extends StatefulWidget {
  const BoardingStatusPanel({
    super.key,
    required this.request,
    required this.postJson,
    this.onBoarded,
    this.onAlighted,
  });
  final Map<String, dynamic> request;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  postJson;
  final VoidCallback? onBoarded;
  final VoidCallback? onAlighted;
  @override
  State<BoardingStatusPanel> createState() => _BoardingStatusPanelState();
}

class _BoardingStatusPanelState extends State<BoardingStatusPanel>
    with WidgetsBindingObserver {
  static const tts = MethodChannel('blind_bus_guide/tts');
  Timer? timer;
  bool busy = false, speaking = false, pendingSpeech = false;
  String state = 'queued';
  String? error;
  String get message => state == 'alighted'
      ? '하차가 확인되었습니다. 이 버스의 안내를 마칩니다.'
      : state == 'boarded'
      ? '기사님이 탑승 완료를 확인했습니다. ${widget.request['routeNo']}번 버스로 이동합니다. ${widget.request['dropoffStop']} 정류장에서 하차합니다.'
      : state == 'confirmed'
      ? '기사님이 탑승 요청을 확인했습니다. 버스 도착 안내를 기다려주세요.'
      : '탑승 요청을 보냈습니다. 기사님의 확인을 기다립니다.';
  bool get foreground =>
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
    WidgetsBinding.instance.addPostFrameCallback((_) => poll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState next) {
    if (next == AppLifecycleState.resumed) poll();
  }

  Future<void> speak() async {
    if (!mounted || !foreground) return;
    if (speaking) {
      pendingSpeech = true;
      return;
    }
    setState(() => speaking = true);
    try {
      await tts
          .invokeMethod('speak', {
            'text':
                '${widget.request['isTest'] == true ? '테스트 안내입니다. ' : ''}$message',
          })
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      if (mounted)
        setState(() => error = '음성 출력 실패. 화면 안내를 확인하고 다시 듣기를 눌러주세요.');
    } finally {
      if (mounted) {
        setState(() => speaking = false);
        if (pendingSpeech) {
          pendingSpeech = false;
          unawaited(speak());
        }
      }
    }
  }

  Future<void> poll() async {
    if (!mounted || busy || !foreground || state == 'alighted') return;
    busy = true;
    try {
      final result = await widget
          .postJson('/boarding/status', {
            'requestId': widget.request['requestId'],
            'passengerToken': widget.request['passengerToken'],
          })
          .timeout(const Duration(seconds: 12));
      if (!mounted || !foreground || state == 'alighted') return;
      final next = result['status'];
      if (result['ok'] != true ||
          result['requestId'] != widget.request['requestId'] ||
          !['queued', 'confirmed', 'boarded', 'alighted'].contains(next))
        throw StateError('잘못된 상태 응답');
      final changed = state != next;
      setState(() {
        state = next as String;
        error = null;
      });
      if (changed) {
        if (state == 'boarded') widget.onBoarded?.call();
        if (state == 'alighted') {
          timer?.cancel();
          widget.onAlighted?.call();
        }
        unawaited(speak());
      }
    } catch (_) {
      if (mounted)
        setState(() => error = '상태 연결 끊김 · 마지막 확인 상태입니다. 자동으로 재시도합니다.');
    } finally {
      busy = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (state != 'boarded')
        GuideCard(
          color: state == 'alighted' ? GuideColors.soft : Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                state == 'alighted' ? Icons.check_circle : Icons.support_agent,
                size: 44,
                color: GuideColors.primary,
              ),
              const SizedBox(height: 16),
              GuideHeading(
                state == 'alighted'
                    ? '하차를 마쳤어요'
                    : state == 'confirmed'
                    ? '기사님이 확인했어요'
                    : '기사님 확인 대기',
              ),
              const SizedBox(height: 12),
              Text(message),
            ],
          ),
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (state == 'boarded')
        TripTrackingPanel(
          request: widget.request,
          postJson: widget.postJson,
          allowSpeech: !speaking,
          onAlighted: () {
            if (state == 'alighted') return;
            setState(() => state = 'alighted');
            timer?.cancel();
            widget.onAlighted?.call();
            unawaited(speak());
          },
        ),
      if (state != 'boarded')
        GuideAction(
          '안내 다시 듣기',
          onPressed: speaking ? null : speak,
          icon: Icons.volume_up,
          secondary: true,
        ),
    ],
  );
}
