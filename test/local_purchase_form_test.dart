import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/common/widgets.dart';
import 'package:ultrasound_inventory/features/inventory/local_purchase_form.dart';

Future<void> _pumpFrames(WidgetTester tester, [int frames = 30]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _openForm(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: const Scaffold(body: LocalPurchaseForm()),
    ),
  ));
  await _pumpFrames(tester);
}

void main() {
  testWidgets('chips control which item sections show', (tester) async {
    await _openForm(tester);

    // Machine is on by default: one model field and the generated ID row.
    expect(find.byType(PickyField), findsOneWidget);
    expect(find.text('ID (generated)'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Probe'));
    await _pumpFrames(tester);
    expect(find.byType(PickyField), findsNWidgets(2));
    expect(find.textContaining('shares the machine'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Printer'));
    await _pumpFrames(tester);
    expect(find.byType(PickyField), findsNWidgets(3));
    expect(find.textContaining('shares the machine'), findsNWidgets(2));

    // Machine off: the two standalone items stay, so the machine-only ID
    // row and the linking hints go away.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Machine'));
    await _pumpFrames(tester);
    expect(find.byType(PickyField), findsNWidgets(2));
    expect(find.text('ID (generated)'), findsNothing);
    expect(find.textContaining('shares the machine'), findsNothing);
  });

  testWidgets('save validates the seller and at least one item',
      (tester) async {
    await _openForm(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pumpFrames(tester);
    expect(find.text('Seller name is required.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Ali');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Machine'));
    await _pumpFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pumpFrames(tester);
    expect(
        find.text('Pick at least one item — machine, probe, printer or part.'),
        findsOneWidget);
  });

  testWidgets('save asks for a model per selected item', (tester) async {
    await _openForm(tester);
    await tester.enterText(find.byType(TextField).first, 'Ali');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Probe'));
    await _pumpFrames(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pumpFrames(tester);
    expect(find.text('Machine model is required.'), findsOneWidget);
  });

  testWidgets('the probe section can hold several probes', (tester) async {
    await _openForm(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Probe'));
    await _pumpFrames(tester);
    expect(find.byType(PickyField), findsNWidgets(2));

    final add = find.widgetWithText(OutlinedButton, 'Add another probe');
    await tester.ensureVisible(add);
    await _pumpFrames(tester);
    await tester.tap(add);
    await _pumpFrames(tester);

    expect(find.byType(PickyField), findsNWidgets(3));
    expect(find.text('Probes'), findsOneWidget);
    expect(find.text('Probe 2'), findsOneWidget);

    // Removing the extra probe drops back to the plain single layout.
    final remove = find.byIcon(Icons.close);
    await tester.ensureVisible(remove.last);
    await _pumpFrames(tester);
    await tester.tap(remove.last);
    await _pumpFrames(tester);

    expect(find.byType(PickyField), findsNWidgets(2));
    expect(find.text('Probes'), findsNothing);
    expect(find.text('Probe 2'), findsNothing);
  });

  testWidgets('save names the probe that is missing a model',
      (tester) async {
    await _openForm(tester);
    await tester.enterText(find.byType(TextField).first, 'Ali');

    await tester.tap(find.widgetWithText(ChoiceChip, 'Probe'));
    await _pumpFrames(tester);
    final add = find.widgetWithText(OutlinedButton, 'Add another probe');
    await tester.ensureVisible(add);
    await _pumpFrames(tester);
    await tester.tap(add);
    await _pumpFrames(tester);

    final models = find.byType(PickyField);
    await tester.enterText(models.at(0), 'GE Logiq e10');
    await tester.enterText(models.at(1), 'GE 12L');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pumpFrames(tester);
    expect(find.text('Probe 2 model is required.'), findsOneWidget);
  });

  testWidgets('the parts section can hold several parts', (tester) async {
    await _openForm(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Part'));
    await _pumpFrames(tester);
    // machine + one part line
    expect(find.byType(PickyField), findsNWidgets(2));

    final add = find.widgetWithText(OutlinedButton, 'Add another part');
    await tester.ensureVisible(add);
    await _pumpFrames(tester);
    await tester.tap(add);
    await _pumpFrames(tester);

    expect(find.byType(PickyField), findsNWidgets(3));
    expect(find.text('Parts'), findsOneWidget);
    expect(find.text('Part 2'), findsOneWidget);

    // Removing the extra part drops back to the plain single layout.
    final remove = find.byIcon(Icons.close);
    await tester.ensureVisible(remove.last);
    await _pumpFrames(tester);
    await tester.tap(remove.last);
    await _pumpFrames(tester);

    expect(find.byType(PickyField), findsNWidgets(2));
    expect(find.text('Parts'), findsNothing);
    expect(find.text('Part 2'), findsNothing);
  });

  testWidgets('save asks for a name per selected part', (tester) async {
    await _openForm(tester);
    await tester.enterText(find.byType(TextField).first, 'Ali');

    // machine off, so the parts validation is what answers
    await tester.tap(find.widgetWithText(ChoiceChip, 'Machine'));
    await _pumpFrames(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Part'));
    await _pumpFrames(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pumpFrames(tester);
    expect(find.text('Part name is required.'), findsOneWidget);
  });
}
