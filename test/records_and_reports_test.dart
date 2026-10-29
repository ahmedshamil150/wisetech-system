import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/auth/auth_controller.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/records/records_screen.dart';
import 'package:ultrasound_inventory/features/reports/reports_screen.dart';
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

ProviderScope _app(Widget screen) {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWithValue(fake),
      profileProvider.overrideWith((ref) async => {'role': 'admin'}),
      productsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      brandsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      customersProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      dealersProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      batchesProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      probeBoxesProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      flagDefsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      flagsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      inventoryProvider.overrideWith((ref) async => const <InventoryItem>[]),
      allMovementsProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      allSalesProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      vendorsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      repairsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      itemLabelsProvider.overrideWith((ref) => const <String, String>{}),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: screen,
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int frames = 15]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('records page has its own app bar, tabs and round add button',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const RecordsScreen()));
    await _pumpFrames(tester);

    expect(find.widgetWithText(AppBar, 'Records'), findsOneWidget);
    expect(find.text('Products'), findsOneWidget);

    // the add control is the page's round button, not a full-width bar
    final fab = find.byTooltip('Add product');
    expect(fab, findsOneWidget);
    final box = tester.getSize(fab);
    expect(box.width, 52);
    expect(box.height, 52);
    expect(find.widgetWithText(FilledButton, 'Add product'), findsNothing);

    // the button follows the tab: brands get their own label
    await tester.tap(find.text('Brands'));
    await _pumpFrames(tester);
    expect(find.byTooltip('Add brand'), findsOneWidget);
  });

  testWidgets('reports page lists the sales reports and explains them',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const ReportsScreen()));
    await _pumpFrames(tester);

    await tester.scrollUntilVisible(find.text('Sold sends'), 200);
    await tester.tap(find.text('Sold sends'));
    await _pumpFrames(tester);

    expect(find.textContaining('Only sends marked Sold'), findsOneWidget);
    expect(find.text('Recorded sales'), findsOneWidget);
    expect(find.text('All sales'), findsOneWidget);
    expect(find.text('Download PDF'), findsOneWidget);
  });
}
