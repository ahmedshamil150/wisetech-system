import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/inventory/inventory_screen.dart';
import 'package:ultrasound_inventory/features/movements/movements_screen.dart';

Future<void> _pumpFrames(WidgetTester tester, [int frames = 30]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _checkApply({
  required WidgetTester tester,
  required Widget screen,
  required Size size,
  required String label,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester
      .pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(body: screen))));
  await _pumpFrames(tester);

  final filtersButton = find.widgetWithText(OutlinedButton, 'Filters');
  expect(filtersButton, findsOneWidget, reason: '$label: Filters button');
  await tester.tap(filtersButton);
  await _pumpFrames(tester);

  final apply = find.text('Apply');
  expect(apply, findsOneWidget, reason: '$label: Apply exists in sheet');

  final rect = tester.getRect(apply);
  expect(rect.top, greaterThanOrEqualTo(0),
      reason: '$label: Apply top on screen');
  expect(rect.bottom, lessThanOrEqualTo(size.height),
      reason: '$label: Apply bottom on screen (not clipped)');

  await tester.tap(apply, warnIfMissed: true);
  await _pumpFrames(tester);
  expect(find.text('Apply'), findsNothing,
      reason: '$label: Apply closes the sheet');
}

void main() {
  testWidgets('inventory sheet shows Apply on phone', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const InventoryScreen(),
      size: const Size(390, 844),
      label: 'inventory/phone',
    );
  });

  testWidgets('inventory sheet shows Apply on desktop', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const InventoryScreen(),
      size: const Size(1200, 800),
      label: 'inventory/desktop',
    );
  });

  testWidgets('movements sheet shows Apply on phone', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const MovementsScreen(),
      size: const Size(390, 844),
      label: 'movements/phone',
    );
  });

  testWidgets('movements sheet shows Apply on desktop', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const MovementsScreen(),
      size: const Size(1200, 800),
      label: 'movements/desktop',
    );
  });

  testWidgets('inventory sheet on small laptop window', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const InventoryScreen(),
      size: const Size(900, 600),
      label: 'inventory/small-desktop',
    );
  });

  testWidgets('inventory sheet on tiny phone', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const InventoryScreen(),
      size: const Size(360, 640),
      label: 'inventory/tiny-phone',
    );
  });

  testWidgets('movements sheet on small laptop window', (tester) async {
    await _checkApply(
      tester: tester,
      screen: const MovementsScreen(),
      size: const Size(900, 600),
      label: 'movements/small-desktop',
    );
  });

  testWidgets('inventory Apply stays above an open keyboard', (tester) async {
    const keyboardHeight = 300.0;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: Scaffold(body: InventoryScreen()))));
    await _pumpFrames(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Filters'));
    await _pumpFrames(tester);

    final apply = find.text('Apply');
    expect(apply, findsOneWidget, reason: 'Apply exists with keyboard open');
    final rect = tester.getRect(apply);
    expect(rect.bottom, lessThanOrEqualTo(844 - keyboardHeight),
        reason: 'Apply stays above the keyboard');
    await tester.tap(apply, warnIfMissed: true);
    await _pumpFrames(tester);
    expect(find.text('Apply'), findsNothing);
  });
}
