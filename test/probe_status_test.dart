import 'package:flutter_test/flutter_test.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/inventory/inventory_screen.dart';

void main() {
  test('dealer probe remains under its linked machine in kit grouping', () {
    final machine = InventoryItem(
      kind: 'machine',
      id: 92,
      code: '94T',
      name: 'PROSOUND ALPHA 7',
      status: 'With Dealer',
      location: 'jimmy sb',
    );
    final probe = InventoryItem(
      kind: 'probe',
      id: 178,
      code: '94T',
      name: 'UST-52105',
      serial: 'X0059580',
      status: 'With Dealer',
      location: 'jimmy sb',
      assignedMachineId: 92,
    );

    final entries = arrangeAsKits([machine, probe]);

    expect(entries.map((entry) => entry.$1.kind).toList(), [
      'machine',
      'probe',
    ]);
    expect(entries[1].$2, isTrue);
    expect(probe.displayStatus, 'With Dealer');
  });

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
