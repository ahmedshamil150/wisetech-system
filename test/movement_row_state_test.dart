import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';

/// One movement row naming [kind] (machine/probe/printer/part) [id].
Map<String, dynamic> _row(
  int id,
  String kind,
  int itemId, {
  String type = 'Customer',
  String group = 'g1',
  String? date,
}) => {
  'id': id,
  'movement_type': type,
  '${kind}_id': itemId,
  'group_ref': group,
  'movement_date': ?date,
};

/// 29T was sent (10) and came back (20); probe 54 (11) and printer 35T
/// (12) are still out with that send; 27T was sent (13) and moved on to
/// a later dealer send (14).
final _history = [
  _row(10, 'machine', 29),
  _row(11, 'probe', 54),
  _row(12, 'printer', 45825),
  _row(13, 'machine', 27),
  _row(14, 'machine', 27, type: 'Dealer'),
  _row(20, 'machine', 29, type: 'Return'),
];

void main() {
  group('movementItemKey', () {
    test('reads whichever item column the row names', () {
      final machine = movementItemKey(_row(1, 'machine', 12));
      expect(machine?.key, 'machine');
      expect(machine?.value, 12);
      final probe = movementItemKey(_row(2, 'probe', 54));
      expect(probe?.key, 'probe');
      expect(probe?.value, 54);
      final printer = movementItemKey(_row(3, 'printer', 45825));
      expect(printer?.key, 'printer');
      expect(printer?.value, 45825);
      expect(movementItemKey({'id': 4, 'movement_type': 'Return'}), isNull);
    });
  });

  group('latestMovementByItem', () {
    test('keeps the newest row of every item, keyed kind:id', () {
      final latest = latestMovementByItem(_history);
      expect(
        latest.keys,
        unorderedEquals([
          'machine:29',
          'probe:54',
          'printer:45825',
          'machine:27',
        ]),
      );
      expect(latest['machine:29']!['id'], 20);
      expect(latest['machine:27']!['id'], 14);
      expect(latest['probe:54']!['id'], 11);
    });

    test('skips rows that name no item', () {
      final latest = latestMovementByItem([
        {'id': 1, 'movement_type': 'Return'},
      ]);
      expect(latest, isEmpty);
    });
  });

  group('movementHistoryByItem', () {
    test('orders each item by the day it moved, then by id', () {
      final history = movementHistoryByItem([
        _row(9, 'machine', 29, date: '02-11-2026'),
        _row(5, 'machine', 29, date: '30-09-2026'),
        _row(7, 'machine', 29, date: '31-10-2026'),
        _row(8, 'machine', 29, date: '31-10-2026'),
      ]);
      expect(history['machine:29']!.map((r) => r['id']), [5, 7, 8, 9]);
    });

    test('rows with no date fall back to their row order', () {
      final history = movementHistoryByItem(_history);
      expect(history['machine:29']!.map((r) => r['id']), [10, 20]);
    });
  });

  group('sendRowState', () {
    final history = movementHistoryByItem(_history);

    test('back when the item has a recorded return after this send', () {
      expect(sendRowState(_row(10, 'machine', 29), history), SendRowState.back);
    });

    test('out when this send is still the newest movement', () {
      expect(sendRowState(_row(11, 'probe', 54), history), SendRowState.out);
    });

    test('movedOn when a later send took the item with no return', () {
      expect(
        sendRowState(_row(13, 'machine', 27), history),
        SendRowState.movedOn,
      );
    });

    test('out when the item has no movement in the history at all', () {
      expect(
        sendRowState(_row(99, 'part', 7, type: 'Workshop'), history),
        SendRowState.out,
      );
    });

    test('movedOn for a row that names no item', () {
      expect(
        sendRowState({'id': 99, 'movement_type': 'Customer'}, history),
        SendRowState.movedOn,
      );
    });

    test('a return still closes the send when the item left again later', () {
      // 30-09 send, a return on 31-10, and the same machine sent again on
      // 02-11: the old send reads returned, the newer one stays out
      final sentAgain = movementHistoryByItem([
        _row(10, 'machine', 1, date: '30-09-2026'),
        _row(40, 'machine', 1, type: 'Return', date: '31-10-2026'),
        _row(30, 'machine', 1, date: '02-11-2026'),
      ]);
      expect(
        sendRowState(_row(10, 'machine', 1), sentAgain),
        SendRowState.back,
      );
      expect(sendRowState(_row(30, 'machine', 1), sentAgain), SendRowState.out);
    });
  });

  group('closingReturn', () {
    final history = movementHistoryByItem(_history);

    test('finds the return row that closed the send', () {
      expect(closingReturn(_row(10, 'machine', 29), history)?['id'], 20);
    });

    test('no return for a send still out or moved on', () {
      expect(closingReturn(_row(11, 'probe', 54), history), isNull);
      expect(closingReturn(_row(13, 'machine', 27), history), isNull);
    });

    test('reads the return date for a send that left again afterwards', () {
      final sentAgain = movementHistoryByItem([
        _row(10, 'machine', 1, date: '30-09-2026'),
        _row(40, 'machine', 1, type: 'Return', date: '31-10-2026'),
        _row(30, 'machine', 1, date: '02-11-2026'),
      ]);
      expect(
        closingReturn(_row(10, 'machine', 1), sentAgain)?['movement_date'],
        '31-10-2026',
      );
    });
  });

  group('partitionSendRows', () {
    final history = movementHistoryByItem(_history);

    test('a single returned item leaves the send, the rest stay out', () {
      final send = [_row(10, 'machine', 29), _row(11, 'probe', 54)];
      final parts = partitionSendRows(send, history);
      expect(parts.out.map((r) => r['id']), [11]);
      expect(parts.back.map((r) => r['id']), [10]);
    });

    test('nothing returned keeps every row on the send', () {
      final send = [_row(12, 'printer', 45825)];
      final parts = partitionSendRows(send, history);
      expect(parts.out.map((r) => r['id']), [12]);
      expect(parts.back, isEmpty);
    });

    test('an item a later send took without a return is movedOn', () {
      final send = [_row(13, 'machine', 27), _row(12, 'printer', 45825)];
      final parts = partitionSendRows(send, history);
      expect(parts.out.map((r) => r['id']), [12]);
      expect(parts.movedOn.map((r) => r['id']), [13]);
      expect(parts.back, isEmpty);
    });

    test('90T send with the 33T probe: all three back', () {
      // machine 101, probe 194 and probe 65 all came back on 14-10; the
      // 33T probe then left again the same day — the send it came back
      // from still reads as returned
      final scenario = movementHistoryByItem([
        _row(403, 'machine', 101),
        _row(404, 'probe', 194),
        _row(405, 'probe', 65),
        _row(1441, 'machine', 101, type: 'Return'),
        _row(1442, 'probe', 194, type: 'Return'),
        _row(1443, 'probe', 65, type: 'Return'),
        _row(1444, 'probe', 65, group: 'other-send'),
      ]);
      final parts = partitionSendRows([
        _row(403, 'machine', 101),
        _row(404, 'probe', 194),
        _row(405, 'probe', 65),
      ], scenario);
      expect(parts.back.map((r) => r['id']), [403, 404, 405]);
      expect(parts.out, isEmpty);
      expect(returnedBannerText(parts.back.length, 3), 'Back in inventory');
    });

    test('a re-sent item without a return keeps the old send movedOn', () {
      final scenario = movementHistoryByItem([
        _row(403, 'machine', 101),
        _row(1444, 'machine', 101, group: 'other-send'),
      ]);
      final parts = partitionSendRows([_row(403, 'machine', 101)], scenario);
      expect(parts.movedOn.map((r) => r['id']), [403]);
      expect(parts.out, isEmpty);
    });
  });

  group('returnedBannerText', () {
    test('the whole send back reads as plain "Back in inventory"', () {
      expect(returnedBannerText(3, 3), 'Back in inventory');
      expect(returnedBannerText(4, 3), 'Back in inventory');
    });

    test('one returned item is called out on its own', () {
      expect(
        returnedBannerText(1, 3),
        'Only this item came back from this movement',
      );
    });

    test('a partial return says how many of the movement came back', () {
      // 90T + its probe back, the 33T probe still with the customer:
      // regression — this once printed the raw row list instead of the
      // count ('$rows.length' interpolated the list, not its length)
      expect(
        returnedBannerText(2, 3),
        '2 of 3 items came back from this movement',
      );
    });
  });

  group('movementCardKey', () {
    Map<String, dynamic> row(
      int id,
      String day,
      String party, {
      String type = 'Dealer',
    }) => {
      'id': id,
      'movement_type': type,
      'movement_date': day,
      'to_location': party,
    };

    test('one party on one day is one card, however many sends', () {
      expect(
        movementCardKey(row(1, '25-09-2026', 'jimmy sb')),
        movementCardKey(row(2, '25-09-2026', 'Jimmy Sb')),
      );
    });

    test('the same day and date parser, both date formats agree', () {
      expect(
        movementCardKey(row(1, '25-09-2026', 'Jimmy Sb')),
        movementCardKey(row(2, '2026-09-25', 'jimmy sb')),
      );
    });

    test('a different day, party or kind is a different card', () {
      final base = movementCardKey(row(1, '25-09-2026', 'Jimmy Sb'));
      expect(movementCardKey(row(2, '26-09-2026', 'Jimmy Sb')), isNot(base));
      expect(movementCardKey(row(3, '25-09-2026', 'Abid Sb')), isNot(base));
      expect(
        movementCardKey(row(4, '25-09-2026', 'Jimmy Sb', type: 'Customer')),
        isNot(base),
      );
    });

    test('a row without a party never merges with another', () {
      expect(
        movementCardKey(row(7, '25-09-2026', '')),
        isNot(movementCardKey(row(8, '25-09-2026', ''))),
      );
    });

    test('an unnamed send keeps its own rows together', () {
      expect(
        movementCardKey(row(7, '25-09-2026', '')..['group_ref'] = 'g1'),
        movementCardKey(row(8, '25-09-2026', '')..['group_ref'] = 'g1'),
      );
    });
  });

  group('groupSendRows', () {
    test('splits a merged card back into its sends in row order', () {
      final sends = groupSendRows([
        _row(1, 'machine', 10, group: 'a'),
        _row(2, 'probe', 11, group: 'a'),
        _row(3, 'machine', 12, group: 'b'),
        _row(4, 'machine', 13, group: ''),
        _row(5, 'machine', 14, group: ''),
      ]);
      expect(sends.map((s) => s.key).toList(), ['a', 'b', 'row:4', 'row:5']);
      expect(sends.first.rows.map((r) => r['id']), [1, 2]);
    });
  });
}
