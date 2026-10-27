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
          '2 of 3 items came back from this send');
    });
  });

  group('returnedBannerText', () {
    test('the whole send back reads as plain "Back in inventory"', () {
      expect(returnedBannerText(3, 3), 'Back in inventory');
      expect(returnedBannerText(4, 3), 'Back in inventory');
    });

    test('one returned item is called out on its own', () {
      expect(returnedBannerText(1, 3),
          'Only this item came back from this send');
    });

    test('a partial return says how many of the send came back', () {
      // 90T + its probe back, the 33T probe still with the customer:
      // regression — this once printed the raw row list instead of the
      // count ('$rows.length' interpolated the list, not its length)
      expect(returnedBannerText(2, 3),
          '2 of 3 items came back from this send');
    });
  });
}
