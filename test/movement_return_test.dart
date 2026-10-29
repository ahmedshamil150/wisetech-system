import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/auth/auth_controller.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/movements/movements_screen.dart';

class _FakeAuth implements AuthController {
  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  User? get currentUser => null;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => {'role': 'admin'};

  @override
  Future<void> login(String username, String password) async {}

  @override
  Future<void> signOut() async {}
}

Map<String, dynamic> _send({
  required int id,
  required int machineId,
  required String group,
}) =>
    {
      'id': id,
      'movement_type': 'Customer',
      'movement_date': '25-09-2026',
      'to_location': 'Jimmy Sb',
      'group_ref': group,
      'machine_id': machineId,
      'probe_id': null,
      'reason': 'Sent to customer',
      'paid': false,
      'sale_amount': null,
      'sold_by': '',
      'is_demo': false,
      'reference': '',
      'dealer_id': null,
      'customer_id': 4,
      'workshop_id': null,
      'actor_id': 'u1',
      'notes': '',
      'customers': {'name': 'Jimmy Sb'},
      'dealers': null,
      'profiles': {'display_name': 'Ahmed'},
    };

/// One card holding two sends: a machine alone, and two machines together.
final _rows = [
  _send(id: 11, machineId: 1, group: 'send-a'),
  _send(id: 12, machineId: 2, group: 'send-b'),
  _send(id: 13, machineId: 3, group: 'send-b'),
];

const _items = <InventoryItem>[
  InventoryItem(
      kind: 'machine',
      id: 1,
      code: 'M001',
      name: 'NEMIO 1',
      status: 'In Stock',
      location: 'Warehouse'),
  InventoryItem(
      kind: 'machine',
      id: 2,
      code: 'M002',
      name: 'NEMIO 2',
      status: 'In Stock',
      location: 'Warehouse'),
  InventoryItem(
      kind: 'machine',
      id: 3,
      code: 'M003',
      name: 'NEMIO 3',
      status: 'In Stock',
      location: 'Warehouse'),
];

const _labels = <String, String>{
  'machine:1': 'NEMIO 1',
  'machine:2': 'NEMIO 2',
  'machine:3': 'NEMIO 3',
};

Widget _app() {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      movementsProvider.overrideWith((ref) async => _rows),
      allMovementsProvider.overrideWith((ref) async => _rows),
      allItemsProvider.overrideWith((ref) async => _items),
      itemLabelsProvider.overrideWith((ref) => _labels),
      flagsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      dealersProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      customersProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      authControllerProvider.overrideWithValue(fake),
      profileProvider.overrideWith((ref) async => {'role': 'admin'}),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: const Scaffold(body: MovementsScreen()),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openCard(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  await _pumpFrames(tester);
  await tester.tap(find.textContaining('Jimmy Sb').first);
  await _pumpFrames(tester);
}

void main() {
  testWidgets('the whole movement returns send by send', (tester) async {
    await _openCard(tester);

    // the primary action opens the tick list because three items are out
    await tester.tap(find.widgetWithText(FilledButton, 'Back to inventory'));
    await _pumpFrames(tester);

    // one line per send, every send ticked to start with
    expect(find.text('1 of 1 ticked'), findsOneWidget);
    expect(find.text('Send 2 · 2 items'), findsOneWidget);
    expect(find.text('2 of 2 ticked'), findsOneWidget);
    expect(find.text('Return 3 items'), findsOneWidget);

    // unticking a send's line leaves all of its items out
    await tester.tap(find.text('Send 2 · 2 items'));
    await _pumpFrames(tester);

    expect(find.text('0 of 2 ticked'), findsOneWidget);
    expect(find.text('Return 1 item'), findsOneWidget);
  });

  testWidgets('a send returns on its own from its own menu', (tester) async {
    await _openCard(tester);

    // the second send's ⋮ carries its own Back to inventory
    await tester.tap(find.byTooltip('Send actions').last);
    await _pumpFrames(tester);
    expect(find.text('Back to inventory'), findsWidgets);

    await tester.tap(find.text('Back to inventory').last);
    await _pumpFrames(tester);

    // the tick list holds that send alone, all of it ticked
    expect(find.text('This send · 2 items'), findsOneWidget);
    expect(find.text('2 of 2 ticked'), findsOneWidget);
    expect(find.text('Return 2 items'), findsOneWidget);
  });
}
