import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/reports/report_data.dart';

InventoryItem _item(
  int id, {
  String kind = 'machine',
  String? date,
  bool sold = false,
}) {
  return InventoryItem(
    kind: kind,
    id: id,
    code: 'X$id',
    name: 'Item $id',
    status: sold ? 'Sold' : 'Available',
    location: 'Company',
    date: date,
    createdAt: null,
    productId: null,
    vendorId: null,
    assignedMachineId: null,
    boxId: kind == 'probe' ? 1 : null,
    probeType: kind == 'probe' ? 'Convex' : null,
    purchasePrice: null,
  );
}

Map<String, dynamic> _movement(
  int id, {
  String type = 'Dealer',
  String? date,
  int? probeId,
}) {
  return {
    'id': id,
    'movement_type': type,
    'movement_date': date,
    'from_location': 'Company',
    'to_location': 'Customer X',
    'reason': null,
    'notes': null,
    'reference': null,
    'is_demo': false,
    'machine_id': null,
    'probe_id': probeId,
    'printer_id': null,
    'part_id': null,
    'dealers': type == 'Dealer' ? {'name': 'ABC'} : null,
    'customers': type == 'Customer' ? {'name': 'XYZ'} : null,
    'workshops': type == 'Workshop' ? {'name': 'Shop'} : null,
    'profiles': {'display_name': 'Ahmed', 'username': 'ahmed'},
  };
}

void main() {
  final from = DateTime(2026, 1, 1);
  final to = DateTime(2026, 1, 31);

  group('reportDate', () {
    test('reads the shop dd-MM-yyyy format and ISO alike', () {
      expect(reportDate('14-09-2026'), DateTime(2026, 9, 14));
      expect(reportDate('2026-09-14T10:30:00'), DateTime(2026, 9, 14));
      expect(reportDate('Unknown'), isNull);
      expect(reportDate(''), isNull);
      expect(reportDate(null), isNull);
    });
  });

  group('dateInRange', () {
    test('includes both ends and rejects undated rows', () {
      expect(dateInRange('01-01-2026', from, to), isTrue);
      expect(dateInRange('31-01-2026', from, to), isTrue);
      expect(dateInRange('31-12-2025', from, to), isFalse);
      expect(dateInRange('01-02-2026', from, to), isFalse);
      expect(dateInRange('Unknown', from, to), isFalse);
    });
  });

  group('filterStockItems', () {
    test('keeps unsold dated items of the chosen kind only', () {
      final items = [
        _item(1, date: '10-01-2026'),
        _item(2, kind: 'probe', date: '15-01-2026'),
        _item(3, date: '10-06-2026'), // out of range
        _item(4, date: null), // no date
        _item(5, date: '10-01-2026', sold: true), // sold machine
        _item(6, kind: 'part', date: '10-01-2026', sold: true), // sold part stays
      ];
      final all = filterStockItems(items,
          kind: 'All stock', from: from, to: to);
      expect(all.map((item) => item.id), [1, 2, 6]);
      final machines =
          filterStockItems(items, kind: 'Machines', from: from, to: to);
      expect(machines.map((item) => item.id), [1]);
      final probes =
          filterStockItems(items, kind: 'Probes', from: from, to: to);
      expect(probes.map((item) => item.id), [2]);
    });
  });

  group('filterMovementRows', () {
    test('drops legacy, other kinds and rows outside the range', () {
      final rows = [
        _movement(1, type: 'Dealer', date: '10-01-2026'),
        _movement(2, type: 'Workshop', date: '10-01-2026'),
        _movement(3, type: 'Legacy', date: '10-01-2026'),
        _movement(4, type: 'Dealer', date: '10-03-2026'),
        _movement(5, type: 'Dealer', date: null),
        _movement(6, type: 'Return', date: '10-01-2026'),
      ];
      final all = filterMovementRows(rows,
          kind: 'All', from: from, to: to);
      expect(all.map((row) => row['id']), [1, 2, 6]);
      final dealers = filterMovementRows(rows,
          kind: 'Dealer', from: from, to: to);
      expect(dealers.map((row) => row['id']), [1]);
    });

    test('All keeps box moves out; Box moves keeps only them', () {
      final rows = [
        _movement(1, type: 'Dealer', date: '10-01-2026'),
        _movement(2, type: 'Box', date: '10-01-2026', probeId: 7),
        _movement(3, type: 'Unbox', date: '11-01-2026', probeId: 7),
      ];
      final all = filterMovementRows(rows,
          kind: 'All', from: from, to: to);
      expect(all.map((row) => row['id']), [1]);
      final boxMoves = filterMovementRows(rows,
          kind: 'Box moves', from: from, to: to);
      expect(boxMoves.map((row) => row['id']), [2, 3]);
    });
  });

  group('pdfText', () {
    test('turns em dashes and curly quotes into Latin-1 safe ones', () {
      expect(pdfText('WiseTech — Ultrasound'), 'WiseTech - Ultrasound');
      expect(pdfText('don’t “quote”…'), 'don\'t "quote"...');
    });

    test('keeps normal text and marks unreadable runes', () {
      expect(pdfText('Plain text 123'), 'Plain text 123');
      expect(pdfText('عربي'), '????');
    });
  });

  group('report rows', () {
    test('movementReportRow fills party, actor and item labels', () {
      final cells = movementReportRow(
        _movement(9,
            type: 'Dealer', date: '10-01-2026', probeId: 5),
        labels: {'probe:5': 'P5  Probe 5'},
      );
      expect(cells[0], '10-01-2026');
      expect(cells[1], 'Dealer');
      expect(cells[2], 'P5  Probe 5');
      expect(cells[5], 'ABC');
      expect(cells[6], 'Ahmed');
      expect(cells[10], '');
    });

    test('boxReportRow counts the probes inside right now', () {
      final cells = boxReportRow(
        {'id': 1, 'name': 'Box A', 'probe_type': 'Convex', 'notes': 'n'},
        items: [
          _item(1, kind: 'probe'),
          _item(2, kind: 'probe', sold: true), // sold → not inside
          _item(3, kind: 'machine'),
        ],
      );
      expect(cells[0], 'Box A');
      expect(cells[2], '1');
      expect(cells[3], 'X1');
    });

    test('stockReportRow widens with kind, box and machine for All stock', () {
      final vendors = {3: 'Vendor Co'};
      final boxes = {1: 'Box A'};
      final labels = {'machine:8': 'M8  Machine 8'};
      final probe = InventoryItem(
        kind: 'probe',
        id: 5,
        code: 'P5',
        name: 'Probe 5',
        serial: 'SN-5',
        status: 'Available',
        location: 'Company',
        date: '10-01-2026',
        batch: 'BATCH-3',
        createdAt: null,
        productId: null,
        vendorId: 3,
        assignedMachineId: 8,
        boxId: 1,
        probeType: 'Convex',
        purchasePrice: 100,
      );
      final single =
          stockReportRow(probe, single: true, vendors: vendors, boxes: boxes, labels: labels);
      expect(single, hasLength(9));
      expect(single[0], 'P5');
      final all =
          stockReportRow(probe, single: false, vendors: vendors, boxes: boxes, labels: labels);
      expect(all, hasLength(13));
      expect(all[0], 'Probe');
      expect(all[10], 'Box A');
      expect(all[11], 'Convex');
      expect(all[12], 'M8  Machine 8');
      expect(all[8], 'Vendor Co');
    });
  });
}
