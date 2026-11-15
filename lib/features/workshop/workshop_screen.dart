import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../movements/movements_screen.dart';
import '../old/old_data.dart';
import '../old/old_item_form.dart';
import '../old/old_item_tile.dart';

/// The quick chips over the list: a display label and the `kind` it keeps.
/// `null` means every kind — the shop's own starting view.
const _kindFilters = <String, String?>{
  'All': null,
  'Machines': 'machine',
  'Probes': 'probe',
  'Printers': 'printer',
  'Parts': 'part',
};

/// The rooms a row sits in — every room flag it carries, so a machine
/// the audit listed twice (Room 3 and Apron) shows in both sections.
/// A kit member with no flag of its own shares its machine's rooms.
Set<String> _workshopRooms(
  Map<String, dynamic> row,
  List<Map<String, dynamic>> flags,
  Map<int, Set<String>> machineRooms,
) {
  final rooms = <String>{};
  for (final flag in flags) {
    if (flag['item_kind'] == row['kind'] &&
        flag['item_id'] == row['id'] &&
        kWorkshopRooms.contains(flag['note'])) {
      rooms.add('${flag['note']}');
    }
  }
  if (rooms.isNotEmpty) return rooms;
  final machineId = row['assigned_machine_id'];
  if (machineId is int) {
    final linked = machineRooms[machineId];
    if (linked != null && linked.isNotEmpty) return linked;
  }
  return {'Unassigned'};
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

/// Puts every machine first with its kit members right behind it (the
/// printer → probe → part order the inventory uses), then whatever is
/// not linked to a machine on this page. Kit rows carry a `with` label
/// naming the machine they travel with.
List<Map<String, dynamic>> _orderKit(List<Map<String, dynamic>> rows) {
  final machines = [
    for (final row in rows)
      if (row['kind'] == 'machine') row,
  ];
  if (machines.isEmpty) return rows;
  final machineIds = {for (final m in machines) m['id'] as int};
  final kit = <int, List<Map<String, dynamic>>>{};
  final loose = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (row['kind'] == 'machine') continue;
    final machineId = row['assigned_machine_id'];
    if (machineId is int && machineIds.contains(machineId)) {
      (kit[machineId] ??= []).add(row);
    } else {
      loose.add(row);
    }
  }
  int rank(Map<String, dynamic> row) => switch (row['kind']) {
    'printer' => 0,
    'probe' => 1,
    _ => 2,
  };
  return [
    for (final machine in machines) ...[
      machine,
      for (final member in ([...?kit[machine['id'] as int]]
            ..sort((a, b) => rank(a).compareTo(rank(b)))))
        {
          ...member,
          'with': '${machine['machine_id'] ?? ''}',
        },
    ],
    ...loose,
  ];
}

class WorkshopScreen extends ConsumerStatefulWidget {
  const WorkshopScreen({super.key});

  @override
  ConsumerState<WorkshopScreen> createState() => _WorkshopScreenState();
}

class _WorkshopScreenState extends ConsumerState<WorkshopScreen> {
  final _search = TextEditingController();
  String _kind = 'All';
  Set<String> _rooms = const <String>{};
  String _status = 'All';

  /// How many choices in the Filters sheet are doing something, so the
  /// button can wear a badge the way Inventory's does.
  int get _activeFilters =>
      (_rooms.isEmpty ? 0 : 1) + (_status == 'All' ? 0 : 1);

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
    await showWorkshopMovement(context, itemFromRow(row));
    if (mounted) ref.invalidate(workshopItemsProvider);
  }

  /// Opens the Filters sheet: which rooms to show and which statuses.
  /// The sheet only narrows the list already in memory.
  Future<void> _openFilters(
    List<({Map<String, dynamic> row, Set<String> rooms})> rows,
  ) async {
    final roomCounts = <String, int>{};
    for (final entry in rows) {
      for (final room in entry.rooms) {
        roomCounts[room] = (roomCounts[room] ?? 0) + 1;
      }
    }
    final statusCounts = <String, int>{};
    for (final entry in rows) {
      final status = '${entry.row['status'] ?? ''}'.trim();
      if (status.isEmpty) continue;
      statusCounts[status] = (statusCounts[status] ?? 0) + 1;
    }
    final result = await showAppSheet<_WorkshopFilterValues>(
      context: context,
      title: 'Filters',
      heightFraction: 0.8,
      builder: (sheetContext) => _WorkshopFilterSheet(
        rooms: _rooms,
        roomCounts: roomCounts,
        status: _status,
        statusCounts: statusCounts,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _rooms = result.rooms;
      _status = result.status;
    });
  }

  Widget _filterChip(BuildContext context, String label, int count) {
    final selected = _kind == label;
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => setState(() => _kind = label),
      visualDensity: isPhoneLayout(context) ? VisualDensity.compact : null,
      selectedColor: Theme.of(context).colorScheme.primary,
      labelStyle: TextStyle(
        color: selected
            ? Colors.white
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontSize: isPhoneLayout(context) ? 12 : 13,
      ),
      backgroundColor: context.colors.isDark
          ? context.colors.quietFill
          : Theme.of(context).colorScheme.surface,
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(workshopItemsProvider);
    final items = async.maybeWhen(
      data: (rows) => rows,
      orElse: () => const <Map<String, dynamic>>[],
    );
    final flags = ref
        .watch(flagsProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    // A kit member without its own room flag follows its machine; a
    // machine in two rooms (the audit listed M-08114 twice) sits in both.
    final machineRooms = <int, Set<String>>{};
    for (final flag in flags) {
      if (flag['item_kind'] == 'machine' && flag['item_id'] is int) {
        final note = '${flag['note'] ?? ''}'.trim();
        if (kWorkshopRooms.contains(note)) {
          (machineRooms[flag['item_id'] as int] ??= {}).add(note);
        }
      }
    }

    final term = _search.text.trim().toLowerCase();
    // Search and status first: every kind chip and room header then
    // counts what the user would see after tapping it.
    final searched = <({Map<String, dynamic> row, Set<String> rooms})>[];
    for (final row in items) {
      if (_status != 'All' && '${row['status'] ?? ''}'.trim() != _status) {
        continue;
      }
      if (term.isNotEmpty) {
        final kind = row['kind'] as String;
        final hit = [
          row[codeColumnFor(kind)],
          row[nameColumnFor(kind)],
          row['serial_number'],
        ].any((value) => '${value ?? ''}'.toLowerCase().contains(term));
        if (!hit) continue;
      }
      searched.add((row: row, rooms: _workshopRooms(row, flags, machineRooms)));
    }
    final kindCounts = <String, int>{};
    for (final entry in searched) {
      final kind = '${entry.row['kind']}';
      kindCounts[kind] = (kindCounts[kind] ?? 0) + 1;
    }
    final kind = _kindFilters[_kind];
    final visible = [
      for (final entry in searched)
        if (kind == null || entry.row['kind'] == kind) entry,
    ];
    final roomsToShow = [
      for (final room in kWorkshopRooms)
        if (_rooms.isEmpty || _rooms.contains(room)) room,
    ];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
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
              const SizedBox(width: 6),
              if (isPhoneLayout(context))
                IconButton(
                  tooltip: 'Filters',
                  onPressed: () => _openFilters(searched),
                  icon: Badge(
                    isLabelVisible: _activeFilters > 0,
                    label: Text('$_activeFilters'),
                    child: const Icon(Icons.filter_list, size: 22),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _openFilters(searched),
                  icon: Badge(
                    isLabelVisible: _activeFilters > 0,
                    label: Text('$_activeFilters'),
                    child: const Icon(Icons.filter_list, size: 20),
                  ),
                  label: const Text('Filters'),
                ),
            ],
          ),
        ),
        SizedBox(
          height: isPhoneLayout(context) ? 36 : 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _kindFilters.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final label = _kindFilters.keys.elementAt(index);
              final key = _kindFilters[label];
              return _filterChip(
                context,
                label,
                key == null ? searched.length : (kindCounts[key] ?? 0),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${visible.length} item${visible.length == 1 ? '' : 's'} · '
              '${roomsToShow.length} room${roomsToShow.length == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: isPhoneLayout(context) ? 11.5 : 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: async.isLoading && items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : async.hasError && items.isEmpty
              ? EmptyState(
                  icon: Icons.error_outline,
                  message: errorMessage(async.error!),
                )
              : visible.isEmpty
              ? const EmptyState(
                  icon: Icons.build_outlined,
                  message: 'No workshop items match these filters.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    for (final room in roomsToShow)
                      ..._roomSection(
                        context,
                        room,
                        _orderKit([
                          for (final entry in visible)
                            if (entry.rooms.contains(room)) entry.row,
                        ]),
                        flags,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// One room's heading and its cards — the heading reads like the Branch
  /// page's section titles, and a room with nothing left after the filters
  /// leaves nothing behind.
  List<Widget> _roomSection(
    BuildContext context,
    String room,
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> flags,
  ) {
    if (rows.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                room,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
            Text(
              '${rows.length}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
      for (final row in rows)
        OldItemTile(
          row: row,
          indented: '${row['with'] ?? ''}'.isNotEmpty,
          withCode: '${row['with'] ?? ''}'.isEmpty ? null : '${row['with']}',
          trailing: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'Item actions',
            onSelected: (value) {
              if (value == 'move') {
                _moveItem(row);
              } else if (value != room) {
                _changeRoom(row, value, flags);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'move',
                child: Text('Move from workshop'),
              ),
              const PopupMenuDivider(),
              for (final option in kWorkshopRooms)
                if (option != room)
                  PopupMenuItem(value: option, child: Text('Move to $option')),
            ],
          ),
        ),
    ];
  }
}

/// What the Filters sheet hands back — an empty room set and 'All' mean
/// "no filter" for that section.
typedef _WorkshopFilterValues = ({Set<String> rooms, String status});

class _WorkshopFilterSheet extends StatefulWidget {
  const _WorkshopFilterSheet({
    required this.rooms,
    required this.roomCounts,
    required this.status,
    required this.statusCounts,
  });

  final Set<String> rooms;
  final Map<String, int> roomCounts;
  final String status;
  final Map<String, int> statusCounts;

  @override
  State<_WorkshopFilterSheet> createState() => _WorkshopFilterSheetState();
}

class _WorkshopFilterSheetState extends State<_WorkshopFilterSheet> {
  late Set<String> _rooms = {...widget.rooms};
  late String _status = widget.status;

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: scheme.primary,
      labelStyle: TextStyle(
        color: selected ? Colors.white : scheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      backgroundColor: context.colors.isDark
          ? context.colors.quietFill
          : scheme.surface,
      side: BorderSide(color: scheme.outlineVariant),
    );
  }

  void _apply() {
    Navigator.pop(context, (rooms: _rooms, status: _status));
  }

  @override
  Widget build(BuildContext context) {
    final statuses = <String>{
      'All',
      ...widget.statusCounts.keys,
    }.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Filters',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _rooms = {};
                  _status = 'All';
                }),
                child: const Text('Reset'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _label('Status'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final status in statuses)
                        _chip(
                          status == 'All'
                              ? 'All (${widget.statusCounts.values.fold(0, (a, b) => a + b)})'
                              : '$status (${widget.statusCounts[status] ?? 0})',
                          _status == status,
                          () => setState(() => _status = status),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _label('Room'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chip('All rooms', _rooms.isEmpty, () {
                        setState(() => _rooms = {});
                      }),
                      for (final room in kWorkshopRooms)
                        _chip(
                          '$room (${widget.roomCounts[room] ?? 0})',
                          _rooms.contains(room),
                          () => setState(() {
                            final next = {..._rooms};
                            if (!next.add(room)) next.remove(room);
                            _rooms = next;
                          }),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _apply, child: const Text('Apply')),
        ],
      ),
    );
  }
}
