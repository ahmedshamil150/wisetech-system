import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';
import 'package:ultrasound_inventory/features/sales/sales_screen.dart';

Map<String, dynamic> _saleRow(
  int id, {
  String date = '2026-01-05',
  String notes = '',
  dynamic price = 100,
  bool imported = false,
  String? trno,
  List<Map<String, dynamic>> lines = const [],
}) {
  return {
    'id': id,
    'sale_date': date,
    'sale_price': price,
    'notes': notes,
    'old_trno': trno,
    'old_source_id': imported ? id : null,
    'customers': null,
    'sale_items': lines,
  };
}

Map<String, dynamic> _moveRow(
  int id, {
  String reason = 'Sold',
  String group = 'g1',
  String date = '05-01-2026',
  String type = 'Customer',
  String to = 'Dr Sajjad',
  int? machineId,
  int? probeId,
  dynamic amount,
  bool paid = false,
  int? oldSourceId,
  Map<String, dynamic>? customer,
  String? soldBy,
}) {
  return {
    'id': id,
    'group_ref': group,
    'movement_type': type,
    'movement_date': date,
    'to_location': to,
    'reason': reason,
    'paid': paid,
    'sale_amount': amount,
    'sold_by': soldBy,
    'old_source_id': oldSourceId,
    'machine_id': ?machineId,
    'probe_id': ?probeId,
    'customers': customer,
  };
}

void main() {
  group('saleEntryDate', () {
    test('sales read yyyy-MM-dd and movements dd-MM-yyyy', () {
      expect(saleEntryDate('2026-01-05'), DateTime(2026, 1, 5));
      expect(saleEntryDate('05-01-2026'), DateTime(2026, 1, 5));
    });

    test('import garbage sorts as null instead of crashing', () {
      expect(saleEntryDate(''), isNull);
      expect(saleEntryDate('0010'), isNull);
      expect(saleEntryDate('06-10'), isNull);
      expect(saleEntryDate('abc-def-ghi'), isNull);
    });
  });

  group('saleAmountText', () {
    test('whole numbers drop the .0 tail', () {
      expect(saleAmountText(null), '');
      expect(saleAmountText(1500), '1500');
      expect(saleAmountText(1500.5), '1500.5');
    });
  });

  group('mergeSaleEntries', () {
    test('rows of one send merge into a single entry', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [
          _moveRow(1, probeId: 10),
          _moveRow(2, probeId: 11),
        ],
        labels: const {},
      );
      expect(entries, hasLength(1));
      expect(entries.single.source, 'send');
      expect(entries.single.rows, hasLength(2));
      expect(entries.single.buyer, 'Dr Sajjad');
    });

    test('a send keeps its own rows when group_ref is empty', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [
          _moveRow(1, group: '', machineId: 5),
          _moveRow(2, group: '', machineId: 6),
        ],
        labels: const {},
      );
      expect(entries, hasLength(2));
    });

    test('unmarked and Return rows never become sales', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [
          _moveRow(1, reason: 'Sent to customer'),
          _moveRow(2, reason: 'Returned to company'),
        ],
        labels: const {},
      );
      expect(entries, isEmpty);
    });

    test('sales and sends merge newest first', () {
      final entries = mergeSaleEntries(
        salesRows: [
          _saleRow(1, date: '2026-03-01'),
          _saleRow(2, date: '2025-12-31', imported: true),
        ],
        movementRows: [
          _moveRow(9, date: '15-03-2026', amount: 45000, paid: true),
        ],
        labels: const {},
      );
      expect(entries.map((e) => e.date).toList(),
          ['15-03-2026', '2026-03-01', '2025-12-31']);
      expect(entries.first.source, 'send');
      expect(entries.first.total, 45000);
      expect(entries.first.paid, isTrue);
      expect(entries.last.imported, isTrue);
    });

    test('item labels fill the send summary', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [
          _moveRow(1, machineId: 7),
          _moveRow(2, probeId: 3),
        ],
        labels: const {
          'machine:7': 'M7  Ultrasound',
          'probe:3': 'P3  Linear',
        },
      );
      expect(entries.single.summary, 'M7  Ultrasound · P3  Linear');
    });

    test('a linked customers row beats the to_location', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [
          _moveRow(1, customer: {'name': 'Dr Ali'}, to: 'somewhere'),
        ],
        labels: const {},
      );
      expect(entries.single.buyer, 'Dr Ali');
    });

    test('a sold send carries the name of the person who sold it', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [_moveRow(1, machineId: 7, soldBy: 'Usman Ali')],
        labels: const {},
      );
      expect(entries.single.soldBy, 'Usman Ali');
    });

    test('a send sold before the field existed reads no seller', () {
      final entries = mergeSaleEntries(
        salesRows: const [],
        movementRows: [_moveRow(1, machineId: 7)],
        labels: const {},
      );
      expect(entries.single.soldBy, '');
    });

    test('unreadable dates sort last instead of crashing', () {
      final entries = mergeSaleEntries(
        salesRows: [_saleRow(1, date: '06-10')],
        movementRows: [_moveRow(5, date: '05-01-2026')],
        labels: const {},
      );
      expect(entries.last.source, 'sale');
      expect(entries.last.date, '06-10');
    });

    test('imported old sends never duplicate the old sales rows', () {
      final entries = mergeSaleEntries(
        salesRows: [_saleRow(1, imported: true), _saleRow(2)],
        movementRows: [_moveRow(9, oldSourceId: 8796, amount: 500)],
        labels: const {},
      );
      expect(entries, hasLength(2));
      expect(entries.every((e) => e.source == 'sale'), isTrue);
    });

    test('a sale without a sale price reads its line prices', () {
      final entries = mergeSaleEntries(
        salesRows: [
          _saleRow(1, price: 0, imported: true, lines: [
            {'item_price': 500},
            {'item_price': 250},
          ]),
        ],
        movementRows: const [],
        labels: const {},
      );
      expect(entries.single.total, 750);
    });

    test('a sale with no price anywhere reads no amount', () {
      final entries = mergeSaleEntries(
        salesRows: [
          _saleRow(1, price: 0, imported: true, lines: [
            {'item_price': 0},
            {'item_price': null},
          ]),
        ],
        movementRows: const [],
        labels: const {},
      );
      expect(entries.single.total, isNull);
    });

    test('the same old invoice imported twice shows once', () {
      final entries = mergeSaleEntries(
        salesRows: [
          _saleRow(1, trno: '19822900', price: 0),
          _saleRow(2, trno: '19822900', price: 0),
          _saleRow(3, trno: '19822901', price: 0),
        ],
        movementRows: const [],
        labels: const {},
      );
      expect(entries, hasLength(2));
    });

    test('sales sharing the placeholder invoice 0 stay apart', () {
      final entries = mergeSaleEntries(
        salesRows: [
          _saleRow(1, trno: '0', date: '2025-12-01'),
          _saleRow(2, trno: '0', date: '2026-01-29'),
          _saleRow(3, trno: '0', date: '2026-05-22'),
        ],
        movementRows: const [],
        labels: const {},
      );
      expect(entries, hasLength(3));
    });
  });

  group('filterSaleEntries', () {
    List<SaleEntry> entries() => mergeSaleEntries(
          salesRows: [
            _saleRow(1, date: '2026-03-01', lines: [
              {'item_description': 'Machine A', 'item_type': 'machine'},
            ]),
            _saleRow(2, date: '2025-12-31', notes: 'party:dealer:Ali Traders', lines: [
              {'item_description': 'Probe B', 'item_type': 'probe'},
            ]),
          ],
          movementRows: [
            _moveRow(9, date: '15-03-2026', probeId: 3, to: 'Dr Sajjad'),
          ],
          labels: const {},
        );

    test('source, buyer and item type narrow the list', () {
      expect(filterSaleEntries(entries(), source: 'Sales'), hasLength(2));
      expect(
          filterSaleEntries(entries(), source: 'From sends').single.source,
          'send');
      expect(filterSaleEntries(entries(), buyerType: 'Dealer').single.date,
          '2025-12-31');
      expect(filterSaleEntries(entries(), itemType: 'machine').single.date,
          '2026-03-01');
      expect(filterSaleEntries(entries(), itemType: 'probe'), hasLength(2));
    });

    test('the date range is inclusive and drops unreadable dates', () {
      final all = entries();
      final narrow = filterSaleEntries(all,
          dateFrom: '01-01-2026', dateTo: '01-03-2026');
      expect(narrow.map((e) => e.date).toList(), ['2026-03-01']);
      expect(filterSaleEntries(all, dateFrom: '16-03-2026'), isEmpty);
    });

    test('search reads buyer, items and totals', () {
      expect(filterSaleEntries(entries(), query: 'ali traders').single.date,
          '2025-12-31');
      expect(filterSaleEntries(entries(), query: 'machine a').single.date,
          '2026-03-01');
    });
  });

  group('sold amount helpers', () {
    test('soldAmountOf reads num rows and misses the rest', () {
      expect(soldAmountOf({'sale_amount': 1200}), 1200);
      expect(soldAmountOf({'sale_amount': null}), isNull);
      expect(soldAmountOf(<String, dynamic>{}), isNull);
    });

    test('parseSaleAmount accepts blanks and commas', () {
      expect(parseSaleAmount(''), isNull);
      expect(parseSaleAmount('   '), isNull);
      expect(parseSaleAmount('45,000'), 45000);
      expect(parseSaleAmount('45000.5'), 45000.5);
      expect(parseSaleAmount('abc'), isNull);
    });
  });

  group('labelsForItems', () {
    test('old-stock items get labels too', () {
      const oldProbe = InventoryItem(
        kind: 'probe',
        id: 40,
        code: 'P40',
        name: 'Linear',
        status: 'Available',
        location: 'Company',
        batch: 'BATCH-OLD',
      );
      final labels = labelsForItems(const [
        InventoryItem(
          kind: 'machine',
          id: 7,
          code: 'M7',
          name: 'Ultrasound',
          status: 'Available',
          location: 'Company',
        ),
        oldProbe,
      ]);
      expect(labels['machine:7'], 'M7  Ultrasound');
      expect(labels['probe:40'], 'P40  Linear');
    });
  });

  group('boxAddCandidates with old stock', () {
    final box = <String, dynamic>{'id': 1, 'name': 'H12', 'probe_type': 'Linear'};

    test('an unboxed old probe is boxable', () {
      const oldProbe = InventoryItem(
        kind: 'probe',
        id: 40,
        code: 'P40',
        name: 'Linear',
        status: 'Available',
        location: 'Company',
        batch: 'BATCH-OLD',
      );
      expect(boxAddCandidates(const [oldProbe], box).single.id, 40);
    });

    test('an old probe already in a box stays out', () {
      const boxedOldProbe = InventoryItem(
        kind: 'probe',
        id: 41,
        code: 'P41',
        name: 'Linear',
        status: 'Available',
        location: 'H12',
        batch: 'BATCH-OLD',
        boxId: 1,
      );
      expect(boxAddCandidates(const [boxedOldProbe], box), isEmpty);
    });
  });
}
