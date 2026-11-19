import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Everything the probe placement flows refresh once a probe moves.
void refreshProbePlacement(WidgetRef ref) {
  ref
    ..invalidate(inventoryProvider)
    ..invalidate(oldStockItemsProvider)
    ..invalidate(allItemsProvider)
    ..invalidate(allMovementsProvider)
    ..invalidate(probeBoxesProvider)
    ..invalidate(flagsProvider);
}

/// The freshest copy of [probe] — after a return the object held by the
/// caller still has the old status and location.
Future<InventoryItem> freshProbe(WidgetRef ref, InventoryItem probe) async {
  try {
    final rows = await ref.read(allItemsProvider.future);
    return rows.firstWhere((item) => item.key == probe.key, orElse: () => probe);
  } catch (_) {
    return probe;
  }
}

/// Asks where a returned probe now sits: in a box, with a machine, or
/// free in stock. The chosen placement is written straight away so the
/// status chip and the list agree with what a person can see.
Future<void> showProbePlacementSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem probe,
) async {
  final fresh = await freshProbe(ref, probe);
  if (!context.mounted) return;
  final choice = await showAppSheet<String>(
    context: context,
    title: 'Where is ${fresh.code.isEmpty ? 'this probe' : fresh.code} now?',
    heightFraction: 0.62,
    builder: (sheetContext) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          'Returned to inventory. Tell us where it is so its status is right.',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        _PlacementTile(
          icon: Icons.inventory_2_outlined,
          title: 'In a box',
          subtitle: 'It is stored in a probe box',
          onTap: () => Navigator.pop(sheetContext, 'box'),
        ),
        _PlacementTile(
          icon: Icons.monitor_outlined,
          title: 'With a machine',
          subtitle: 'It is attached to a machine',
          onTap: () => Navigator.pop(sheetContext, 'machine'),
        ),
        _PlacementTile(
          icon: Icons.shelves,
          title: 'Free in stock',
          subtitle: 'Not in a box and not on a machine',
          onTap: () => Navigator.pop(sheetContext, 'stock'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('Decide later'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'box':
      await showProbeBoxPicker(context, ref, fresh);
    case 'machine':
      await showProbeAttachSheet(context, ref, fresh);
    case 'stock':
      await _placeInStock(context, ref, fresh);
  }
}

class _PlacementTile extends StatelessWidget {
  const _PlacementTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: context.colors.tintBlue,
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: onTap,
        ),
      ),
    );
  }
}

Future<void> _placeInStock(
  BuildContext context,
  WidgetRef ref,
  InventoryItem probe,
) async {
  try {
    await placeProbeInStock(probe);
    refreshProbePlacement(ref);
    if (context.mounted) {
      showSnack(context, '${probe.code} is free in stock.');
    }
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
  }
}

/// Offers the boxes a probe can go into and writes the box move.
Future<void> showProbeBoxPicker(
  BuildContext context,
  WidgetRef ref,
  InventoryItem probe,
) async {
  final List<Map<String, dynamic>> boxes;
  try {
    boxes = await ref.read(probeBoxesProvider.future);
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
    return;
  }
  if (!context.mounted) return;
  if (boxes.isEmpty) {
    showSnack(context, 'No boxes yet — create a box first.', error: true);
    return;
  }
  final box = await showAppSheet<Map<String, dynamic>>(
    context: context,
    title: 'Put ${probe.code.isEmpty ? 'probe' : probe.code} in a box',
    heightFraction: 0.7,
    builder: (sheetContext) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        for (final row in boxes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AppCard(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(
                  (row['name'] ?? 'Box').toString(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  [
                    (row['probe_type'] ?? '').toString(),
                    if ((row['notes'] ?? '').toString().isNotEmpty)
                      (row['notes'] ?? '').toString(),
                  ].where((value) => value.isNotEmpty).join(' · '),
                ),
                onTap: () => Navigator.pop(sheetContext, row),
              ),
            ),
          ),
      ],
    ),
  );
  if (box == null || !context.mounted) return;
  try {
    await putProbeInBox(probe, box);
    refreshProbePlacement(ref);
    if (context.mounted) {
      showSnack(context, '${probe.code} put in ${box['name']}.');
    }
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
  }
}

/// Offers the machines a probe can travel with and writes the attach.
/// Works for a free probe, a boxed probe and a probe moving from another
/// machine — attaching always clears the old box/machine link.
Future<void> showProbeAttachSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem probe,
) async {
  List<InventoryItem> machines;
  try {
    final rows = await db
        .from('machines')
        .select('id, machine_id, model, serial_number, status, '
            'current_location, acquisition_date')
        .order('machine_id');
    machines = [
      for (final row in rows.cast<Map<String, dynamic>>())
        if (!{
          'Sold',
          'Archived',
          'With Customer',
        }.contains('${row['status'] ?? ''}'))
          InventoryItem(
            kind: 'machine',
            id: row['id'] as int,
            code: (row['machine_id'] ?? '').toString(),
            name: (row['model'] ?? '').toString(),
            serial: row['serial_number'] as String?,
            status: (row['status'] ?? '').toString(),
            location: (row['current_location'] ?? '').toString(),
          ),
    ];
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
    return;
  }
  Set<String> missing;
  try {
    missing = await ref.read(missingItemKeysProvider.future);
  } catch (_) {
    missing = const {};
  }
  machines.removeWhere((machine) => missing.contains(machine.key));
  if (!context.mounted) return;
  if (machines.isEmpty) {
    showSnack(context, 'No machine to attach this probe to.', error: true);
    return;
  }
  final machine = await showPickItem(context, items: machines);
  if (machine == null || !context.mounted) return;
  try {
    await attachProbeToMachine(probe, machine);
    refreshProbePlacement(ref);
    if (context.mounted) {
      showSnack(context, '${probe.code} attached to ${machine.code}.');
    }
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
  }
}

/// Takes a probe off its machine and leaves it free in stock.
Future<void> detachProbe(BuildContext context, WidgetRef ref, InventoryItem probe) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Detach ${probe.code.isEmpty ? 'this probe' : probe.code}?'),
      content: const Text(
        'The probe comes off its machine and goes back to free stock. '
        'You can attach it to another machine afterwards.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Detach'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await detachProbeFromMachine(probe);
    refreshProbePlacement(ref);
    if (context.mounted) {
      showSnack(context, '${probe.code} is off its machine, free in stock.');
    }
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
  }
}
