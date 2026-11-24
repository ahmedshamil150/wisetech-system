import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../old/basement_data.dart';
import '../old/missing_screen.dart' show showFoundItemSheet;
import '../old/move_item_sheet.dart' show showMoveItemSheet;
import '../old/old_data.dart'
    show missingAllProvider, missingItemsProvider, workshopItemsProvider;
import '../old/old_item_form.dart' show itemFromRow;
import 'inventory_item_tile.dart';
import 'inventory_screen.dart' show showItemDetails;

/// The three lists the new button on the Inventory page opens. Each one
/// keeps its own source, but all of them render with the same tiles,
/// filters and details sheet Inventory uses.
enum StockGroup {
  workshop('Workshop', Icons.handyman_outlined),
  missing('Missing', Icons.help_outline),
  basement('Basement', Icons.stairs_outlined);

  const StockGroup(this.label, this.icon);

  final String label;
  final IconData icon;

  FutureProvider<List<Map<String, dynamic>>> get items => switch (this) {
    StockGroup.workshop => workshopItemsProvider,
    StockGroup.missing => missingItemsProvider,
    StockGroup.basement => basementItemsProvider,
  };
}

/// A full list of one group — Workshop, Missing or Basement — laid out
/// exactly like the Inventory page: search, kind chips, a machine card
/// with its kit underneath, and the same details sheet with edit, delete,
/// flags, movements and moves.
class StockGroupScreen extends ConsumerStatefulWidget {
  const StockGroupScreen({super.key, required this.group});

  final StockGroup group;

  @override
  ConsumerState<StockGroupScreen> createState() => _StockGroupScreenState();
}

class _StockGroupScreenState extends ConsumerState<StockGroupScreen> {
  String _query = '';
  String _kind = 'all';

  static const _kindFilters = <(String, String?)>[
    ('All', null),
    ('Machines', 'machine'),
    ('Probes', 'probe'),
    ('Printers', 'printer'),
    ('Parts', 'part'),
  ];

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(widget.group.items);
    final rows = async.maybeWhen(
      data: (rows) => rows,
      orElse: () => const <Map<String, dynamic>>[],
    );
    final items = [for (final row in rows) itemFromRow(row, isMissing: widget.group == StockGroup.missing)];
    final term = _query.toLowerCase();

    bool matches(InventoryItem item) {
      if (_kind != 'all' && item.kind != _kind) return false;
      if (term.isEmpty) return true;
      return [
        item.code,
        item.title,
        item.serial,
        item.location,
      ].any((value) => (value ?? '').toLowerCase().contains(term));
    }

    final filtered = items.where(matches).toList();
    final typeCounts = kindCountsOf(items);
    final visible = _arrangeKits(filtered);

    return Scaffold(
      appBar: AppBar(title: Text('${widget.group.label} items')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SearchField(
              hint: 'Search by code, model or serial',
              onChanged: (value) => setState(() => _query = value.trim()),
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
                final (label, kind) = _kindFilters[index];
                final count = kind == null
                    ? items.length
                    : (typeCounts[kind] ?? 0);
                return _filterChip(
                  context,
                  label,
                  count,
                  selected: _kind == (kind ?? 'all'),
                  onTap: () => setState(() => _kind = kind ?? 'all'),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${filtered.length} item${filtered.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: isPhoneLayout(context) ? 11.5 : 12.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: async.isLoading && rows.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : async.hasError && rows.isEmpty
                ? EmptyState(
                    icon: Icons.error_outline,
                    message: errorMessage(async.error!),
                    onRetry: () => ref.invalidate(widget.group.items),
                  )
                : visible.isEmpty
                ? EmptyState(
                    icon: widget.group.icon,
                    message: _query.isEmpty && _kind == 'all'
                        ? 'No ${widget.group.label.toLowerCase()} items yet.'
                        : 'No items match this search.',
                  )
                : AppRefresh(
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final entry = visible[index];
                        return InventoryItemTile(
                          item: entry.item,
                          indented: entry.indented,
                          onTap: () =>
                              showItemDetails(context, ref, entry.item),
                          trailing: _quickAction(context, ref, entry.item),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// One-tap action for the group: "I found this item" while a row is
  /// missing, otherwise the move sheet (Inventory / Workshop / Basement).
  Widget _quickAction(
    BuildContext context,
    WidgetRef ref,
    InventoryItem item,
  ) {
    if (widget.group == StockGroup.missing) {
      return IconButton(
        tooltip: 'I found this item',
        icon: Icon(
          Icons.task_alt,
          color: Theme.of(context).colorScheme.primary,
        ),
        onPressed: () async {
          final moved = await showFoundItemSheet(context, {
            'kind': item.kind,
            'id': item.id,
            'code': item.code,
            'name': item.title,
            'serial_number': item.serial,
            'current_location': item.location,
          });
          if (moved != true) return;
          ref
            ..invalidate(flagsProvider)
            ..invalidate(inventoryProvider)
            ..invalidate(allItemsProvider)
            ..invalidate(missingItemsProvider)
            ..invalidate(missingAllProvider)
            ..invalidate(workshopItemsProvider)
            ..invalidate(basementItemsProvider);
        },
      );
    }
    return IconButton(
      tooltip: 'Move to Inventory, Workshop or Basement',
      icon: const Icon(Icons.swap_horiz, size: 20),
      onPressed: () => showMoveItemSheet(context, ref, item),
    );
  }

  Widget _filterChip(
    BuildContext context,
    String label,
    int count, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => onTap(),
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
}

Map<String, int> kindCountsOf(List<InventoryItem> items) {
  final counts = <String, int>{};
  for (final item in items) {
    counts[item.kind] = (counts[item.kind] ?? 0) + 1;
  }
  return counts;
}

typedef _Placed = ({InventoryItem item, bool indented});

/// Machine first, its probes/printer/parts tucked underneath, then every
/// item that does not travel with a machine — the Inventory order.
List<_Placed> _arrangeKits(List<InventoryItem> items) {
  final machines = [
    for (final item in items)
      if (item.kind == 'machine') item,
  ];
  final machineIds = {for (final machine in machines) machine.id};
  final kit = <int, List<InventoryItem>>{};
  final loose = <InventoryItem>[];
  for (final item in items) {
    if (item.kind == 'machine') continue;
    final machineId = item.assignedMachineId;
    if (machineId != null && machineIds.contains(machineId)) {
      (kit[machineId] ??= []).add(item);
    } else {
      loose.add(item);
    }
  }
  int rank(InventoryItem item) => switch (item.kind) {
    'printer' => 0,
    'probe' => 1,
    _ => 2,
  };
  return [
    for (final machine in machines) ...[
      (item: machine, indented: false),
      for (final member in ([...?kit[machine.id]]..sort((a, b) {
        final byKind = rank(a).compareTo(rank(b));
        if (byKind != 0) return byKind;
        return (a.serial ?? '').compareTo(b.serial ?? '');
      })))
        (item: member, indented: true),
    ],
    for (final item in loose) (item: item, indented: false),
  ];
}
