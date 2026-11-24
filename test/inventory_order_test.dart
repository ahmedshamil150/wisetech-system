import 'package:flutter_test/flutter_test.dart';
import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/inventory/inventory_screen.dart';

InventoryItem _item({
  required String kind,
  required int id,
  DateTime? added,
  String? code,
  int? machine,
  String batch = 'BATCH-U',
}) => InventoryItem(
  kind: kind,
  id: id,
  code: code ?? '$kind-$id',
  name: 'name',
  status: 'In Stock',
  location: 'Company',
  batch: batch,
  createdAt: added,
  assignedMachineId: machine,
);

List<String> _codes(List<(InventoryItem, bool)> entries) => [
  for (final entry in entries) entry.$1.code,
];

void main() {
  test('newest machine is first even when the audit order ranks it lower', () {
    final local = _item(
      kind: 'machine',
      id: 1,
      code: 'L1',
      batch: 'BATCH-LOCAL',
      added: DateTime(2026, 1, 1),
    );
    final fresh = _item(
      kind: 'machine',
      id: 2,
      code: '1U',
      added: DateTime(2026, 3, 1),
    );

    final entries = arrangeAsKits(
      [local, fresh],
      machineAreaRanks: {1: 0, 2: 4},
    );

    expect(_codes(entries), ['1U', 'L1']);
  });

  test('a part added later shows above older machine groups', () {
    final machine = _item(
      kind: 'machine',
      id: 5,
      code: '3T',
      added: DateTime(2026, 1, 10),
    );
    final part = _item(
      kind: 'part',
      id: 9,
      code: 'PART-1',
      added: DateTime(2026, 3, 2),
    );

    final entries = arrangeAsKits([machine, part]);

    expect(_codes(entries), ['PART-1', '3T']);
    expect(entries.every((entry) => !entry.$2), isTrue);
  });

  test('attaching a fresh probe lifts its older machine above the rest', () {
    final mine = _item(
      kind: 'machine',
      id: 1,
      code: '1U',
      added: DateTime(2026, 1, 1),
    );
    final other = _item(
      kind: 'machine',
      id: 2,
      code: '2U',
      added: DateTime(2026, 2, 1),
    );
    final probe = _item(
      kind: 'probe',
      id: 3,
      code: '1U',
      added: DateTime(2026, 3, 1),
      machine: 1,
    );

    final entries = arrangeAsKits([mine, other, probe]);

    expect(_codes(entries), ['1U', '1U', '2U']);
    expect(entries.map((entry) => entry.$2).toList(), [false, true, false]);
  });

  test('a kit keeps printer then probes under its machine', () {
    final machine = _item(
      kind: 'machine',
      id: 1,
      code: '1U',
      added: DateTime(2026, 1, 1),
    );
    final probe = _item(
      kind: 'probe',
      id: 2,
      code: '1U',
      added: DateTime(2026, 2, 1),
      machine: 1,
    );
    final printer = _item(
      kind: 'printer',
      id: 3,
      code: '1U',
      added: DateTime(2026, 3, 1),
      machine: 1,
    );

    final entries = arrangeAsKits([machine, probe, printer]);

    expect(entries.map((entry) => entry.$1.kind).toList(), [
      'machine',
      'printer',
      'probe',
    ]);
  });

  test('rows added at the same moment keep the audit area order', () {
    final when = DateTime(2026, 1, 1);
    final basement = _item(kind: 'machine', id: 1, code: '9T', added: when);
    final local = _item(
      kind: 'machine',
      id: 2,
      code: 'L4',
      batch: 'BATCH-LOCAL',
      added: when,
    );

    final entries = arrangeAsKits(
      [basement, local],
      machineAreaRanks: {1: 3, 2: 0},
    );

    expect(_codes(entries), ['L4', '9T']);
  });
}
