import 'driver_trip_panel.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DriverInbox extends StatefulWidget {
  const DriverInbox({super.key, required this.profile});
  final Map<String, dynamic> profile;
  @override
  State<DriverInbox> createState() => _DriverInboxState();
}

class _DriverInboxState extends State<DriverInbox> with WidgetsBindingObserver {
  static const channel = MethodChannel('blind_bus_driver/profile');
  Timer? timer;
  String? token;
  bool busy = false, registered = false;
  String status = '서버 연결 중…';
  List<dynamic> requests = [];
  Set<String> seen = {};
  bool loaded = false;
  String? changing;

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); poll(); timer = Timer.periodic(const Duration(seconds: 3), (_) => poll()); }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> data) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(Uri.parse('${const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://127.0.0.1:8765')}$path'));
      request.headers.set('X-Blindbus-Access', const String.fromEnvironment('API_ACCESS_TOKEN'));
      final bytes = utf8.encode(jsonEncode(data));
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(const Duration(seconds: 8));
      final result = jsonDecode(await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 8))) as Map<String, dynamic>;
      if (response.statusCode != 200 || result['ok'] != true) throw Exception(result['error'] ?? '서버 오류');
      return result;
    } finally { client.close(force: true); }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) poll(); }

  Future<void> poll() async {
    if (!mounted || busy || changing != null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) return;
    busy = true;
    try {
      if (token == null) {
        final raw = await channel.invokeMethod<String>('load');
        final profile = jsonDecode(raw!) as Map<String, dynamic>;
        final credentials = Map<String, dynamic>.from(profile['credentials'] ?? {});
        final key = widget.profile['vehicleNo'] as String;
        final newToken = credentials[key] as String? ?? List.generate(32, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        credentials[key] = newToken;
        profile['credentials'] = credentials;
        await channel.invokeMethod('save', {'profile': jsonEncode(profile)});
        token = newToken;
      }
      if (!registered) {
        await post('/driver/register', {...widget.profile, 'token': token});
        registered = true;
      }
      final data = await post('/driver/inbox', {'vehicleNo': widget.profile['vehicleNo'], 'token': token});
      if (!mounted) return;
      final list = data['requests'] as List<dynamic>;
      final ids = list.map((e) => '${e['requestId']}').toSet();
      if (loaded && ids.difference(seen).isNotEmpty) {
        SystemSound.play(SystemSoundType.alert);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('새 탑승 지원 요청이 도착했습니다.')));
      }
      seen = ids; loaded = true;
      if (changing != null) return;
      setState(() { requests = list; status = '서버 연결됨 · 3초마다 확인'; });
    } catch (e) {
      if (mounted) setState(() => status = '수신 확인 실패: $e\n서버 실행 및 USB 연결을 확인하세요.');
    } finally { busy = false; }
  }

  Future<void> act(Map<String, dynamic> request, String action) async {
    if (changing != null || token == null) return;
    setState(() => changing = '${request['requestId']}');
    try {
      if (action == 'board' || action == 'alight') {
        final yes = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
          title: Text(action == 'alight' ? '하차 완료 확인' : '탑승 완료 확인'),
          content: Text(action == 'alight' ? '${request['dropoffStop']}에서 해당 승객이 실제로 하차했나요?' : '${request['boardingStop']}에서 요청한 승객이 실제로 탑승했나요?'),
          actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('아직 아니요')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action == 'alight' ? '네, 하차했습니다' : '네, 탑승했습니다'))],
        ));
        if (yes != true || !mounted) return;
      }
      final response = await post('/driver/action', {
        'vehicleNo': widget.profile['vehicleNo'], 'token': token,
        'requestId': request['requestId'], 'action': action,
      });
      if (!mounted) return;
      setState(() {
        for (final r in requests) {
          if (r['requestId'] == request['requestId']) r['status'] = response['status'];
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        response['status'] == 'alighted' ? '하차 완료를 서버에 저장했습니다.' : response['status'] == 'boarded' ? '탑승 완료를 서버에 저장했습니다.' : '요청 확인을 서버에 저장했습니다.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('처리 확인 실패: $e. 다시 시도해주세요.')));
    } finally { if (mounted) setState(() => changing = null); }
  }

  @override
  void dispose() { timer?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('탑승 지원 요청')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Text('${widget.profile['routeNo']}번 · ${widget.profile['vehicleNo']}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      Text(status, semanticsLabel: status),
      TextButton(onPressed: poll, child: const Text('지금 새로고침')),
      const Text('이 화면을 열어 두면 요청을 확인합니다. 확인과 탑승 완료는 승객 앱에 전달됩니다. 백그라운드 푸시는 없습니다.'),
      const SizedBox(height: 16),
      if (loaded && requests.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('아직 받은 탑승 요청이 없습니다.'))),
      for (final r in requests) Card(key: ValueKey(r['requestId']), child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r['isTest'] == true ? '테스트 · 탑승 지원 요청' : '시각장애인 탑승 예정', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Text('승차: ${r['boardingStop']}', style: const TextStyle(fontSize: 20)),
        Text('하차: ${r['dropoffStop']}', style: const TextStyle(fontSize: 20)),
        const SizedBox(height: 12),
        Text('${r['routeNo']}번 · ${r['vehicleNo']}'),
        Text('접수: ${DateTime.tryParse('${r['createdAt']}')?.toLocal().toString().split('.').first ?? r['createdAt']}'),
        Text(r['status'] == 'alighted' ? '하차 완료' : r['status'] == 'boarded' ? '탑승 완료' : r['status'] == 'confirmed' ? '기사 확인 완료 · 탑승 대기' : '요청 수신됨 · 기사 확인 전'),
        const SizedBox(height: 12),
        if (r['status'] == 'boarded' && token != null) ...[
          DriverTripPanel(key: ValueKey(r['requestId']), load: () => post('/driver/trip', {
            'vehicleNo': widget.profile['vehicleNo'], 'token': token, 'requestId': r['requestId'],
          })),
          FilledButton(onPressed: changing != null ? null : () => act(Map<String, dynamic>.from(r), 'alight'), child: const Text('하차 완료')),
        ],
        if (r['status'] == 'queued' || r['status'] == null)
          FilledButton(onPressed: changing != null ? null : () => act(Map<String, dynamic>.from(r), 'confirm'), child: const Text('요청 확인')),
        if (r['status'] == 'confirmed')
          FilledButton(onPressed: changing != null ? null : () => act(Map<String, dynamic>.from(r), 'board'), child: const Text('탑승 완료')),
        if (changing == r['requestId']) const Text('처리 중…'),
      ]))),
    ]),
  );
}