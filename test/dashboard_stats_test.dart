import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/sales/sales_screen.dart';
import 'package:ultrasound_inventory/features/shell/dashboard_stats.dart';

Map<String, dynamic> _move(
  int id, {
  String type = 'Dealer',
  String date = '15-10-2026',
  String group = 'g1',
  int? machineId,
  int? probeId,
}) {
  return {
    'id': id,
    'movement_type': type,
    'movement_date': date,
    'group_ref': group,
    'machine_id': machineId,
    'probe_id': probeId,
  };
}

SaleEntry _entry({
  String source = 'send',
  String date = '15-10-2026',
  double? total = 1000,
  bool imported = false,
  Map<String, dynamic> row = const {},
  List<Map<String, dynamic>> rows = const [],
}) {
  return (
    source: source,
    date: date,
    buyer: 'Dr Sajjad',
    buyerKind: 'Customer',
    summary: '',
    total: total,
    soldBy: '',
    paid: false,
    imported: imported,
    row: row,
    rows: rows,
  );
}

const _batches = {
  'machine:1': 'BATCH-3',
  'probe:2': 'BATCH-OLD',
  'machine:3': 'BATCH-3',
};

void main() {
  group('periods', () {
    final now = DateTime(2026, 10, 28);

    test('the running month stops at today', () {
      final period = dashMonthPeriod(2026, 10, now: now);
      expect(period.from, DateTime(2026, 10, 1));
      expect(period.to, DateTime(2026, 10, 28));
      expect(period.label, 'October 2026');
    });

    test('a past month runs to its last day', () {
      expect(dashMonthPeriod(2026, 9, now: now).to, DateTime(2026, 9, 30));
      expect(dashMonthPeriod(2026, 2, now: now).to, DateTime(2026, 2, 28));
      expect(dashMonthPeriod(2024, 2, now: now).to, DateTime(2024, 2, 29));
    });

    test('last month, this year and all time', () {
      final last = dashLastMonth(now);
      expect(last.from, DateTime(2026, 9, 1));
      expect(last.to, DateTime(2026, 9, 30));
      final year = dashThisYear(now);
      expect(year.from, DateTime(2026, 1, 1));
      expect(year.to, DateTime(2026, 10, 28));
      expect(dashAllTime.from, isNull);
      expect(dashAllTime.to, isNull);
    });

    test('a typed range is inclusive and rejects bad or reversed dates', () {
      final period = dashCustomPeriod('01-10-2026', '28-10-2026')!;
      expect(period.from, DateTime(2026, 10, 1));
      expect(period.to, DateTime(2026, 10, 28));
      expect(dashInPeriod('01-10-2026', period), isTrue);
      expect(dashInPeriod('28-10-2026', period), isTrue);
      expect(dashInPeriod('29-10-2026', period), isFalse);
      expect(dashInPeriod('', period), isFalse);
      expect(dashCustomPeriod('28-10-2026', '01-10-2026'), isNull);
      expect(dashCustomPeriod('', '01-10-2026'), isNull);
      expect(dashCustomPeriod('abc', '01-10-2026'), isNull);
    });

    test('all time keeps undated rows, a window drops them', () {
      expect(dashInPeriod('', dashAllTime), isTrue);
      final month = dashThisMonth();
      expect(dashInPeriod('', month), isFalse);
    });
  });

  group('computeDashStats', () {
    final october = dashMonthPeriod(2026, 10, now: DateTime(2026, 10, 28));

    test('sends count once per group, items once per row', () {
      final stats = computeDashStats(
        movementRows: [
          _move(1, machineId: 1, group: 'g1'),
          _move(2, probeId: 2, group: 'g1'),
          _move(3, machineId: 3, group: 'g2', type: 'Workshop'),
          _move(4, machineId: 1, group: 'g3', date: '30-09-2026'),
        ],
        saleEntries: const [],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.sendCount, 2);
      expect(stats.itemCount, 3);
      expect(stats.sendsByKind, {'Dealer': 1, 'Workshop': 1});
      expect(stats.returnedItems, 0);
    });

    test('returns are counted apart from sends', () {
      final stats = computeDashStats(
        movementRows: [
          _move(1, type: 'Return', machineId: 1, group: 'r1'),
          _move(2, type: 'Return', probeId: 2, group: 'r2'),
        ],
        saleEntries: const [],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.returnedItems, 2);
      expect(stats.returnedBack, 2);
      expect(stats.sendCount, 0);
      expect(stats.itemCount, 0);
    });

    test('a returned item sent out again is not counted as back', () {
      final stats = computeDashStats(
        movementRows: [
          _move(1, type: 'Return', machineId: 1, group: 'r1',
              date: '05-10-2026'),
          _move(2, type: 'Customer', machineId: 1, group: 'g9',
              date: '06-10-2026'),
          _move(3, type: 'Return', probeId: 2, group: 'r2'),
        ],
        saleEntries: const [],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.returnedItems, 2);
      expect(stats.returnedBack, 1);
    });

    test('a batch narrows movements to items in it', () {
      final stats = computeDashStats(
        movementRows: [
          _move(1, machineId: 1, group: 'g1'),
          _move(2, probeId: 2, group: 'g2'),
          _move(3, machineId: 3, group: 'g3'),
        ],
        saleEntries: const [],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
        batch: 'BATCH-3',
      );
      expect(stats.sendCount, 2);
      expect(stats.itemCount, 2);
    });

    test('sales add up inside the period only', () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: [
          _entry(total: 1000),
          _entry(date: '2026-10-02', total: 2500.5),
          _entry(date: '2026-09-30', total: 999),
        ],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.salesCount, 2);
      expect(stats.salesAmount, 3500.5);
      expect(stats.salesPriced, 2);
    });

    test('a sale without a recorded amount counts, but adds nothing', () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: [
          _entry(total: null),
          _entry(date: '2026-10-02', total: 700),
        ],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.salesCount, 2);
      expect(stats.salesPriced, 1);
      expect(stats.salesAmount, 700);
      expect(stats.salesUnpricedImported, 0);
    });

    test('unpriced import rows are told apart from unpriced sends', () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: [
          _entry(total: null, imported: true),
          _entry(total: null, imported: true),
          _entry(total: null),
        ],
        repairRows: const [],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.salesCount, 3);
      expect(stats.salesPriced, 0);
      expect(stats.salesUnpricedImported, 2);
    });

    test('a batch keeps only sales made entirely of its items', () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: [
          // send: both rows in batch 3
          _entry(rows: [
            {'machine_id': 1},
            {'probe_id': 4},
          ]),
          // send: one old-stock probe mixed in
          _entry(rows: [
            {'machine_id': 1},
            {'probe_id': 9},
          ]),
          // sale whose line names a batch-3 machine
          _entry(source: 'sale', row: {
            'sale_items': [
              {'machine_id': 3, 'item_price': 500},
            ],
          }),
          // sale line with no item link — cannot be placed in a batch
          _entry(source: 'sale', row: {
            'sale_items': [
              {'item_description': 'Unknown'},
            ],
          }),
        ],
        repairRows: const [],
        batchByItem: {..._batches, 'probe:4': 'BATCH-3', 'probe:9': 'BATCH-OLD'},
        period: october,
        batch: 'BATCH-3',
      );
      expect(stats.salesCount, 2);
      expect(stats.salesAmount, 2000);
    });

    test('repairs count in and back inside the period, with money', () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: const [],
        repairRows: [
          {'received_at': '03-10-2026', 'status': 'Received'},
          {
            'received_at': '01-10-2026',
            'returned_at': '12-10-2026',
            'money_received': 4000,
            'status': 'Returned',
          },
          {
            'received_at': '01-09-2026',
            'returned_at': '05-09-2026',
            'money_received': 500,
            'status': 'Returned',
          },
        ],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.repairsReceived, 2);
      expect(stats.repairsReturnedOfReceived, 1);
      expect(stats.repairsBack, 1);
      expect(stats.repairsMoney, 4000);
    });

    test('a repair received earlier and given back now counts only as back',
        () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: const [],
        repairRows: [
          {
            'received_at': '20-09-2026',
            'returned_at': '04-10-2026',
            'money_received': 1500,
            'status': 'Returned',
          },
        ],
        batchByItem: _batches,
        period: october,
      );
      expect(stats.repairsReceived, 0);
      expect(stats.repairsReturnedOfReceived, 0);
      expect(stats.repairsBack, 1);
      expect(stats.repairsMoney, 1500);
    });

    test('a batch view leaves repairs out', () {
      final stats = computeDashStats(
        movementRows: const [],
        saleEntries: const [],
        repairRows: [
          {'received_at': '03-10-2026', 'money_received': 4000},
        ],
        batchByItem: _batches,
        period: october,
        batch: 'BATCH-3',
        includeRepairs: false,
      );
      expect(stats.repairsReceived, 0);
      expect(stats.repairsBack, 0);
      expect(stats.repairsMoney, 0);
    });
  });
}
