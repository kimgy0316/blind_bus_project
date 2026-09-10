import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blind_bus_driver/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('validates, saves, reloads and cancels edits', (tester) async {
    String? stored;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('blind_bus_driver/profile'), (call) async {
        if (call.method == 'load') return stored;
        if (call.method == 'save') stored = call.arguments['profile'] as String;
        return null;
      },
    );
    await tester.pumpWidget(const DriverApp());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('차량 정보 저장'));
    await tester.tap(find.text('차량 정보 저장'));
    await tester.pumpAndSettle();
    expect(stored, isNull);
    await tester.enterText(find.byType(TextFormField).at(0), '747');
    await tester.enterText(find.byType(TextFormField).at(1), '충북 70아 1234');
    await tester.ensureVisible(find.text('차량 정보 저장'));
    await tester.tap(find.text('차량 정보 저장'));
    await tester.pumpAndSettle();
    expect(jsonDecode(stored!)['vehicleNo'], '충북70아1234');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const DriverApp());
    await tester.pumpAndSettle();
    expect(find.text('747번'), findsOneWidget);
    await tester.tap(find.text('차량 정보 수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '105');
    await tester.ensureVisible(find.text('수정 취소'));
    await tester.tap(find.text('수정 취소'));
    await tester.pumpAndSettle();
    expect(find.text('747번'), findsOneWidget);
  });
}
