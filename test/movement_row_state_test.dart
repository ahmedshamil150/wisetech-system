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

    test('an item that moved on counts as still out, not returned', () {
      final send = [_row(13, 'machine', 27), _row(12, 'printer', 45825)];
      final parts = partitionSendRows(send, latest);
      expect(parts.out.map((r) => r['id']), [13, 12]);
      expect(parts.back, isEmpty);
    });
  });
}
