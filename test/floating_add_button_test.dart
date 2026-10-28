import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/auth/auth_controller.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/inventory/inventory_screen.dart';
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

Widget _app(Widget screen) {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      movementsProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      allMovementsProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      inventoryProvider.overrideWith((ref) async => const <InventoryItem>[]),
      probeBoxesProvider
          .overrideWith((ref) async => const <Map<String, dynamic>>[]),
      allItemsProvider.overrideWith((ref) async => const <InventoryItem>[]),
      itemLabelsProvider.overrideWith((ref) => const <String, String>{}),
      flagsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      authControllerProvider.overrideWithValue(fake),
      profileProvider.overrideWith((ref) async => {'role': 'admin'}),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: screen),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<void> pump(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(screen));
    await _pumpFrames(tester);
  }

  Rect rectOf(WidgetTester tester, String tooltip) =>
      tester.getRect(find.byTooltip(tooltip));

  testWidgets('the new movement button floats at the bottom right',
      (tester) async {
    await pump(tester, const MovementsScreen());

    final fab = rectOf(tester, 'New movement');
    expect(fab.width, 52);
    expect(fab.height, 52);
    expect(fab.right, closeTo(390 - 16, 0.5));
    expect(fab.bottom, closeTo(844 - 16, 0.5));
  });

  testWidgets('inventory has two round buttons: new stock and buy local',
      (tester) async {
    await pump(tester, const InventoryScreen());

    final add = rectOf(tester, 'Add to inventory');
    final local = rectOf(tester, 'Buy local');
    expect(add.width, 52);
    expect(local.width, 52);
    // stacked in the corner, the new-stock plus nearest the thumb
    expect(local.bottom, closeTo(add.top - 12, 0.5));
    expect(add.right, closeTo(390 - 16, 0.5));
    expect(add.bottom, closeTo(844 - 16, 0.5));
  });
}
