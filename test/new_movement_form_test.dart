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

/// Two machines in stock, each with one probe that travels with it.
const _items = <InventoryItem>[
  InventoryItem(
      kind: 'machine',
      id: 1,
      code: 'M001',
      name: 'NEMIO 1',
      status: 'In Stock',
      location: 'Warehouse'),
  InventoryItem(
      kind: 'probe',
      id: 11,
      code: 'P001',
      name: 'PROBE 1',
      status: 'In Stock',
      location: 'Warehouse',
      assignedMachineId: 1),
  InventoryItem(
      kind: 'machine',
      id: 2,
      code: 'M002',
      name: 'NEMIO 2',
      status: 'In Stock',
      location: 'Warehouse'),
  InventoryItem(
      kind: 'probe',
      id: 12,
      code: 'P002',
      name: 'PROBE 2',
      status: 'In Stock',
      location: 'Warehouse',
      assignedMachineId: 2),
];

Widget _app() {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      movementsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      allMovementsProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      allItemsProvider.overrideWith((ref) async => _items),
      itemLabelsProvider.overrideWith((ref) => const <String, String>{}),
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

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await _pumpFrames(tester);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await _pumpFrames(tester, 4);
    await tester.tap(finder);
    await _pumpFrames(tester);
  }

  testWidgets('the form records several groups sharing one party and date',
      (tester) async {
    await pumpScreen(tester);
    await tapVisible(tester, find.text('New movement'));

    expect(find.text('What is going out *'), findsOneWidget);
    expect(find.text('Choose an item'), findsOneWidget);

    // a second group — same party, date and notes, its own items
    await tapVisible(tester, find.text('Add another group'));
    expect(find.text('Group 1'), findsOneWidget);
    expect(find.text('Group 2'), findsOneWidget);
    expect(find.text('Choose an item'), findsNWidgets(2));

    // picking a machine brings its probe along, into that group only
    await tapVisible(tester, find.text('Choose an item').first);
    await tapVisible(tester, find.text('M001  NEMIO 1'));
    expect(find.text('M001  NEMIO 1'), findsOneWidget);
    expect(find.text('P001  PROBE 1'), findsOneWidget);
    expect(find.text('P002  PROBE 2'), findsNothing);
    expect(find.text('Choose an item'), findsOneWidget);

    // the empty second group can be dropped again; the filled one stays
    await tapVisible(tester, find.byTooltip('Remove this group').last);
    expect(find.text('Group 1'), findsNothing);
    expect(find.text('M001  NEMIO 1'), findsOneWidget);
    expect(find.text('Choose an item'), findsNothing);
  });

  testWidgets('each group keeps its own sold and paid marks', (tester) async {
    await pumpScreen(tester);
    await tapVisible(tester, find.text('New movement'));

    // sold only exists on a sale-like send — a workshop trip cannot
    // have been sold
    expect(find.widgetWithText(SwitchListTile, 'Sold'), findsNothing);
    await tapVisible(tester, find.text('Customer'));
    await tapVisible(tester, find.text('Choose an item'));
    await tapVisible(tester, find.text('M002  NEMIO 2'));

    // a group can be sold on its own: the sale amount and seller are
    // asked for under that group's switch
    final sold = find.text('Sold');
    await tapVisible(tester, sold);
    expect(find.text('Sale amount (optional)'), findsOneWidget);
    expect(find.text('Sold by (optional)'), findsOneWidget);

    // paid is per group too, and the whole form has one
    expect(find.widgetWithText(SwitchListTile, 'Paid'), findsOneWidget);
    await tapVisible(tester, find.text('Add another group'));
    expect(find.widgetWithText(SwitchListTile, 'Paid'), findsNWidgets(2));
    expect(find.widgetWithText(SwitchListTile, 'Sold'), findsNWidgets(2));
    // the new group starts plain
    expect(find.text('Sale amount (optional)'), findsOneWidget);
  });
}
