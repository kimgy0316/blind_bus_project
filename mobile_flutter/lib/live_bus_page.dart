import 'dart:async';
import 'package:flutter/material.dart';
import 'boarding_guide_page.dart';

class LiveBusPage extends StatefulWidget {
  const LiveBusPage({super.key, required this.route, required this.getJson});
  final Map<String, dynamic> route;
  final GetBoardingJson getJson;
  @override
  State<LiveBusPage> createState() => _LiveBusPageState();
}
class _LiveBusPageState extends State<LiveBusPage> with WidgetsBindingObserver {
  Timer? timer;
  bool get visible => (WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) && (ModalRoute.of(context)?.isCurrent ?? true);
  bool busy = false;
  String? error;
  Map<String, dynamic>? data;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
    timer = Timer.periodic(const Duration(seconds: 10), (_) => load());
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) { if (state == AppLifecycleState.resumed) load(); }
  @override
  void dispose() { timer?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  Future<void> load() async {
    if (!mounted || busy || !visible) return;
    setState(() { busy = true; error = null; });
    try {
      final response = await widget.getJson('/live-buses', {
        'routeNo': '${widget.route['routeNo']}', 'nodeId': '${widget.route['nodeId']}',
        'cityCode': '${widget.route['cityCode'] ?? '33010'}',
      });
      if (response['ok'] != true) throw StateError('${response['error']}');
      if (mounted) setState(() => data = response);
    } catch (e) { if (mounted) setState(() => error = '실제 정보 조회 실패: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('실제 운행 정보 확인')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      Text('${widget.route['routeNo']}번 · ${widget.route['boardingStop']}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      const Text('TAGO 제공 자료입니다. 차량 목록과 도착시간은 서로 연결된 정보가 아닙니다. 정류장 전광판·차량번호와 비교해 확인하세요.'),
      FilledButton(onPressed: busy ? null : load, child: Text(busy ? '조회 중…' : '최신 정보 다시 조회')),
      const Text('10초마다 자동 조회 · 앱으로 돌아오면 즉시 조회'),
      if (error != null) Text('$error\n화면 값은 마지막으로 성공한 조회 결과입니다.'),
      if (data != null) ...[
        Text('서버 조회: ${DateTime.tryParse('${data!['checkedAt']}')?.toLocal()}'),
        const Text('제공기관의 측정 시각은 응답에 없어 지연 여부를 확정할 수 없습니다.'),
        const SizedBox(height: 20),
        const Text('정류장 도착 예정', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
        if ((data!['arrivals'] as List).isEmpty) const Text('현재 도착 예정 정보가 없습니다. 노선 ID를 확보하지 못해 차량 목록도 조회하지 않았습니다.'),
        for (final a in data!['arrivals'] as List) Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(
          '${a['route_no']}번 · 약 ${((a['arrival_seconds'] as num) / 60).ceil()}분\n남은 정류장 ${a['prev_station_count']}개\n노선 ID: ${a['route_id']}'))),
        const SizedBox(height: 20),
        const Text('같은 노선의 운행 차량', style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
        for (final e in data!['locationErrors'] as List) Text('$e'),
        if ((data!['vehicles'] as List).isEmpty) const Text('조회된 차량이 없습니다. 운행 중단으로 단정할 수는 없습니다.'),
        for (final v in data!['vehicles'] as List) Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(
          '차량번호: ${v['vehicleNo'] == '' ? '미제공' : v['vehicleNo']}\n노선: ${v['routeNo']} / ${v['routeId']}\n최근 정류장: ${v['stopName']}\n위도: ${v['latitude']} · 경도: ${v['longitude']}'))),
      ],
    ]),
  );
}
