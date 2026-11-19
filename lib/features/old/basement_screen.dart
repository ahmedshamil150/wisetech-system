import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/widgets.dart';
import '../data/data.dart';
import 'basement_data.dart';
import 'move_item_sheet.dart';
import 'old_item_form.dart';
import 'old_item_tile.dart';

/// The Basement page: the machines kept downstairs, laid out the same way
/// the Inventory and Branch pages lay their items out — a machine card
/// with its probes, printer and parts tucked underneath it.
///
/// Basement stock never appears on the Inventory list. Every row here can
/// be opened, flagged and edited exactly like an Inventory row, and the
/// swap button sends the item (and its kit) back to the Inventory or the
/// Workshop.
class BasementScreen extends ConsumerStatefulWidget {
  const BasementScreen({super.key});

  @override
  ConsumerState<BasementScreen> createState() => _BasementScreenState();
}

class _BasementScreenState extends ConsumerState<BasementScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(basementItemsProvider);
    final rows = async.maybeWhen(
      data: (rows) => rows,
      orElse: () => const <Map<String, dynamic>>[],
    );
    final term = _search.text.trim().toLowerCase();

    bool matches(Map<String, dynamic> row) {
      final kind = row['kind'] as String;
      return [
        row[codeColumnFor(kind)],
        row[nameColumnFor(kind)],
        row['serial_number'],
        row['current_location'],
      ].any((value) => '${value ?? ''}'.toLowerCase().contains(term));
    }

    final machinesById = <int, Map<String, dynamic>>{
      for (final row in rows)
        if (row['kind'] == 'machine') row['id'] as int: row,
    };
    final visibleMachineIds = <int>{};
    if (term.isEmpty) {
      visibleMachineIds.addAll(machinesById.keys);
    } else {
      for (final entry in machinesById.entries) {
        if (matches(entry.value)) visibleMachineIds.add(entry.key);
      }
      // a matching probe brings its machine along, so the pair stays
      // together the way it reads on the Inventory page
      for (final row in rows) {
        if (row['kind'] == 'machine' || !matches(row)) continue;
        final machineId = row['assigned_machine_id'];
        if (machineId is int && machinesById.containsKey(machineId)) {
          visibleMachineIds.add(machineId);
        }
      }
    }
    final machines = [for (final id in visibleMachineIds) machinesById[id]!];
    final kit = <int, List<Map<String, dynamic>>>{};
    final loose = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row['kind'] == 'machine') continue;
      if (term.isNotEmpty && !matches(row)) continue;
      final machineId = row['assigned_machine_id'];
      if (machineId is int && visibleMachineIds.contains(machineId)) {
        (kit[machineId] ??= []).add(row);
      } else {
        loose.add(row);
      }
    }

    final probeCount = rows.where((row) => row['kind'] == 'probe').length;
    final printerCount = rows.where((row) => row['kind'] == 'printer').length;
    final partCount = rows.where((row) => row['kind'] == 'part').length;

    final listChildren = <Widget>[];
    for (final machine in machines) {
      listChildren.add(_tile(machine));
      for (final member in _sortedKit(kit[machine['id']] ?? const [])) {
        listChildren.add(
          _tile(
            member,
            indented: true,
            withCode: '${machine['machine_id'] ?? ''}',
          ),
        );
      }
    }
    if (loose.isNotEmpty) {
      listChildren.add(const _SectionHeader('Other basement items'));
      for (final row in _latestFirst(loose)) {
        listChildren.add(_tile(row));
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search basement items',
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Basement · ${machinesById.length} machines · '
              '$probeCount probes · $printerCount printers'
              '${partCount == 0 ? '' : ' · $partCount parts'}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.outline,
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
                  onRetry: () => ref.invalidate(basementItemsProvider),
                )
              : rows.isEmpty
              ? const EmptyState(
                  icon: Icons.stairs_outlined,
                  message: 'No items in the basement yet.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: listChildren.length,
                  itemBuilder: (_, index) => listChildren[index],
                ),
        ),
      ],
    );
  }

  /// A basement row with the quick "move out" button on the right. Tapping
  /// the row itself still opens the same details sheet Inventory uses.
  Widget _tile(
    Map<String, dynamic> row, {
    bool indented = false,
    String? withCode,
  }) {
    return OldItemTile(
      row: row,
      indented: indented,
      withCode: withCode,
      trailing: IconButton(
        tooltip: 'Move to Inventory or Workshop',
        icon: const Icon(Icons.swap_horiz, size: 20),
        onPressed: () => showBasementMoveMenu(context, ref, row),
      ),
    );
  }
}

/// Heading for basement items that do not travel with a machine.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

/// Newest row first — the basement page shows the latest row on top, the
/// way the Inventory and Movements lists do.
List<Map<String, dynamic>> _latestFirst(List<Map<String, dynamic>> rows) {
  return [...rows]..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
}

/// Machines first (printer, probe, part), then by serial so a kit reads
/// the same way the Inventory page orders it.
List<Map<String, dynamic>> _sortedKit(List<Map<String, dynamic>> rows) {
  int rank(Map<String, dynamic> row) => switch (row['kind']) {
    'printer' => 0,
    'probe' => 1,
    _ => 2,
  };
  return [...rows]..sort((a, b) {
    final byKind = rank(a).compareTo(rank(b));
    if (byKind != 0) return byKind;
    return _naturalCompare(
      '${a['serial_number'] ?? ''}',
      '${b['serial_number'] ?? ''}',
    );
  });
}

/// Sorts ids the way a person counts: 23T before 60T before 100T.
int _naturalCompare(String a, String b) {
  final ra = RegExp(r'^(\d+)(.*)$').firstMatch(a);
  final rb = RegExp(r'^(\d+)(.*)$').firstMatch(b);
  if (ra != null && rb != null) {
    final byNumber = int.parse(ra.group(1)!).compareTo(int.parse(rb.group(1)!));
    if (byNumber != 0) return byNumber;
    return ra.group(2)!.compareTo(rb.group(2)!);
  }
  if (ra != null) return -1;
  if (rb != null) return 1;
  return a.compareTo(b);
}
