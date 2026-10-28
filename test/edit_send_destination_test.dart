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

/// One customer send on 25-09-2026 that was recorded to Jimmy Sb.
final _rows = <Map<String, dynamic>>[
  {
    'id': 11,
    'movement_type': 'Customer',
    'movement_date': '25-09-2026',
    'to_location': 'Jimmy Sb',
    'group_ref': 'send-a',
    'machine_id': 1,
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
    'customers': {'name': 'Jimmy Sb'},
    'dealers': null,
    'profiles': {'display_name': 'Ahmed'},
  },
];

const _labels = <String, String>{'machine:1': 'NEMIO 1'};

Widget _app() {
  final fake = _FakeAuth();
  return ProviderScope(
    overrides: [
      movementsProvider.overrideWith((ref) async => _rows),
      allMovementsProvider.overrideWith((ref) async => _rows),
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

void main() {
  testWidgets('the Edit sheet can move a send from a customer to a dealer',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app());
    await _pumpFrames(tester);

    await tester.tap(find.textContaining('Jimmy Sb'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Edit'));
    await _pumpFrames(tester);

    // where it went is editable, with the party it was recorded to
    expect(find.text('Sent to'), findsOneWidget);
    expect(find.text('Send as demo'), findsOneWidget);

    // a branch trip is a company location — no party, no demo
    await tester.tap(find.text('Branch').last);
    await _pumpFrames(tester);
    expect(find.text('Send as demo'), findsNothing);
    expect(
        find.textContaining('The Lahore branch'), findsOneWidget);

    // and on to a dealer, where a party and the demo mark come back
    await tester.tap(find.text('Dealer').last);
    await _pumpFrames(tester);
    expect(find.text('Send as demo'), findsOneWidget);
    expect(find.text('Workshop'), findsOneWidget);
  });
}
