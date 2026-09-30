import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/username.dart';

class AuthController {
  AuthController(this._client);

  final SupabaseClient _client;

  SupabaseClient get client => _client;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  User? get currentUser => _client.auth.currentUser;

  Future<void> login(String username, String password) async {
    await _client.auth.signInWithPassword(
      email: Username.toEmail(username),
      password: password,
    );
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<Map<String, dynamic>?> fetchProfile() async {
    final user = currentUser;
    if (user == null) return null;
    final row = await _client
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle();
    if (row != null) return row;
    final username = Username.fromEmail(user.email);
    final fallback = <String, dynamic>{
      'id': user.id,
      'username': username,
      'display_name': username,
    };
    try {
      await _client.from('profiles').upsert(fallback, onConflict: 'id');
    } catch (_) {
      return fallback;
    }
    return fallback;
  }
}

final supabaseClientProvider = Provider<SupabaseClient>(
  (_) => Supabase.instance.client,
);

final authControllerProvider = Provider<AuthController>(
  (ref) => AuthController(ref.read(supabaseClientProvider)),
);

final authStateProvider = StreamProvider<AuthState>(
  (ref) => ref.read(authControllerProvider).authStateChanges,
);

final profileProvider = FutureProvider<Map<String, dynamic>?>(
  (ref) => ref.read(authControllerProvider).fetchProfile(),
);

/// `true` only for admin accounts. Viewers are read-only everywhere except
/// movements (see supabase/migrations/0003_roles_and_movements.sql).
final isAdminProvider = Provider<bool>((ref) {
  final profile = ref.watch(profileProvider);
  return profile.maybeWhen(
    data: (row) => row?['role'] == 'admin',
    orElse: () => false,
  );
});
