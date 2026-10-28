import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';

void main() {
  group('movementSold / movementPaid', () {
    test('reads the sold mark off the reason, paid off the column', () {
      expect(movementSold({'reason': 'Sold'}), isTrue);
      expect(movementSold({'reason': 'Sent to dealer'}), isFalse);
      expect(movementSold(const {}), isFalse);
      expect(movementPaid({'paid': true}), isTrue);
      expect(movementPaid({'paid': false}), isFalse);
      expect(movementPaid(const {}), isFalse);
    });

    test('a marked send reads "Sold to X" in the item history', () {
      expect(
          movementTitle({
            'movement_type': 'Dealer',
            'reason': 'Sold',
            'to_location': 'ABC',
          }),
          'Sold to ABC');
      expect(
          movementTitle({
            'movement_type': 'Customer',
            'reason': 'Sent to customer',
            'to_location': 'XYZ',
          }),
          'Sent to XYZ');
    });
  });

  group('sale amount / sold by', () {
    test('amount reads off the column, blank type reads null', () {
      expect(soldAmountOf({'sale_amount': 45000}), 45000);
      expect(soldAmountOf({'sale_amount': null}), isNull);
      expect(soldAmountOf(const {}), isNull);
      expect(parseSaleAmount(' 45,000 '), 45000);
      expect(parseSaleAmount(''), isNull);
      expect(parseSaleAmount('abc'), isNull);
    });

    test('the person who sold it is trimmed, blank when not recorded', () {
      expect(movementSoldBy({'sold_by': 'Usman Ali'}), 'Usman Ali');
      expect(movementSoldBy({'sold_by': '  Usman  '}), 'Usman');
      expect(movementSoldBy({'sold_by': null}), '');
      expect(movementSoldBy(const {}), '');
    });
  });

  group('sendReason', () {
    test('mirrors the wording create_movement records', () {
      expect(sendReason('Workshop', demo: false), 'Sent to workshop');
      expect(sendReason('Branch', demo: false), 'Sent to lahore branch');
      expect(sendReason('Dealer', demo: false), 'Sent to dealer');
      expect(sendReason('Customer', demo: false), 'Sent to customer');
      expect(sendReason('Dealer', demo: true), 'Sent to dealer (demo)');
      expect(sendReason('Customer', demo: true), 'Sent to customer (demo)');
      // workshop / branch sends are never demos
      expect(sendReason('Workshop', demo: true), 'Sent to workshop');
      expect(sendReason('Branch', demo: true), 'Sent to lahore branch');
    });
  });

  group('kind rules', () {
    test('sold is dealer/customer/branch; outbound adds workshop', () {
      expect(isSoldKind('Dealer'), isTrue);
      expect(isSoldKind('Customer'), isTrue);
      expect(isSoldKind('Branch'), isTrue);
      expect(isSoldKind('Workshop'), isFalse);
      expect(isOutboundKind('Workshop'), isTrue);
      expect(isOutboundKind('Dealer'), isTrue);
      expect(isOutboundKind('Return'), isFalse);
      expect(isOutboundKind('Box'), isFalse);
    });
  });
}
