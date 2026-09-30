import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultrasound_inventory/features/common/widgets.dart';

void main() {
  const options = ['Printer X', 'Probe Y', 'Machine Z'];

  Widget wrap(TextEditingController controller) => MaterialApp(
        home: Scaffold(
          body: PickyField(
            controller: controller,
            hint: 'Type a value',
            options: options,
            pickTitle: 'Choose',
          ),
        ),
      );

  testWidgets('typing shows matching suggestions live', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(controller));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'P');
    await tester.pump();

    expect(find.text('Printer X'), findsOneWidget);
    expect(find.text('Probe Y'), findsOneWidget);
    expect(find.text('Machine Z'), findsNothing);

    await tester.enterText(find.byType(TextField), 'h');
    await tester.pump();

    expect(find.text('Printer X'), findsNothing);
    expect(find.text('Probe Y'), findsNothing);
  });

  testWidgets('tapping a suggestion fills the field', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(wrap(controller));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Probe');
    await tester.pump();

    await tester.tap(find.text('Probe Y'));
    await tester.pump();

    expect(controller.text, 'Probe Y');
  });
}
