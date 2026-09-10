import 'driver_trip_panel.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';

void main() => runApp(MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(colorSchemeSeed: Colors.deepOrange, useMaterial3: true),
  home: const TestDriverApp(),
));

class TestDriverApp extends StatefulWidget {
  const TestDriverApp({super.key});
  @override
  State<TestDriverApp> createState() => _TestDriverAppState();
}

class _TestDriverAppState extends State<TestDriverApp> with WidgetsBindingObserver {
  static const base = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8765');
  final token = List.generate(32, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  Timer? timer;
  bool active = false, busy = false, showCompleted = false;
  String message = '수신 시작을 누르면 모든 노선의 테스트 요청을 받습니다.';
  List<Map<String, dynamic>> requests = [];

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    final request = await client.postUrl(Uri.parse('$base$path')).timeout(const Duration(seconds: 10));
    request.headers.set('X-Blindbus-Access', const String.fromEnvironment('API_ACCESS_TOKEN'));
    request.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode({'token': token, ...body}));
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 10));
    final raw = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (response.statusCode != 200 || data['ok'] != true) throw StateError('${data['error'] ?? '서버 응답 오류'}');
    return data;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> start() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await post('/test-driver/register', {});
      if (mounted) setState(() { active = true; message = '서버 연결됨 · 모든 노선 테스트 수신 중'; });
    } catch (e) {
      if (mounted) setState(() => message = '연결 실패: $e\n서버와 USB 연결을 확인하세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await refresh();
  }

  Future<void> refresh() async {
    if (!mounted || !active || busy || WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) return;
    setState(() => busy = true);
    try {
      final data = await post('/test-driver/inbox', {});
      if (!mounted) return;
      setState(() {
        requests = (data['requests'] as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
        message = '서버 연결됨 · 마지막 조회 ${TimeOfDay.now().format(context)}';
      });
    } catch (e) {
      if (mounted) setState(() => message = '수신 실패: $e\n마지막 조회 결과를 표시합니다.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(Map<String, dynamic> r, String action) async {
    if (busy) return;
    if (action == 'board' || action == 'alight') {
      final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(action == 'alight' ? '테스트 하차 완료' : '테스트 탑승 완료'),
        content: Text(action == 'alight' ? '${r['dropoffStop']}에서 이 승객이 하차했다고 가정하고 추적을 종료합니다.' : '${r['routeNo']}번에 승객이 탑승했다고 가정하고 승객앱을 버스 이동 상태로 변경합니다.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action == 'alight' ? '하차 완료' : '탑승 완료'))],
      ));
      if (yes != true || !mounted || busy) return;
    }
    setState(() => busy = true);
    try {
      await post('/test-driver/action', {'requestId': r['requestId'], 'action': action});
      if (mounted) setState(() => message = '처리 완료 · 승객앱에서 확인하세요.');
    } catch (e) {
      if (mounted) setState(() => message = '처리 확인 실패: $e\n새로고침 후 필요하면 다시 누르세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await refresh();
  }

  @override
  void dispose() {
    timer?.cancel(); client.close(force: true);
    WidgetsBinding.instance.removeObserver(this); super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = requests.where((r) => showCompleted || r['status'] != 'alighted').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('테스트 기사 · 모든 노선')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('차량 등록 없이 시험', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('승객앱에서 보낸 테스트 요청만 수신합니다. 실제 기사의 차량 등록이나 요청은 변경하지 않습니다.'),
        const SizedBox(height: 12),
        FilledButton(onPressed: busy ? null : start, child: Text(active ? '서버 다시 연결' : '모든 노선 수신 시작')),
        if (active) OutlinedButton(onPressed: busy ? null : refresh, child: const Text('새로고침')),
        Semantics(liveRegion: true, child: Text(message)),
        SwitchListTile(value: showCompleted, title: const Text('하차 완료한 요청도 보기'),
          onChanged: (value) => setState(() => showCompleted = value)),
        if (visible.isEmpty) const Padding(padding: EdgeInsets.all(24),
          child: Text('대기 중인 테스트 요청이 없습니다.\n승객앱에서 테스트 기사앱 연결 후 요청을 보내주세요.')),
        for (final r in visible) Card(key: ValueKey(r['requestId']), child: Padding(padding: const EdgeInsets.all(20), child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${r['routeNo']}번 · 탑승 지원 요청', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Text('${r['vehicleNo']}'.startsWith('TEST-') ? '테스트 · 차량 번호판 미지정' : '테스트 차량: ${r['vehicleNo']} · 실제 기사 등록 아님'),
            Text('승차: ${r['boardingStop']}\n하차: ${r['dropoffStop']}', style: const TextStyle(fontSize: 20)),
            Text('요청 번호: ${r['requestId']}'),
            Text('상태: ${r['status'] == 'alighted' ? '하차 완료' : r['status'] == 'boarded' ? '탑승 완료 · 하차 대기' : r['status'] == 'confirmed' ? '요청 확인됨' : '확인 대기'}'),
            if (r['status'] == 'boarded') ...[
              DriverTripPanel(key: ValueKey(r['requestId']), load: () => post('/test-driver/trip', {'requestId': r['requestId']})),
              FilledButton(onPressed: busy ? null : () => action(r, 'alight'), child: const Text('테스트 하차 완료')),
            ],
            if (r['status'] == 'queued') FilledButton(onPressed: busy ? null : () => action(r, 'confirm'), child: const Text('요청 확인')),
            if (r['status'] == 'confirmed') FilledButton(onPressed: busy ? null : () => action(r, 'board'), child: const Text('테스트 탑승 완료')),
          ],
        ))),
      ]),
    );
  }
}
