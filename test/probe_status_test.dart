import 'package:flutter_test/flutter_test.dart';
import 'package:ultrasound_inventory/features/data/data.dart';

void main() {
  group('displayStatusFor', () {
    String status({
      String kind = 'probe',
      required String value,
      String location = 'Company',
      int? machine,
      int? box,
    }) => displayStatusFor(
      kind: kind,
      status: value,
      location: location,
      assignedMachineId: machine,
      boxId: box,
    );

    test('a free probe reads In Stock, never a stale outbound status', () {
      expect(status(value: 'Available'), 'In Stock');
      expect(status(value: 'With Machine'), 'In Stock');
      expect(status(value: 'With Customer'), 'In Stock');
      expect(status(value: 'With Dealer'), 'In Stock');
    });

    test('a probe on a machine reads With Machine', () {
      expect(status(value: 'Available', machine: 12), 'With Machine');
      expect(status(value: 'With Machine', machine: 12), 'With Machine');
    });

    test('a boxed probe reads In Stock even if its status is stale', () {
      expect(status(value: 'Available', box: 3), 'In Stock');
      expect(status(value: 'With Customer', box: 3), 'In Stock');
    });

    test('a genuine send keeps its status', () {
      expect(
        status(value: 'With Customer', location: 'Rasheed sb'),
        'With Customer',
      );
      expect(
        status(value: 'With Dealer', location: 'BASIT SB'),
        'With Dealer',
      );
    });

    test('a probe sent out alone keeps its outbound status over a stale '
        'machine link', () {
      expect(
        status(value: 'With Customer', location: 'IDC', machine: 9),
        'With Customer',
      );
      expect(
        status(value: 'With Dealer', location: 'jimmy sb', machine: 9),
        'With Dealer',
      );
    });

    test('Sold and Archived always win', () {
      expect(status(value: 'Sold', machine: 12), 'Sold');
      expect(status(value: 'Archived', box: 3), 'Archived');
    });

    test('machines keep their own status', () {
      expect(status(kind: 'machine', value: 'In Stock'), 'In Stock');
      expect(status(kind: 'machine', value: 'With Customer'), 'With Customer');
    });
  });
}
