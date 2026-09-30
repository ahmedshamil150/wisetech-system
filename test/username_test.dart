import 'package:flutter_test/flutter_test.dart';
import 'package:ultrasound_inventory/core/username.dart';

void main() {
  group('Username.toEmail', () {
    test('maps username to internal email', () {
      expect(Username.toEmail('Ahmed_1'), 'ahmed_1@wisetech.app');
    });

    test('trims and lowercases', () {
      expect(Username.toEmail('  Sara.K  '), 'sara.k@wisetech.app');
    });
  });

  group('Username.validate', () {
    test('rejects empty', () {
      expect(Username.validate('   '), isNotNull);
    });

    test('rejects invalid characters', () {
      expect(Username.validate('ahmed hasan'), isNotNull);
      expect(Username.validate('ahmed@x'), isNotNull);
    });

    test('accepts valid usernames', () {
      expect(Username.validate('ahmed_1'), isNull);
      expect(Username.validate('Sara.K'), isNull);
    });
  });

  group('Username.validatePassword', () {
    test('requires 6+ characters', () {
      expect(Username.validatePassword(''), isNotNull);
      expect(Username.validatePassword('12345'), isNotNull);
      expect(Username.validatePassword('123456'), isNull);
    });
  });

  group('Username.fromEmail', () {
    test('extracts local part', () {
      expect(Username.fromEmail('member1@wisetech.app'), 'member1');
      expect(Username.fromEmail(null), '');
    });
  });
}
