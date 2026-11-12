import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data.dart';
import '../movements/movements_screen.dart';
import '../old/old_data.dart';
import '../old/old_item_form.dart';

String _workshopRoom(
  Map<String, dynamic> row,
  List<Map<String, dynamic>> flags,
) {
  for (final flag in flags) {
    if (flag['item_kind'] == row['kind'] &&
        flag['item_id'] == row['id'] &&
        kWorkshopRooms.contains(flag['note'])) {
      return '${flag['note']}';
    }
  }
  return 'Unassigned';
}

Future<void> _assignWorkshopRoom(
  Map<String, dynamic> row,
  String room,
  List<Map<String, dynamic>> flags,
) async {
  final kind = row['kind'] as String;
  final id = row['id'] as int;
  await setWorkshopRoom(kind: kind, id: id, room: room);
}

class WorkshopScreen extends ConsumerStatefulWidget {
  const WorkshopScreen({super.key});

  @override
  ConsumerState<WorkshopScreen> createState() => _WorkshopScreenState();
}

class _WorkshopScreenState extends ConsumerState<WorkshopScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _changeRoom(
    Map<String, dynamic> row,
    String room,
    List<Map<String, dynamic>> flags,
  ) async {
    try {
      await _assignWorkshopRoom(row, room, flags);
      ref.invalidate(flagsProvider);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }

  Future<void> _moveItem(Map<String, dynamic> row) async {
    final kind = row['kind'] as String;
    await showWorkshopMovement(
      context,
      InventoryItem(
        kind: kind,
        id: row['id'] as int,
        code: '${row[codeColumnFor(kind)] ?? ''}',
        name: '${row[nameColumnFor(kind)] ?? ''}',
        serial: '${row['serial_number'] ?? ''}',
        status: '${row['status'] ?? ''}',
        location: '${row['current_location'] ?? ''}',
      ),
    );
    if (mounted) ref.invalidate(workshopItemsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final items = ref
        .watch(workshopItemsProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final flags = ref
        .watch(flagsProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final term = _search.text.trim().toLowerCase();
    final filtered = term.isEmpty
        ? items
        : items.where((row) {
            final kind = row['kind'] as String;
            return [
              row[codeColumnFor(kind)],
              row[nameColumnFor(kind)],
              row['serial_number'],
            ].any((value) => '${value ?? ''}'.toLowerCase().contains(term));
          }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search workshop items',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _search.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.clear),
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              for (final room in kWorkshopRooms)
                _WorkshopRoom(
                  room: room,
                  rows: [
                    for (final row in filtered)
                      if (_workshopRoom(row, flags) == room) row,
                  ],
                  flags: flags,
                  onRoomChanged: _changeRoom,
                  onMove: _moveItem,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkshopRoom extends StatelessWidget {
  const _WorkshopRoom({
    required this.room,
    required this.rows,
    required this.flags,
    required this.onRoomChanged,
    required this.onMove,
  });

  final String room;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> flags;
  final Future<void> Function(
    Map<String, dynamic> row,
    String room,
    List<Map<String, dynamic>> flags,
  )
  onRoomChanged;
  final Future<void> Function(Map<String, dynamic> row) onMove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        initiallyExpanded: rows.isNotEmpty,
        title: Text(room, style: const TextStyle(fontWeight: FontWeight.w800)),
        trailing: Chip(label: Text('${rows.length}')),
        children: [
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('No workshop items in this room.'),
              ),
            ),
          for (final row in rows)
            _WorkshopItem(
              row: row,
              room: room,
              flags: flags,
              onRoomChanged: onRoomChanged,
              onMove: onMove,
            ),
        ],
      ),
    );
  }
}

class _WorkshopItem extends StatelessWidget {
  const _WorkshopItem({
    required this.row,
    required this.room,
    required this.flags,
    required this.onRoomChanged,
    required this.onMove,
  });

  final Map<String, dynamic> row;
  final String room;
  final List<Map<String, dynamic>> flags;
  final Future<void> Function(
    Map<String, dynamic> row,
    String room,
    List<Map<String, dynamic>> flags,
  )
  onRoomChanged;
  final Future<void> Function(Map<String, dynamic> row) onMove;

  @override
  Widget build(BuildContext context) {
    final kind = row['kind'] as String;
    final code = '${row[codeColumnFor(kind)] ?? ''}';
    final name = '${row[nameColumnFor(kind)] ?? ''}';
    final serial = '${row['serial_number'] ?? ''}';
    return ListTile(
      title: Text(code.isEmpty ? name : code),
      subtitle: Text(
        [
          name,
          serial,
          '${row['current_location'] ?? ''}',
        ].where((value) => value.isNotEmpty && value != code).join(' · '),
        overflow: TextOverflow.ellipsis,
      ),
      leading: CircleAvatar(child: Text(kindLabel(kind)[0])),
      onTap: () => showOldItemForm(context, kind: kind, row: row),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: room,
            underline: const SizedBox.shrink(),
            onChanged: (value) {
              if (value != null && value != room) {
                onRoomChanged(row, value, flags);
              }
            },
            items: [
              for (final option in kWorkshopRooms)
                DropdownMenuItem(value: option, child: Text(option)),
            ],
          ),
          IconButton(
            tooltip: 'Move from workshop',
            icon: const Icon(Icons.local_shipping_outlined),
            onPressed: () => onMove(row),
          ),
        ],
      ),
    );
  }
}
