import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/theme.dart';
import 'core/theme_controller.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screen.dart';
import 'features/data/data_era.dart';
import 'features/era/era_choice_screen.dart';
import 'features/shell/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  initialThemeMode = switch (prefs.getString('themeMode')) {
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => ThemeMode.light,
  };
  // Remember the era choice so providers can read it before the first frame.
  initialDataEra = storedDataEra(prefs.getString('dataEra'));
  if (!Config.isConfigured) {
    runApp(const MissingConfigApp());
    return;
  }
  await Supabase.initialize(
    url: Config.supabaseUrl,
    publishableKey: Config.supabaseAnonKey,
  );
  runApp(const ProviderScope(child: UltrasoundInventoryApp()));
}

class UltrasoundInventoryApp extends ConsumerWidget {
  const UltrasoundInventoryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'WTS',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: themeMode,
      home: const AuthGate(),
    );
  }
}

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authStateProvider);
    return auth.when(
      loading: () => const _SplashScreen(),
      error: (error, stack) => const LoginScreen(),
      data: (state) {
        if (state.session == null) return const LoginScreen();
        // Admins who have not picked an era yet see the choice screen first.
        final isAdmin = ref.watch(isAdminProvider);
        final eraChoiceMade = ref.watch(eraChoiceMadeProvider);
        if (isAdmin && !eraChoiceMade) {
          return const EraChoiceScreen();
        }
        return const AppShell();
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child:
                  Image.asset('assets/wts-icon.png', width: 64, height: 64),
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class MissingConfigApp extends StatelessWidget {
  const MissingConfigApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'Supabase is not configured.\n\n'
              'Run with:\n'
              'flutter run '
              '--dart-define=SUPABASE_URL=... '
              '--dart-define=SUPABASE_ANON_KEY=...',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}
