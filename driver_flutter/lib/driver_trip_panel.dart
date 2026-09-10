import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DriverTripPanel extends StatefulWidget {
  const DriverTripPanel({super.key, required this.load});
  final Future<Map<String, dynamic>> Function() load;
  @override
  State<DriverTripPanel> createState() => _DriverTripPanelState();
}

class _DriverTripPanelState extends State<DriverTripPanel> with WidgetsBindingObserver {
  Timer? timer;
  DateTime? attempted;
  bool busy = false, ended = false;
  int alerted = 0;
  Map<String, dynamic>? progress;
  String message = '승객의 하차 정류장까지 조회 중…';
  String? checkedAt;
  bool get visible => (WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) && (ModalRoute.of(context)?.isCurrent ?? true);
  int get interval => progress?['state'] == 'riding' && (progress?['remainingStops'] as num? ?? 99) <= 3 ? 3 : 5;
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (attempted == null || DateTime.now().difference(attempted!).inSeconds >= interval) refresh();
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) refresh(); }
  Future<void> refresh() async {
    if (!mounted || busy || ended || !visible) return;
    busy = true; attempted = DateTime.now();
    try {
      final data = await widget.load().timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (data['ok'] != true) throw StateError('조회 실패');
      final p = data['position'];
      final g = p is Map && p['progress'] is Map ? Map<String, dynamic>.from(p['progress'] as Map) : null;
      setState(() {
        ended = data['status'] == 'alighted';
        progress = g;
        checkedAt = p is Map ? DateTime.tryParse('${p['checkedAt']}')?.toLocal().toString().split('.').first : null;
        message = ended ? '하차 완료' : g?['available'] == true && g?['state'] == 'riding'
            ? g!['remainingStops'] == 1 ? '하차 임박 · 다음 정류장에서 이 승객이 하차합니다.' : '이 승객 하차까지 ${g['remainingStops']}개 정류장'
            : '${g?['message'] ?? data['message'] ?? '하차 위치를 확인하지 못했습니다.'}';
      });
      if (ended) timer?.cancel();
      final level = g?['available'] != true ? 0 : g?['state'] == 'at_stop' || g?['state'] == 'passed' ? 3
          : g?['state'] == 'riding' && g?['remainingStops'] == 1 ? 2
          : g?['state'] == 'riding' && g?['remainingStops'] == 2 ? 1 : 0;
      if (level > alerted && visible && !ended) {
        alerted = level;
        await SystemSound.play(SystemSoundType.alert);
      }
    } catch (_) {
      if (mounted) setState(() { progress = null; checkedAt = null; message = '하차 위치 조회 실패 · 자동으로 다시 조회합니다.'; });
    } finally { busy = false; }
  }
  @override
  void dispose() { timer?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 12), padding: const EdgeInsets.all(12),
    color: progress?['available'] == true && (progress?['remainingStops'] as num? ?? 99) <= 2 ? Colors.orange.shade100 : Colors.grey.shade100,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(message, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      if (checkedAt != null) Text('조회: $checkedAt'),
      const Text('이 화면에서 자동 조회합니다. 실제 하차를 확인한 뒤 하차 완료를 눌러주세요.'),
    ]),
  );
}
