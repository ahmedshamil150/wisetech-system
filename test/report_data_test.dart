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
  int? oldSourceId,
  String group = '',
  bool paid = false,
  String? reason,
  double? saleAmount,
  String soldBy = '',
}) {
  return {
    'id': id,
    'movement_type': type,
    'movement_date': date,
    'from_location': 'Company',
    'to_location': 'Customer X',
    'group_ref': group,
    'paid': paid,
    'sale_amount': saleAmount,
    'sold_by': soldBy,
    'reason': reason,
    'notes': null,
    'reference': null,
    'is_demo': false,
    'old_source_id': oldSourceId,
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

    test('reportDateText writes every shape as dd-MM-yyyy', () {
      expect(reportDateText('14-09-2026'), '14-09-2026');
      expect(reportDateText('2026-09-14'), '14-09-2026');
      expect(reportDateText('2026-09-14T10:30:00'), '14-09-2026');
      expect(reportDateText('Unknown'), 'Unknown');
      expect(reportDateText(null), '');
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
    test('drops legacy, old-side imports, other kinds and rows outside the range', () {
      final rows = [
        _movement(1, type: 'Dealer', date: '10-01-2026'),
        _movement(2, type: 'Workshop', date: '10-01-2026'),
        _movement(3, type: 'Legacy', date: '10-01-2026'),
        _movement(4, type: 'Dealer', date: '10-03-2026'),
        _movement(5, type: 'Dealer', date: null),
        _movement(6, type: 'Return', date: '10-01-2026'),
        _movement(7, type: 'Customer', date: '10-01-2026', oldSourceId: 9001),
      ];
      final all = filterMovementRows(rows,
          kind: 'All', from: from, to: to);
      expect(all.map((row) => row['id']), [1, 2, 6]);
      final dealers = filterMovementRows(rows,
          kind: 'Dealer', from: from, to: to);
      expect(dealers.map((row) => row['id']), [1]);
    });

    test('keeps imported rows dated on or after the split', () {
      final rows = [
        _movement(1, type: 'Customer', date: '13-09-2026', oldSourceId: 1),
        _movement(2, type: 'Customer', date: '14-09-2026', oldSourceId: 2),
        _movement(3, type: 'Dealer', date: '29-09-2026', oldSourceId: 3),
        _movement(4, type: 'Customer', date: null, oldSourceId: 4),
      ];
      final kept = filterMovementRows(rows,
          kind: 'All', from: DateTime(2026, 9, 1), to: DateTime(2026, 9, 30));
      expect(kept.map((row) => row['id']), [2, 3]);
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

  group('filterRepairRows', () {
    test('keeps jobs received inside the range only', () {
      final rows = [
        {'id': 1, 'received_at': '10-01-2026'},
        {'id': 2, 'received_at': '10-06-2026'}, // out of range
        {'id': 3, 'received_at': null}, // no date
        {'id': 4, 'received_at': '31-01-2026'}, // both ends included
      ];
      final filtered =
          filterRepairRows(rows, from: from, to: to);
      expect(filtered.map((row) => row['id']), [1, 4]);
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
    test('movementReportRow reads one send: items, destination, actor', () {
      final cells = movementReportRow(
        [
          _movement(9,
              type: 'Dealer', date: '10-01-2026', probeId: 5),
        ],
        labels: {'probe:5': 'Probe 5 (SN-5)'},
      );
      expect(cells, hasLength(9));
      expect(cells[0], '10-01-2026');
      expect(cells[1], 'Dealer');
      expect(cells[2], 'Probe 5 (SN-5)');
      expect(cells[3], 'Customer X');
      expect(cells[4], '');
      expect(cells[5], '');
      expect(cells[6], 'Unpaid');
      expect(cells[7], 'Ahmed');
      // the party is not a column of its own any more
      expect(cells, isNot(contains('ABC')));
    });

    test('a blank destination falls back to the party name', () {
      final row = _movement(10, type: 'Dealer', date: '10-01-2026');
      row['to_location'] = '';
      final cells = movementReportRow([row], labels: const {});
      expect(cells[3], 'ABC');
    });

    test('a sold send carries its amount and paid flag', () {
      final cells = movementReportRow(
        [
          _movement(1,
              type: 'Customer',
              date: '10-01-2026',
              group: 'g1',
              paid: true,
              reason: 'Sold',
              saleAmount: 45000,
              soldBy: 'Sami'),
          _movement(2,
              type: 'Customer',
              date: '10-01-2026',
              probeId: 5,
              group: 'g1',
              paid: true,
              reason: 'Sold',
              saleAmount: 45000,
              soldBy: 'Sami'),
        ],
        labels: {'probe:5': 'Probe 5 (SN-5)'},
      );
      expect(cells[2], 'Probe 5 (SN-5)');
      expect(cells[4], 'Sold');
      expect(cells[5], '45,000');
      expect(cells[6], 'Paid');
      expect(cells[7], 'Ahmed');
    });

    test('reportSendGroups keeps a group together and a lone row alone', () {
      final groups = reportSendGroups([
        _movement(1, group: 'g1'),
        _movement(2, group: ''),
        _movement(3, group: 'g1'),
      ]);
      expect(groups.map((g) => g.map((r) => r['id']).toList()), [
        [1, 3],
        [2],
      ]);
    });

    test('reportMoney groups thousands and drops the whole tail', () {
      expect(reportMoney(null), '');
      expect(reportMoney(45000), '45,000');
      expect(reportMoney(1234567.5), '1,234,567.50');
      expect(reportMoney(-500), '-500');
    });

    test('salesReportRow fills buyer, amount and invoice', () {
      final cells = salesReportRow((
        source: 'sale',
        date: '10-01-2026',
        buyer: 'XYZ',
        buyerKind: 'Customer',
        summary: 'Mindray DP',
        total: 45000,
        soldBy: '',
        paid: true,
        imported: true,
        row: {
          'invoice_reference': 'INV-1',
          'old_trno': '',
          'notes': 'party:customer:XYZ\nPaid in full',
        },
        rows: const <Map<String, dynamic>>[],
      ));
      expect(cells, hasLength(8));
      expect(cells[0], '10-01-2026');
      expect(cells[1], 'XYZ');
      expect(cells[3], '45,000');
      expect(cells[5], 'Paid');
      expect(cells[6], 'INV-1');
      expect(cells[7], 'Paid in full');
    });

    test('recorded sale items read name-first with their serial', () {
      final cells = salesReportRow(
        (
          source: 'sale',
          date: '10-01-2026',
          buyer: 'XYZ',
          buyerKind: 'Customer',
          summary: '',
          total: 45000,
          soldBy: '',
          paid: true,
          imported: true,
          row: {
            'invoice_reference': 'INV-1',
            'old_trno': '',
            'notes': '',
            'sale_items': [
              {
                'machine_id': 9,
                'item_description': 'Ultrasound Machine, Model: NEMIO',
                'item_serial': '070602',
              },
              {
                'item_description': 'Convex Probe, Model: PVM-375AT',
                'item_serial': 'TDA1073239',
              },
            ],
          },
          rows: const <Map<String, dynamic>>[],
        ),
        labels: {'machine:9': 'NEMIO (070602)'},
      );
      expect(cells[2],
          'NEMIO (070602) · Convex Probe, Model: PVM-375AT (TDA1073239)');
    });

    test('a sold send with no amount reads as unrecorded and unpaid', () {
      final cells = salesReportRow((
        source: 'send',
        date: '2026-01-11',
        buyer: 'ABC',
        buyerKind: 'Dealer',
        summary: 'NEMIO 1',
        total: null,
        soldBy: 'Sami',
        paid: false,
        imported: false,
        row: const <String, dynamic>{},
        rows: const <Map<String, dynamic>>[],
      ));
      expect(cells, hasLength(8));
      expect(cells[0], '11-01-2026'); // ISO date reads the shop way
      expect(cells[2], 'NEMIO 1');
      expect(cells[3], '');
      expect(cells[4], 'Sami');
      expect(cells[5], 'Unpaid');
    });

    test('saleReportNotes drops the import party tags', () {
      expect(
          saleReportNotes({
            'notes': 'party:dealer:ABC\nUnknown legacy customer\nDelivered',
          }),
          'Delivered');
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
    test('repairReportRow fills items, customer, costs and notes', () {
      final cells = repairReportRow({
        'job_number': 'REP-00007',
        'received_at': '10-01-2026',
        'customers': {'name': 'XYZ'},
        'customer_contact': '555',
        'problem_description': 'No image',
        'status': 'Returned',
        'returned_at': '20-01-2026',
        'collected_by': 'Sami',
        'profiles': {'display_name': 'Ahmed', 'username': 'ahmed'},
        'estimated_cost': 50,
        'final_cost': null,
        'repair_notes': 'Fixed',
        'return_notes': '',
        'repair_items': [
          {'name_model': 'Mindray DP', 'serial_number': 'SN-1'},
          {'name_model': 'Probe X', 'serial_number': null},
        ],
      });
      expect(cells, hasLength(9));
      expect(cells[0], 'REP-00007');
      expect(cells[2], 'XYZ');
      expect(cells[3], 'Mindray DP (SN-1); Probe X');
      expect(cells[6], '20-01-2026');
      expect(cells[7], '');
      expect(cells[8], 'Fixed');
    });
  });
}
