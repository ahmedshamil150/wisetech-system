import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/auth/auth_controller.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/sales/sales_screen.dart';

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

Map<String, dynamic> _sale({dynamic trno}) => {
  'id': 1,
  'sale_date': '2026-01-05',
  'invoice_reference': null,
  'sale_price': 45000,
  'notes': null,
  'old_trno': trno,
  'old_source_id': 10,
  'customer_id': 2,
  'customers': {'name': 'Dr Sajjad'},
  'sale_items': [
    {
      'item_description': 'Mindray DC-40',
      'item_serial': 'SN-1',
      'item_price': 45000,
      'item_type': 'machine',
      'is_main_item': 1,
      'machine_id': 8,
      'probe_id': null,
      'printer_id': null,
      'part_id': null,
    },
  ],
};

ProviderScope _app(Map<String, dynamic> sale) {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWithValue(_FakeAuth()),
      profileProvider.overrideWith((ref) async => {'role': 'admin'}),
      customersProvider.overrideWith(
        (ref) async => const <Map<String, dynamic>>[],
      ),
      dealersProvider.overrideWith(
        (ref) async => const <Map<String, dynamic>>[],
      ),
      inventoryProvider.overrideWith((ref) async => const <InventoryItem>[]),
      allMovementsProvider.overrideWith(
        (ref) async => const <Map<String, dynamic>>[],
      ),
      allSalesProvider.overrideWith((ref) async => [sale]),
      itemLabelsProvider.overrideWith((ref) => const <String, String>{}),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: const Scaffold(body: SalesScreen()),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int frames = 15]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the old invoice number shows on the card and in the details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_sale(trno: '4521')));
    await _pumpFrames(tester);

    expect(find.textContaining('Old invoice 4521'), findsOneWidget);

    await tester.tap(find.textContaining('Old invoice 4521'));
    await _pumpFrames(tester);

    expect(find.text('Old invoice no.'), findsOneWidget);
    expect(find.text('4521'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('the old system\'s zero reads as no invoice number', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_sale(trno: '0')));
    await _pumpFrames(tester);

    expect(find.textContaining('Old invoice 0'), findsNothing);
    await tester.tap(find.textContaining('2026-01-05'));
    await _pumpFrames(tester);

    expect(find.text('Old invoice no.'), findsNothing);
  });
}
