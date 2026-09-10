import 'driver_inbox.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const DriverApp());

class DriverApp extends StatelessWidget {
  const DriverApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Blind Bus 기사',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6246EA)),
      scaffoldBackgroundColor: const Color(0xFFF5F6FB),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(),
      ),
      useMaterial3: true,
    ),
    home: const VehiclePage(),
  );
}

class VehiclePage extends StatefulWidget {
  const VehiclePage({super.key});
  @override
  State<VehiclePage> createState() => _VehiclePageState();
}

class _VehiclePageState extends State<VehiclePage> {
  static const channel = MethodChannel('blind_bus_driver/profile');
  final form = GlobalKey<FormState>();
  final route = TextEditingController();
  final vehicle = TextEditingController();
  Map<String, dynamic>? saved;
  bool loading = true, saving = false, editing = false;
  String? error;

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {
    setState(() { loading = true; error = null; });
    try {
      final raw = await channel.invokeMethod<String>('load');
      final data = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
      if (data != null && (data['routeNo'] is! String || data['vehicleNo'] is! String)) {
        throw const FormatException('Invalid profile');
      }
      if (!mounted) return;
      setState(() {
        saved = data;
        route.text = data?['routeNo'] ?? '';
        vehicle.text = data?['vehicleNo'] ?? '';
        editing = data == null;
      });
    } catch (_) {
      if (mounted) setState(() => error = '등록 정보를 읽지 못했습니다. 다시 불러와 주세요.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() { saving = true; error = null; });
    try {
    final latest = await channel.invokeMethod<String>('load');
    final credentials = latest == null ? <String, dynamic>{} : (jsonDecode(latest) as Map<String, dynamic>)['credentials'] ?? <String, dynamic>{};
    final data = <String, dynamic>{
      'credentials': credentials,
      'city': '청주',
      'routeNo': route.text.trim(),
      'vehicleNo': vehicle.text.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
    };
      await channel.invokeMethod<void>('save', {'profile': jsonEncode(data)});
      if (!mounted) return;
      setState(() { saved = data; editing = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이 기기에 차량 정보를 저장했습니다.')),
      );
    } catch (_) {
      if (mounted) setState(() => error = '저장하지 못했습니다. 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() { route.dispose(); vehicle.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Blind Bus · 기사')),
    body: SafeArea(child: loading
      ? const Center(child: CircularProgressIndicator())
      : SingleChildScrollView(padding: const EdgeInsets.all(24), child: Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Icon(Icons.directions_bus_rounded, size: 64, color: Color(0xFF6246EA)),
            const SizedBox(height: 20),
            Text(editing ? '운행 차량 등록' : '내 운행 차량',
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('1단계 · 버스 번호와 차량번호 설정', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            if (error != null) ...[
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (!editing && saved == null)
                OutlinedButton(onPressed: load, child: const Text('다시 불러오기')),
              const SizedBox(height: 16),
            ],
            if (editing) Form(key: form, child: Column(children: [
              const Align(alignment: Alignment.centerLeft, child: Text('운행 지역: 청주')),
              const SizedBox(height: 20),
              TextFormField(controller: route, enabled: !saving,
                maxLength: 20, textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '버스 번호', hintText: '예: 747 또는 105-1', helperText: '정류장에 표시되는 노선 번호를 입력하세요.'),
                validator: (value) => value == null || value.trim().isEmpty
                  ? '버스 번호를 입력해 주세요.'
                  : !RegExp(r'^[가-힣a-zA-Z0-9-]+$').hasMatch(value.trim())
                    ? '문자, 숫자, 하이픈으로 입력해 주세요.' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(controller: vehicle, enabled: !saving,
                maxLength: 20, textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: '차량번호 전체', hintText: '예: 충북70아1234', helperText: '같은 노선의 다른 버스와 구분하는 번호입니다.'),
                validator: (value) {
                  final normalized = (value ?? '').replaceAll(RegExp(r'\s+'), '');
                  if (normalized.isEmpty) return '차량번호를 입력해 주세요.';
                  if (!RegExp(r'^([가-힣]{2})?\d{2,3}[가-힣]\d{4}$').hasMatch(normalized)) {
                    return '번호판 전체를 입력해 주세요. 예: 충북70아1234';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => save(),
              ),
              const SizedBox(height: 20),
              SizedBox(width: double.infinity, height: 56, child: FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? '저장 중…' : '차량 정보 저장', style: const TextStyle(fontSize: 18)),
              )),
              if (saved != null) TextButton(onPressed: saving ? null : () {
                setState(() {
                  route.text = saved!['routeNo']; vehicle.text = saved!['vehicleNo'];
                  editing = false; error = null;
                });
              }, child: const Text('수정 취소')),
            ])),
            if (!editing && saved != null) ...[
              FilledButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DriverInbox(profile: saved!))), child: const Text('서버 등록 및 요청 수신 시작')), 
              Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('청주 · 기기 저장 완료'),
                  const SizedBox(height: 12),
                  Text('${saved!['routeNo']}번', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text('차량번호 ${saved!['vehicleNo']}', style: const TextStyle(fontSize: 20)),
                ],
              ))),
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: () => setState(() => editing = true),
                icon: const Icon(Icons.edit_outlined), label: const Text('차량 정보 수정')),
            ],
            const SizedBox(height: 24),
            const Card(color: Color(0xFFFFF2CC), child: Padding(
              padding: EdgeInsets.all(20), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('실제 버스 연동 전', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('요청 수신 시작을 누르면 서버에 등록합니다. 차량의 실제 운행 여부는 확인하지 않습니다. 요청은 수신 화면을 열어 두었을 때 조회합니다.'),
                ],
              ),
            )),
          ]),
        ),
      )),
    ),
  );
}
