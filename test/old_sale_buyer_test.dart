import 'package:flutter_test/flutter_test.dart';
import 'package:ultrasound_inventory/features/old/old_data.dart';
import 'package:ultrasound_inventory/features/sales/sales_screen.dart';

void main() {
  group('oldSalePartyNote', () {
    test('a dealer sale round-trips through the buyer parser', () {
      final row = <String, dynamic>{
        'notes': oldSalePartyNote('dealer', 'jimmy sb'),
      };
      expect(oldSaleBuyer(row).name, 'jimmy sb');
      expect(oldSaleBuyer(row).kind, 'Dealer');
    });

    test('branch and customer tags parse too', () {
      expect(
        oldSaleBuyer(<String, dynamic>{
          'notes': oldSalePartyNote('branch', 'Lahore branch'),
        }).kind,
        'Branch',
      );
      expect(
        oldSaleBuyer(<String, dynamic>{
          'notes': oldSalePartyNote('customer', 'dr sajjad ali jhang'),
        }).kind,
        'Customer',
      );
    });

    test('the tag sits above the sellers own notes lines', () {
      final row = <String, dynamic>{
        'notes': '${oldSalePartyNote('dealer', 'ali traders')}\npaid in full',
      };
      expect(oldSaleBuyer(row).name, 'ali traders');
    });

    test('a linked customers row wins over any notes tag', () {
      final row = <String, dynamic>{
        'customers': {'name': 'Dr Sajjad'},
        'notes': oldSalePartyNote('dealer', 'someone else'),
      };
      expect(oldSaleBuyer(row).name, 'Dr Sajjad');
      expect(oldSaleBuyer(row).kind, 'Customer');
    });

    test('the unknown-legacy-customer fallback still reads', () {
      expect(
        oldSaleBuyer(<String, dynamic>{
          'notes': 'Unknown legacy customer (old import)',
        }).name,
        'Unknown legacy customer',
      );
    });

    test('a sale with no buyer at all reads as empty, not a crash', () {
      expect(oldSaleBuyer(<String, dynamic>{}).name, '');
      expect(oldSaleBuyer(<String, dynamic>{'notes': null}).kind, '');
    });
  });

  group('oldDisplayToIso', () {
    test('the sales date field stores yyyy-MM-dd', () {
      expect(oldDisplayToIso('06-10-2026'), '2026-10-06');
      expect(oldDisplayToIso('06-10'), '06-10'); // untouched if malformed
    });
  });
}
