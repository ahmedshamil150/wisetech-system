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
  String notes = '',
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
      'notes': notes,
      'customers': {'name': 'Jimmy Sb'},
      'dealers': null,
      'profiles': {'display_name': 'Ahmed'},
    };

/// One customer send, an old imported one without a group, and a card
/// holding two sends.
final _oneSend = [_send(id: 11, machineId: 1, group: 'send-a', notes: 'Call first')];
final _groupless = [_send(id: 12, machineId: 1, group: '')];
final _twoSends = [
  _send(id: 11, machineId: 1, group: 'send-a'),
  _send(id: 12, machineId: 2, group: 'send-b'),
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
];

const _labels = <String, String>{'machine:1': 'NEMIO 1', 'machine:2': 'NEMIO 2'};

Widget _app(List<Map<String, dynamic>> rows) {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      movementsProvider.overrideWith((ref) async => rows),
      allMovementsProvider.overrideWith((ref) async => rows),
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

Future<void> _openCard(WidgetTester tester, List<Map<String, dynamic>> rows,
    [int index = 0]) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(rows));
  await _pumpFrames(tester);
  await tester.tap(find.textContaining('Jimmy Sb').at(index));
  await _pumpFrames(tester);
}

void main() {
  testWidgets('a single-send movement offers Add item and opens the picker',
      (tester) async {
    await _openCard(tester, _oneSend);

    expect(find.text('Add item'), findsOneWidget);
    expect(find.text('Add group'), findsOneWidget);

    await tester.tap(find.text('Add item'));
    await _pumpFrames(tester);

    // the item already in the send is not offered again
    expect(find.text('Choose an item'), findsOneWidget);
    expect(find.text('M002  NEMIO 2'), findsOneWidget);
    expect(find.text('M001  NEMIO 1'), findsNothing);
    await tester.tap(find.text('Close'));
    await _pumpFrames(tester);
  });

  testWidgets('an old send without a group accepts an item too',
      (tester) async {
    await _openCard(tester, _groupless);

    await tester.tap(find.text('Add item'));
    await _pumpFrames(tester);

    expect(find.text('Choose an item'), findsOneWidget);
    expect(find.textContaining('cannot be added to'), findsNothing);
    await tester.tap(find.text('Close'));
    await _pumpFrames(tester);
  });

  testWidgets('a card with several sends asks which group the item joins',
      (tester) async {
    await _openCard(tester, _twoSends);

    await tester.tap(find.text('Add item'));
    await _pumpFrames(tester);

    expect(find.text('Which group gets the item?'), findsOneWidget);
    expect(find.textContaining('NEMIO 1 → Jimmy Sb'), findsOneWidget);
    expect(find.textContaining('NEMIO 2 → Jimmy Sb'), findsOneWidget);

    await tester.tap(find.textContaining('NEMIO 2 → Jimmy Sb'));
    await _pumpFrames(tester);
    expect(find.text('Choose an item'), findsOneWidget);
  });

  testWidgets('Add group opens the form filled in from the card',
      (tester) async {
    await _openCard(tester, _oneSend);

    await tester.tap(find.text('Add group'));
    await _pumpFrames(tester);

    // the kind, party, date and notes carry over; only the items are new
    expect(find.text('Add a group'), findsOneWidget);
    expect(find.text('Jimmy Sb'), findsWidgets);
    expect(find.widgetWithText(TextField, '25-09-2026'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Call first'), findsOneWidget);
    expect(find.text('Choose an item'), findsOneWidget);
  });
}
