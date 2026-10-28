import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';

/// One movement row naming [kind] (machine/probe/printer/part) [id].
Map<String, dynamic> _row(int id, String kind, int itemId,
        {String type = 'Customer', String group = 'g1'}) =>
    {
      'id': id,
      'movement_type': type,
      '${kind}_id': itemId,
      'group_ref': group,
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
      expect(latest.keys,
          unorderedEquals(['machine:29', 'probe:54', 'printer:45825', 'machine:27']));
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

  group('sendRowState', () {
    final latest = latestMovementByItem(_history);

    test('back when the item\'s newest movement is a Return', () {
      expect(sendRowState(_row(10, 'machine', 29), latest), SendRowState.back);
    });

    test('out when this send is still the newest movement', () {
      expect(sendRowState(_row(11, 'probe', 54), latest), SendRowState.out);
    });

    test('movedOn when a later movement took the item away', () {
      expect(sendRowState(_row(13, 'machine', 27), latest),
          SendRowState.movedOn);
    });

    test('out when the item has no movement in the history at all', () {
      expect(sendRowState(_row(99, 'part', 7, type: 'Workshop'), latest),
          SendRowState.out);
    });

    test('movedOn for a row that names no item', () {
      expect(sendRowState({'id': 99, 'movement_type': 'Customer'}, latest),
          SendRowState.movedOn);
    });
  });

  group('partitionSendRows', () {
    final latest = latestMovementByItem(_history);

    test('a single returned item leaves the send, the rest stay out', () {
      final send = [_row(10, 'machine', 29), _row(11, 'probe', 54)];
      final parts = partitionSendRows(send, latest);
      expect(parts.out.map((r) => r['id']), [11]);
      expect(parts.back.map((r) => r['id']), [10]);
    });

    test('nothing returned keeps every row on the send', () {
      final send = [_row(12, 'printer', 45825)];
      final parts = partitionSendRows(send, latest);
      expect(parts.out.map((r) => r['id']), [12]);
      expect(parts.back, isEmpty);
    });

    test('an item a later send took lands in its own bucket', () {
      final send = [_row(13, 'machine', 27), _row(12, 'printer', 45825)];
      final parts = partitionSendRows(send, latest);
      expect(parts.out.map((r) => r['id']), [12]);
      expect(parts.movedOn.map((r) => r['id']), [13]);
      expect(parts.back, isEmpty);
    });

    test('90T send with the 33T probe: two back, one moved on', () {
      // machine 101 + probe 194 came back on 14-10; probe 65 (33T) came
      // back too and left again on a newer send the same day
      final scenario = latestMovementByItem([
        _row(403, 'machine', 101),
        _row(404, 'probe', 194),
        _row(405, 'probe', 65),
        _row(1441, 'machine', 101, type: 'Return'),
        _row(1442, 'probe', 194, type: 'Return'),
        _row(1443, 'probe', 65, type: 'Return'),
        _row(1444, 'probe', 65, group: 'other-send'),
      ]);
      final parts = partitionSendRows(
          [_row(403, 'machine', 101), _row(404, 'probe', 194), _row(405, 'probe', 65)],
          scenario);
      expect(parts.back.map((r) => r['id']), [403, 404]);
      expect(parts.movedOn.map((r) => r['id']), [405]);
      expect(parts.out, isEmpty);
      expect(returnedBannerText(parts.back.length, 3),
          '2 of 3 items came back from this movement');
    });
  });

  group('returnedBannerText', () {
    test('the whole send back reads as plain "Back in inventory"', () {
      expect(returnedBannerText(3, 3), 'Back in inventory');
      expect(returnedBannerText(4, 3), 'Back in inventory');
    });

    test('one returned item is called out on its own', () {
      expect(returnedBannerText(1, 3),
          'Only this item came back from this movement');
    });

    test('a partial return says how many of the movement came back', () {
      // 90T + its probe back, the 33T probe still with the customer:
      // regression — this once printed the raw row list instead of the
      // count ('$rows.length' interpolated the list, not its length)
      expect(returnedBannerText(2, 3),
          '2 of 3 items came back from this movement');
    });
  });

  group('movementCardKey', () {
    Map<String, dynamic> row(int id, String day, String party,
            {String type = 'Dealer'}) =>
        {
          'id': id,
          'movement_type': type,
          'movement_date': day,
          'to_location': party,
        };

    test('one party on one day is one card, however many sends', () {
      expect(movementCardKey(row(1, '25-09-2026', 'jimmy sb')),
          movementCardKey(row(2, '25-09-2026', 'Jimmy Sb')));
    });

    test('the same day and date parser, both date formats agree', () {
      expect(movementCardKey(row(1, '25-09-2026', 'Jimmy Sb')),
          movementCardKey(row(2, '2026-09-25', 'jimmy sb')));
    });

    test('a different day, party or kind is a different card', () {
      final base = movementCardKey(row(1, '25-09-2026', 'Jimmy Sb'));
      expect(movementCardKey(row(2, '26-09-2026', 'Jimmy Sb')), isNot(base));
      expect(movementCardKey(row(3, '25-09-2026', 'Abid Sb')), isNot(base));
      expect(
          movementCardKey(row(4, '25-09-2026', 'Jimmy Sb', type: 'Customer')),
          isNot(base));
    });

    test('a row without a party never merges with another', () {
      expect(movementCardKey(row(7, '25-09-2026', '')),
          isNot(movementCardKey(row(8, '25-09-2026', ''))));
    });

    test('an unnamed send keeps its own rows together', () {
      expect(
          movementCardKey(row(7, '25-09-2026', '')..['group_ref'] = 'g1'),
          movementCardKey(row(8, '25-09-2026', '')..['group_ref'] = 'g1'));
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
