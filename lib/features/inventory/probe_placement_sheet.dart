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

/// Offers the machines a probe, printer or part can travel with and writes
/// the attach. Works for a free item, a boxed probe and an item moving
/// from another machine — attaching always clears the old box/machine link.
Future<void> showMachineAttachSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item,
) async {
  List<InventoryItem> machines;
  try {
    // fetchAllPages is required: the machines table has more than 1,000 rows
    // and PostgREST silently truncates a plain .select() at that limit,
    // causing machines added after the first 1,000 (alphabetically by
    // machine_id) to never appear in the picker.
    final rows = await fetchAllPages(
      () => db
          .from('machines')
          .select('id, machine_id, model, serial_number, status, '
              'current_location, acquisition_date')
          .order('machine_id'),
    );
    machines = [
      for (final row in rows)
        if (!{
          'Sold',
          'Archived',
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
    showSnack(
      context,
      'No machine to attach this ${item.kindLabel.toLowerCase()} to.',
      error: true,
    );
    return;
  }
  final machine = await showPickItem(context, items: machines);
  if (machine == null || !context.mounted) return;
  try {
    await attachItemToMachine(item, machine);
    refreshProbePlacement(ref);
    if (context.mounted) {
      showSnack(context, '${item.code} attached to ${machine.code}.');
    }
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
  }
}

/// Probe-specific entry point kept for the existing callers.
Future<void> showProbeAttachSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem probe,
) =>
    showMachineAttachSheet(context, ref, probe);

/// The machine-side half of [showMachineAttachSheet]: pick the machine
/// first, then tick the spare parts that go into it. Only free parts are
/// offered - not sold, archived, missing, or already on a machine - and
/// several can be fitted in one go. Each one becomes With Machine at the
/// machine's location and rides along with its kit.
Future<void> showMachinePartsSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem machine,
) async {
  List<InventoryItem> parts;
  try {
    final rows = await fetchAllPages(
      () => db
          .from('parts')
          .select('id, internal_id, name_model, serial_number, status, '
              'current_location, acquisition_date, batch_id, '
              'assigned_machine_id')
          .order('internal_id'),
    );
    parts = [
      for (final row in rows)
        if (row['assigned_machine_id'] == null &&
            !{
              'Sold',
              'Archived',
            }.contains('${row['status'] ?? ''}'))
          InventoryItem(
            kind: 'part',
            id: row['id'] as int,
            code: (row['internal_id'] ?? '').toString(),
            name: (row['name_model'] ?? '').toString(),
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
  parts.removeWhere((part) => missing.contains(part.key));
  if (!context.mounted) return;
  if (parts.isEmpty) {
    showSnack(
      context,
      'No free part to fit to ${machine.code}.',
      error: true,
    );
    return;
  }

  final chosen = await showAppSheet<List<InventoryItem>>(
    context: context,
    title: 'Fit parts to ${machine.code}',
    heightFraction: 0.85,
    builder: (sheetContext) => _MachinePartsPicker(parts: parts),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;

  var fitted = 0;
  String? failure;
  for (final part in chosen) {
    try {
      await attachItemToMachine(part, machine);
      fitted++;
    } catch (error) {
      failure = errorMessage(error);
      break;
    }
  }
  refreshProbePlacement(ref);
  if (!context.mounted) return;
  showSnack(
    context,
    failure ??
        '$fitted part${fitted == 1 ? '' : 's'} fitted to ${machine.code}.',
    error: failure != null,
  );
}

/// Searchable tick-list of the free parts that can be fitted to a machine.
class _MachinePartsPicker extends StatefulWidget {
  const _MachinePartsPicker({required this.parts});

  final List<InventoryItem> parts;

  @override
  State<_MachinePartsPicker> createState() => _MachinePartsPickerState();
}

class _MachinePartsPickerState extends State<_MachinePartsPicker> {
  final _selected = <String>{};
  var _query = '';

  List<InventoryItem> get _matches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.parts;
    return [
      for (final part in widget.parts)
        if (part.code.toLowerCase().contains(q) ||
            part.name.toLowerCase().contains(q) ||
            (part.serial ?? '').toLowerCase().contains(q))
          part,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Tick the parts that go into this machine',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SearchField(
            hint: 'Search ${widget.parts.length} free parts',
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: matches.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off,
                  message: 'No free part matches that search.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: matches.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final part = matches[index];
                    final checked = _selected.contains(part.key);
                    return CheckboxListTile(
                      dense: true,
                      value: checked,
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selected.add(part.key);
                        } else {
                          _selected.remove(part.key);
                        }
                      }),
                      title: Text(
                        '${part.code}  ${part.title}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text('${part.status} · ${part.location}'),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: _selected.isEmpty
                  ? null
                  : () {
                      final chosen = [
                        for (final part in widget.parts)
                          if (_selected.contains(part.key)) part,
                      ];
                      Navigator.pop(context, chosen);
                    },
              icon: const Icon(Icons.link, size: 18),
              label: Text(
                _selected.isEmpty
                    ? 'Select parts to fit'
                    : 'Fit ${_selected.length} part'
                          '${_selected.length == 1 ? '' : 's'}',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Takes a probe, printer or part off its machine and leaves it free in
/// stock.
Future<void> detachItemFromMachineSheet(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Detach ${item.code.isEmpty ? 'this item' : item.code}?'),
      content: Text(
        'The ${item.kindLabel.toLowerCase()} comes off its machine and goes '
        'back to free stock. You can attach it to another machine '
        'afterwards.',
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
    await detachItemFromMachine(item);
    refreshProbePlacement(ref);
    if (context.mounted) {
      showSnack(context, '${item.code} is off its machine, free in stock.');
    }
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
  }
}

/// Takes a probe off its machine and leaves it free in stock.
Future<void> detachProbe(
  BuildContext context,
  WidgetRef ref,
  InventoryItem probe,
) =>
    detachItemFromMachineSheet(context, ref, probe);
