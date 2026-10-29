import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ultrasound_inventory/core/theme.dart';
import 'package:ultrasound_inventory/features/auth/auth_controller.dart';
import 'package:ultrasound_inventory/features/shell/profile_screen.dart';

class _FakeAuth implements AuthController {
  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  User? get currentUser => null;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => {'role': 'viewer'};

  @override
  Future<void> login(String username, String password) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets('a viewer opens the manual from the profile', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authControllerProvider.overrideWithValue(_FakeAuth()),
        profileProvider.overrideWith((ref) async => {
              'username': 'hanif',
              'display_name': 'Hanif',
              'role': 'viewer',
              'created_at': '2026-01-05T10:00:00',
            }),
      ],
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: const ProfileScreen(),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Records'), findsNothing);

    await tester.tap(find.text('Manual'));
    await tester.pumpAndSettle();

    expect(find.text('Signing in'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Movements'), 200);
    expect(find.text('Movements'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Reports'), 200);
    expect(find.text('Reports'), findsOneWidget);
  });
}
