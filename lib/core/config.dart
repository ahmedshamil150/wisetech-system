/// Supabase connection settings.
///
/// The values below are the project defaults so every build (debug or
/// release, with or without --dart-define) talks to the live backend.
/// Pass `--dart-define=SUPABASE_URL=...` / `--dart-define=SUPABASE_ANON_KEY=...`
/// to override them for another environment.
abstract class Config {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://yygbkgtxuuyuidkqrqqw.supabase.co',
  );

  /// Publishable / anon key - safe to ship inside the app (RLS is enabled).
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl5Z2JrZ3R4dXV5dWlka3FycXF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA1ODgzMTcsImV4cCI6MjEwNjE2NDMxN30.BZnxLwFddF9dsfNAJwLQnULOCCd_YD-X3EetzocTKqA',
  );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
