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
        oldMachinesProvider,
        oldPrintersProvider,
        oldProbesProvider,
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
        final kitUpdates = <String, dynamic>{
          'current_location': location,
        };
        if (target == 'workshop') {
          kitUpdates['status'] = 'With Workshop';
        } else if (target == 'inventory' && table != 'parts') {
          kitUpdates['status'] = 'With Machine';
        }
        await db
            .from(table)
            .update(kitUpdates)
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

/// Refreshes every list a return can change: the inventory, old stock,
/// workshop, missing, basement and branch pages, the movement history and
/// the labels built from them.
void refreshAfterReturn(WidgetRef ref) {
  ref
    ..invalidate(inventoryProvider)
    ..invalidate(oldStockItemsProvider)
    ..invalidate(allItemsProvider)
    ..invalidate(allMovementsProvider)
    ..invalidate(flagsProvider)
    ..invalidate(missingItemKeysProvider)
    ..invalidate(missingItemsProvider)
    ..invalidate(missingAllProvider)
    ..invalidate(basementItemsProvider)
    ..invalidate(workshopItemsProvider)
    ..invalidate(branchItemsProvider)
    ..invalidate(itemLabelsProvider)
    ..invalidate(oldMachinesProvider)
    ..invalidate(oldProbesProvider)
    ..invalidate(oldPrintersProvider);
}

/// Asks where a returned item should land: Main Inventory or Workshop.
/// Returns 'inventory' / 'workshop', or null when dismissed.
Future<String?> showReturnDestinationSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text(
              'Where should it go?',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text('The item will be listed on the page you choose.'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Main Inventory'),
            subtitle: const Text('Back on the Inventory page'),
            onTap: () => Navigator.pop(sheetContext, 'inventory'),
          ),
          ListTile(
            leading: const Icon(Icons.handyman_outlined),
            title: const Text('Workshop'),
            subtitle: const Text('List it on the Workshop page'),
            onTap: () => Navigator.pop(sheetContext, 'workshop'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Returns a Branch or Sold item to the chosen stock list through the
/// `return_item_to_stock` RPC: the server moves the item and, for a
/// machine, its kit; clears Missing flags and writes a Return row for
/// everything that moved. One call keeps a kit from splitting if the
/// connection drops halfway.
Future<bool> returnItemToStockAt(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item,
  String destination,
) async {
  try {
    await returnItemToStock(item, destination);
    refreshAfterReturn(ref);
    if (context.mounted) {
      showSnack(context, 'Returned to ${_labelFor(destination)}.');
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      showSnack(context, errorMessage(error), error: true);
    }
    return false;
  }
}

/// The small menu shown from a Branch or Sold row: return the item to
/// Main Inventory, the Workshop or the Basement. Unlike [moveItemTo],
/// this writes a Return movement and carries a machine's kit.
Future<void> showReturnToStockSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item,
) async {
  final target = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              'Return ${item.code.isEmpty ? item.title : item.code}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text('${item.kindLabel} · ${item.status}'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Return to Main Inventory'),
            subtitle: const Text('Back on the Inventory list'),
            onTap: () => Navigator.pop(sheetContext, 'inventory'),
          ),
          ListTile(
            leading: const Icon(Icons.handyman_outlined),
            title: const Text('Return to Workshop'),
            subtitle: const Text('List it on the Workshop page'),
            onTap: () => Navigator.pop(sheetContext, 'workshop'),
          ),
          ListTile(
            leading: const Icon(Icons.stairs_outlined),
            title: const Text('Return to Basement'),
            subtitle: const Text('Keep it off Inventory, on the Basement page'),
            onTap: () => Navigator.pop(sheetContext, 'basement'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (target == null || !context.mounted) return;
  await returnItemToStockAt(context, ref, item, target);
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
