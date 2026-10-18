import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';

InventoryItem _probe(
  int id, {
  String status = 'Available',
  int? boxId,
  int? machineId,
  String location = 'Company',
}) {
  return InventoryItem(
    kind: 'probe',
    id: id,
    code: 'P$id',
    name: 'Probe $id',
    status: status,
    location: location,
    boxId: boxId,
    assignedMachineId: machineId,
  );
}

void main() {
  group('boxAddCandidates', () {
    final box = <String, dynamic>{'id': 1, 'name': 'H12', 'probe_type': 'Linear'};

    test('includes a probe that is With Machine', () {
      final items = [_probe(1, status: 'With Machine', machineId: 81)];
      final out = boxAddCandidates(items, box);
      expect(out, hasLength(1));
      expect(out.single.id, 1);
    });

    test('ignores the box probe type — any type may go in any box', () {
      final items = [_probe(1, status: 'Available')];
      final out = boxAddCandidates(items, box);
      expect(out, hasLength(1));
    });

    test('excludes probes already in a box', () {
      final items = [
        _probe(1, boxId: 2),
        _probe(2, boxId: null),
      ];
      final out = boxAddCandidates(items, box);
      expect(out.map((i) => i.id), [2]);
    });

    test('excludes Sold / Archived / With Customer and non-probes', () {
      final items = [
        _probe(1, status: 'Sold'),
        _probe(2, status: 'Archived'),
        _probe(3, status: 'With Customer'),
        const InventoryItem(
          kind: 'machine',
          id: 9,
          code: 'M9',
          name: 'Machine',
          status: 'Available',
          location: 'Company',
        ),
      ];
      expect(boxAddCandidates(items, box), isEmpty);
    });
  });

  group('movementTitle', () {
    test('Box movement reads as placed in the box', () {
      expect(
        movementTitle({
          'movement_type': 'Box',
          'to_location': 'H12',
          'from_location': 'Rawalpindi',
        }),
        'Placed in box H12',
      );
    });

    test('Unbox movement reads as took out of the box', () {
      expect(
        movementTitle({
          'movement_type': 'Unbox',
          'from_location': 'H12',
          'to_location': 'Company',
        }),
        'Took out of box H12',
      );
    });

    test('Return / Sold / Send still read as before', () {
      expect(
          movementTitle({'movement_type': 'Return', 'to_location': 'Company'}),
          'Returned to Company');
      expect(
          movementTitle({
            'movement_type': 'Dealer',
            'to_location': 'ABC',
            'reason': 'Sold to dealer',
          }),
          'Sold to ABC');
      expect(
          movementTitle({'movement_type': 'Dealer', 'to_location': 'ABC'}),
          'Sent to ABC');
    });
  });

  group('isBoxMovement', () {
    test('flags Box and Unbox only', () {
      expect(isBoxMovement({'movement_type': 'Box'}), isTrue);
      expect(isBoxMovement({'movement_type': 'Unbox'}), isTrue);
      expect(isBoxMovement({'movement_type': 'Dealer'}), isFalse);
      expect(isBoxMovement({'movement_type': 'Return'}), isFalse);
    });
  });
}
