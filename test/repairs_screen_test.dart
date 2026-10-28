import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/repairs/repairs_screen.dart';

Map<String, dynamic> _job(
  int id, {
  required String jobNumber,
  required String customer,
  String status = 'Received',
  String receivedAt = '10-01-2026',
  String? returnedAt,
  String model = 'Mindray DC-40',
}) =>
    {
      'id': id,
      'job_number': jobNumber,
      'status': status,
      'received_at': receivedAt,
      'returned_at': returnedAt,
      'customer_contact': '0300-1234567',
      'customers': {'name': customer},
      'repair_items': [
        {
          'id': id * 10,
          'equipment_type': 'machine',
          'name_model': model,
          'serial_number': 'SN-$id',
          'quantity': 1,
        },
      ],
    };

final _jobs = [
  _job(1, jobNumber: 'JOB-1', customer: 'Ali Traders'),
  _job(
    2,
    jobNumber: 'JOB-2',
    customer: 'Bilal Diagnostics',
    status: 'In repair',
    model: 'SonoSite M-Turbo with a very long model name for wrapping',
  ),
  _job(
    3,
    jobNumber: 'JOB-3',
    customer: 'Chand Clinic',
    status: 'Returned',
    returnedAt: '20-01-2026',
  ),
];

Widget _app() {
  return ProviderScope(
    overrides: [
      repairsProvider.overrideWith((ref) async => _jobs),
      flagsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: const Scaffold(body: RepairsScreen()),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<void> pumpScreen(WidgetTester tester,
      {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await _pumpFrames(tester);
  }

  testWidgets('lists every job without squeezing the row', (tester) async {
    await pumpScreen(tester);
    expect(find.text('JOB-1'), findsOneWidget);
    expect(find.text('JOB-2'), findsOneWidget);
    expect(find.text('JOB-3'), findsOneWidget);
    expect(find.text('Ali Traders'), findsOneWidget);
    expect(find.text('3 repairs'), findsOneWidget);
  });

  testWidgets('quick chips narrow the list to one state', (tester) async {
    await pumpScreen(tester);
    final chip = find.text('Sent back (1)');
    await tester.ensureVisible(chip);
    await _pumpFrames(tester);
    await tester.tap(chip);
    await _pumpFrames(tester);

    expect(find.text('JOB-3'), findsOneWidget);
    expect(find.text('JOB-1'), findsNothing);
    expect(find.text('JOB-2'), findsNothing);
    expect(find.text('1 repair'), findsOneWidget);
  });

  testWidgets('search finds a job by customer', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField).first, 'bilal');
    await _pumpFrames(tester);

    expect(find.text('JOB-2'), findsOneWidget);
    expect(find.text('JOB-1'), findsNothing);
  });

  testWidgets('filter sheet opens and Apply stays on screen', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Filters'));
    await _pumpFrames(tester);

    expect(find.text('Filter repairs'), findsWidgets);
    final apply = find.text('Apply filters');
    expect(apply, findsOneWidget);

    final rect = tester.getRect(apply);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(844));

    await tester.tap(apply);
    await _pumpFrames(tester);
    expect(find.text('Apply filters'), findsNothing);
  });

  testWidgets('new repair form opens with roomy sections', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('New repair'));
    await _pumpFrames(tester);

    expect(find.text('Who sent it'), findsWidgets);
    expect(find.text('From our stock'), findsOneWidget);
    expect(find.text('Outside item'), findsOneWidget);
    expect(find.text('Save repair'), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    await _pumpFrames(tester);
    expect(find.text('Save repair'), findsNothing);
  });

  testWidgets('details sheet opens from a job', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('JOB-1'));
    await _pumpFrames(tester);

    expect(find.text('Customer & dates'), findsOneWidget);
    expect(find.text('Items (1)'), findsOneWidget);
    expect(find.text('Edit job'), findsOneWidget);
    expect(find.text('Repaired — send it back'), findsOneWidget);
  });
}
