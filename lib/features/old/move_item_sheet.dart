import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'basement_data.dart';
import 'old_data.dart'
    show
        branchItemsProvider,
        missingAllProvider,
        missingItemsProvider,
        workshopItemsProvider;
import 'old_item_form.dart' show itemFromRow;

String _tableFor(String kind) => switch (kind) {
  'machine' => 'machines',
  'probe' => 'probes',
  'printer' => 'printers',
  _ => 'parts',
};

String _kindForTable(String table) => switch (table) {
  'probes' => 'probe',
  'printers' => 'printer',
  _ => 'part',
};

String _labelFor(String target) => switch (target) {
  'basement' => 'Basement',
  'workshop' => 'Workshop',
  _ => 'Inventory',
};

String _locationFor(String target) => switch (target) {
  'basement' => 'Basement',
  'workshop' => 'Workshop',
  _ => 'Company',
};

String _stockStatusFor(InventoryItem item) =>
    item.assignedMachineId != null ? 'With Machine' : defaultStatus(item.kind);

/// Moves one item between the Basement, the Inventory and the Workshop.
///
/// A machine takes its probes, printer and parts with it, so a kit never
/// splits across two pages. The item's Missing mark is cleared on every
/// move (a found item is no longer missing), and room flags are cleared
/// when it leaves the Workshop.
Future<bool> moveItemTo(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item,
  String target,
) async {
  final location = _locationFor(target);
  final updates = <String, dynamic>{
    'current_location': location,
    if (item.kind == 'machine')
      'status': target == 'workshop' ? 'With Workshop' : 'In Stock'
    else
      'status': _stockStatusFor(item),
  };

  try {
    await db.from(_tableFor(item.kind)).update(updates).eq('id', item.id);

    // a machine carries its kit along
    final kitIds = <String, List<int>>{};
    if (item.kind == 'machine') {
      for (final table in const ['probes', 'printers', 'parts']) {
        final rows = await db
            .from(table)
            .select('id')
            .eq('assigned_machine_id', item.id);
        final ids = [
          for (final row in rows)
            if (row['id'] is int) row['id'] as int,
        ];
        if (ids.isNotEmpty) kitIds[_kindForTable(table)] = ids;
        await db
            .from(table)
            .update({'current_location': location})
            .eq('assigned_machine_id', item.id);
      }
    }

    // a found item is not missing any more
    await db
        .from('flags')
        .delete()
        .eq('item_kind', item.kind)
        .eq('item_id', item.id)
        .eq('note', 'Missing');
    for (final entry in kitIds.entries) {
      await db
          .from('flags')
          .delete()
          .eq('item_kind', entry.key)
          .inFilter('item_id', entry.value)
          .eq('note', 'Missing');
    }

    // leaving the workshop drops the old room label
    if (item.kind == 'machine' && target != 'workshop') {
      await db
          .from('flags')
          .delete()
          .eq('item_kind', 'machine')
          .eq('item_id', item.id)
          .inFilter('note', [...kWorkshopRooms, ...kRetiredWorkshopRooms]);
    }

    ref.invalidate(inventoryProvider);
    ref.invalidate(oldStockItemsProvider);
    ref.invalidate(allItemsProvider);
    ref.invalidate(flagsProvider);
    ref.invalidate(missingItemsProvider);
    ref.invalidate(missingAllProvider);
    ref.invalidate(basementItemsProvider);
    ref.invalidate(workshopItemsProvider);
    ref.invalidate(branchItemsProvider);
    ref.invalidate(itemLabelsProvider);
    if (context.mounted) {
      showSnack(context, 'Moved to ${_labelFor(target)}.');
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      showSnack(context, errorMessage(error), error: true);
    }
    return false;
  }
}

/// The small menu shown from a Basement row: one tap to send the item back
/// to the Inventory or the Workshop.
Future<void> showBasementMoveMenu(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> row,
) async {
  final item = itemFromRow(row);
  final target = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              'Move ${item.code.isEmpty ? item.title : item.code}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text('${item.kindLabel} · ${item.status}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Move to Inventory'),
            subtitle: const Text('Back into the current stock list'),
            onTap: () => Navigator.pop(sheetContext, 'inventory'),
          ),
          ListTile(
            leading: const Icon(Icons.handyman_outlined),
            title: const Text('Move to Workshop'),
            subtitle: const Text('Send it to the workshop'),
            onTap: () => Navigator.pop(sheetContext, 'workshop'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (target == null || !context.mounted) return;
  await moveItemTo(context, ref, item, target);
}

/// Details-sheet entry point. Shows where the item is and the three
/// places it can go.
Future<void> showMoveItemSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item, {
  bool closeAfterMove = true,
}) {
  return showAppSheet<void>(
    context: context,
    title: 'Move ${item.code.isEmpty ? item.title : item.code}',
    heightFraction: 0.55,
    builder: (sheetContext) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          '${item.kindLabel} · ${item.status} · ${item.location}',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (!isBasementLocation(item.location))
          _targetTile(
            sheetContext,
            context,
            ref,
            item,
            target: 'basement',
            icon: Icons.stairs_outlined,
            subtitle: 'Keep it off the Inventory list, on the Basement page',
            closeAfterMove: closeAfterMove,
          ),
        if (item.location.trim().toUpperCase() != 'COMPANY')
          _targetTile(
            sheetContext,
            context,
            ref,
            item,
            target: 'inventory',
            icon: Icons.inventory_2_outlined,
            subtitle: 'Put it back in the current stock list',
            closeAfterMove: closeAfterMove,
          ),
        if (item.status != 'With Workshop')
          _targetTile(
            sheetContext,
            context,
            ref,
            item,
            target: 'workshop',
            icon: Icons.handyman_outlined,
            subtitle: 'Mark it With Workshop and list it on the Workshop page',
            closeAfterMove: closeAfterMove,
          ),
      ],
    ),
  );
}

Widget _targetTile(
  BuildContext sheetContext,
  BuildContext pageContext,
  WidgetRef ref,
  InventoryItem item, {
  required String target,
  required IconData icon,
  required String subtitle,
  required bool closeAfterMove,
}) {
  return ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text('Move to ${_labelFor(target)}'),
    subtitle: Text(subtitle),
    onTap: () async {
      Navigator.pop(sheetContext);
      final moved = await moveItemTo(pageContext, ref, item, target);
      if (moved && closeAfterMove && pageContext.mounted) {
        Navigator.of(pageContext).maybePop();
      }
    },
  );
}
