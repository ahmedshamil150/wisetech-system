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
  Future<Map<String, dynamic>?> fetchProfile() async => null;

  @override
  Future<void> login(String username, String password) async {}

  @override
  Future<void> signOut() async {}
}

/// One customer-send row on 25-09-2026.
Map<String, dynamic> _row(
  int id,
  String group, {
  int? machine,
  int? probe,
  String type = 'Customer',
  String reason = 'Sent to customer',
  bool paid = false,
  double? amount,
  String soldBy = '',
}) =>
    {
      'id': id,
      'movement_type': type,
      'movement_date': '25-09-2026',
      'to_location': 'Jimmy Sb',
      'group_ref': group,
      'machine_id': machine,
      'probe_id': probe,
      'reason': reason,
      'paid': paid,
      'sale_amount': amount,
      'sold_by': soldBy,
      'is_demo': false,
      'reference': '',
      'actor_id': 'u1',
      'profiles': {'display_name': 'Ahmed'},
    };

/// Three separate sends to Jimmy Sb on one day: the first was sold, the
/// third came back — one movement to the screen, three sends inside it.
final _rows = <Map<String, dynamic>>[
  _row(11, 'send-a',
      machine: 1, reason: 'Sold', paid: true, amount: 90000, soldBy: 'Ali'),
  _row(12, 'send-a',
      probe: 11, reason: 'Sold', paid: true, amount: 90000, soldBy: 'Ali'),
  _row(13, 'send-b', machine: 2),
  _row(14, 'send-b', probe: 12),
  _row(15, 'send-c', machine: 3),
  _row(16, 'send-c', probe: 13),
  _row(21, 'return-c', type: 'Return', machine: 3, reason: 'Returned'),
  _row(22, 'return-c', type: 'Return', probe: 13, reason: 'Returned'),
];

const _labels = <String, String>{
  'machine:1': 'NEMIO 1',
  'probe:11': 'PROBE 11',
  'machine:2': 'NEMIO 2',
  'probe:12': 'PROBE 12',
  'machine:3': 'NEMIO 3',
  'probe:13': 'PROBE 13',
};

Widget _app() {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      movementsProvider.overrideWith((ref) async => _rows),
      allMovementsProvider.overrideWith((ref) async => _rows),
      itemLabelsProvider.overrideWith((ref) => _labels),
      flagsProvider.overrideWith((ref) async => const <Map<String, dynamic>>[]),
      authControllerProvider.overrideWithValue(fake),
      profileProvider.overrideWith((ref) async => null),
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

  testWidgets('three sends on one day read as one movement', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Jimmy Sb'), findsOneWidget);
    expect(find.textContaining('3 sends'), findsOneWidget);
    expect(find.textContaining('6 items'), findsOneWidget);
    expect(find.textContaining('1 movement · 4 items'), findsOneWidget);

    // each send keeps its own marks: sold and paid, then plain unpaid
    expect(find.textContaining('Sold by Ali'), findsOneWidget);
    expect(find.text('Unpaid'), findsOneWidget);
    // the send that came back is not on the live card
    expect(find.text('NEMIO 3'), findsNothing);
  });

  testWidgets('the Returned tab shows the movement and the partial return',
      (tester) async {
    await pumpScreen(tester);
    final chip = find.text('Returned (1)');
    await tester.dragUntilVisible(
        chip, find.byType(ListView).first, const Offset(-150, 0));
    await _pumpFrames(tester);
    await tester.tap(chip);
    await _pumpFrames(tester);

    expect(find.text('Jimmy Sb'), findsOneWidget);
    expect(find.text('2 of 6 items came back from this movement'),
        findsOneWidget);
    expect(find.text('1 movement · 2 items'), findsOneWidget);
    expect(find.text('NEMIO 3'), findsOneWidget);
  });

  testWidgets('opening the card shows every send of the movement',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Jimmy Sb'));
    await _pumpFrames(tester);

    expect(find.text('Still out (4)'), findsOneWidget);
    expect(find.text('Returned (2)'), findsOneWidget);
    expect(find.textContaining('3 sends · 6 items'), findsNWidgets(2));
    // one caption per send, each with its own marks
    expect(find.textContaining('2 items · Sold by Ali'), findsOneWidget);
    expect(find.textContaining('2 items · Unpaid'), findsNWidgets(2));
    expect(find.text('NEMIO 3'), findsOneWidget);
  });
}
