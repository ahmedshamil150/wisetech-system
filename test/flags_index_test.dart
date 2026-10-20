import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/data/data.dart';

Map<String, dynamic> _flag(
  int id, {
  String? kind,
  int? itemId,
  int? movementId,
  String? groupRef,
  int? repairId,
  String color = '#E53935',
  String? note,
}) {
  return {
    'id': id,
    'item_kind': kind,
    'item_id': itemId,
    'movement_id': movementId,
    'group_ref': groupRef,
    'repair_id': repairId,
    'color': color,
    'note': note,
  };
}

void main() {
  group('flagIndex', () {
    test('keeps every flag of one target, newest first', () {
      final index = flagIndex([
        _flag(3, kind: 'probe', itemId: 7, note: 'newer'),
        _flag(2, kind: 'probe', itemId: 7, note: 'older'),
        _flag(1, kind: 'probe', itemId: 8, note: 'other item'),
      ]);
      final onSeven = index[flagItemKey('probe', 7)]!;
      expect(onSeven, hasLength(2));
      expect(onSeven.first['note'], 'newer');
      expect(onSeven.last['note'], 'older');
      expect(index[flagItemKey('probe', 8)], hasLength(1));
    });

    test('separates a row flag from its send flag', () {
      final index = flagIndex([
        _flag(2, movementId: 11, groupRef: 'g1', note: 'the send'),
        _flag(1, movementId: 11, note: 'the row'),
      ]);
      expect(index[flagRowKey(11)], hasLength(1));
      expect(index[flagRowKey(11)]!.single['note'], 'the row');
      expect(index[flagSendKey({'id': 11, 'group_ref': 'g1'})],
          hasLength(1));
      expect(index[flagSendKey({'id': 11, 'group_ref': 'g1'})]!.single['note'],
          'the send');
    });

    test('ignores rows that carry no target', () {
      final index = flagIndex([
        _flag(1, color: '#FDD835'),
        _flag(2, kind: 'printer', itemId: 4),
      ]);
      expect(index, hasLength(1));
      expect(index[flagItemKey('printer', 4)], hasLength(1));
    });
  });

  group('flagLabel', () {
    test('joins the notes of several flags', () {
      expect(
          flagLabel([
            _flag(1, note: 'first'),
            _flag(2, note: 'second'),
          ]),
          'first, second');
    });

    test('falls back to Flagged when no note is written', () {
      expect(flagLabel([_flag(1), _flag(2, note: '   ')]), 'Flagged');
    });
  });

  group('flagNoteText', () {
    test('reads the note, or Flagged when empty', () {
      expect(flagNoteText(_flag(1, note: 'Check serial')), 'Check serial');
      expect(flagNoteText(_flag(2, note: '  ')), 'Flagged');
      expect(flagNoteText(_flag(3)), 'Flagged');
    });
  });
}
