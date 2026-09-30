abstract class Username {
  static const String emailDomain = 'wisetech.app';

  static String normalize(String raw) => raw.trim().toLowerCase();

  static String toEmail(String raw) => '${normalize(raw)}@$emailDomain';

  static String? validate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return 'Username is required';
    if (!RegExp(r'^[a-zA-Z0-9_.]+$').hasMatch(value)) {
      return 'Only letters, numbers, dot and underscore';
    }
    return null;
  }

  static String? validatePassword(String raw) {
    if (raw.isEmpty) return 'Password is required';
    if (raw.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  static String fromEmail(String? email) {
    if (email == null || email.isEmpty) return '';
    return email.split('@').first;
  }
}
