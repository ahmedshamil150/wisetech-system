import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/gallery/gallery_data.dart';
import 'package:ultrasound_inventory/features/gallery/gallery_upload_screen.dart';

/// The upload page used to be a bare Column, so it was pushed as a route with
/// no Scaffold: its text fell back to MaterialApp's red/yellow "fallback
/// style" and the page had no app bar. These checks keep the page a real
/// screen.
Widget _app({List<String> batches = const ['Nov 2026', 'Oct 2026']}) {
  return ProviderScope(
    overrides: [
      galleryBatchesProvider.overrideWith((ref) async => batches),
    ],
    child: MaterialApp(
      theme: buildAppTheme(Brightness.light),
      // Deliberately no Scaffold here: the screen must bring its own, the way
      // Navigator does when Gallery pushes it.
      home: const GalleryUploadScreen(),
    ),
  );
}

void main() {
  testWidgets('upload page brings its own Scaffold and app bar', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Upload batch pictures'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Pick a batch'), findsOneWidget);
  });

  testWidgets('hint text uses the app text style, not the fallback style',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final render = tester.renderObject<RenderParagraph>(
      find.textContaining('Pick a batch'),
    );
    final style = (render.text as TextSpan).style!;
    // MaterialApp's fallback style is red, 48px and yellow-underlined.
    expect(style.fontSize, 16);
    expect(style.decoration, isNot(TextDecoration.underline));
    expect(style.color, isNot(const Color(0xD0FF0000)));
  });

  testWidgets('generate code button enables after picking a batch',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    Finder button() => find.widgetWithText(OutlinedButton, 'Generate group code');

    expect(tester.widget<OutlinedButton>(button()).onPressed, isNull);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nov 2026').last);
    await tester.pumpAndSettle();

    expect(tester.widget<OutlinedButton>(button()).onPressed, isNotNull);
  });
}
