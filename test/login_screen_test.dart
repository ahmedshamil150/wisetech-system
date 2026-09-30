import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ultrasound_inventory/features/auth/auth_controller.dart';
import 'package:ultrasound_inventory/features/auth/login_screen.dart';

class FakeAuthController implements AuthController {
  int loginCalls = 0;
  String? lastUsername;
  String? lastPassword;

  @override
  SupabaseClient get client => throw UnimplementedError();

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  User? get currentUser => null;

  @override
  Future<Map<String, dynamic>?> fetchProfile() async => null;

  @override
  Future<void> login(String username, String password) async {
    loginCalls++;
    lastUsername = username;
    lastPassword = password;
  }

  @override
  Future<void> signOut() async {}
}

Future<FakeAuthController> pumpLogin(WidgetTester tester) async {
  final fake = FakeAuthController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authControllerProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  return fake;
}

void main() {
  testWidgets('renders username and password fields', (tester) async {
    await pumpLogin(tester);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('blocks empty submission with validation', (tester) async {
    final fake = await pumpLogin(tester);
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Username is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
    expect(fake.loginCalls, 0);
  });

  testWidgets('submits normalized username', (tester) async {
    final fake = await pumpLogin(tester);
    await tester.enterText(find.byType(TextFormField).first, '  Ahmed_1 ');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(fake.loginCalls, 1);
    expect(fake.lastUsername, 'ahmed_1');
    expect(fake.lastPassword, 'secret123');
  });
}
