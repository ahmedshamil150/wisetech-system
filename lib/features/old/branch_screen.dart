import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/flag_sheet.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart' show showItemDetails;
import 'old_data.dart';
import 'old_item_form.dart';

/// The Branch page: everything the shop has sent to the Lahore branch,
/// on one screen and laid out the way the Inventory page lays its items
/// out — a machine card with its probes, printer and parts tucked
/// underneath it.
class BranchScreen extends ConsumerStatefulWidget {
  const BranchScreen({super.key});

  @override
  ConsumerState<BranchScreen> createState() => _BranchScreenState();
}

class _BranchScreenState extends ConsumerState<BranchScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(branchItemsProvider);
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
    // the provider hands machines newest first, so the latest branch
    // arrival heads the page
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search branch items',
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
              'Lahore branch · ${machinesById.length} machines · '
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
                )
              : rows.isEmpty
              ? const EmptyState(
                  icon: Icons.storefront_outlined,
                  message: 'No items at the branch yet.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    for (final machine in machines) ...[
                      _BranchTile(row: machine),
                      for (final member in _sortedKit(
                        kit[machine['id']] ?? const [],
                      ))
                        _BranchTile(
                          row: member,
                          indented: true,
                          withCode: '${machine['machine_id'] ?? ''}',
                        ),
                    ],
                    if (loose.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Other branch items',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                      for (final row in _latestFirst(loose))
                        _BranchTile(row: row),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// Newest row first — the branch page always shows the latest arrival on
/// top, the way the Inventory and Movements lists do.
List<Map<String, dynamic>> _latestFirst(List<Map<String, dynamic>> rows) {
  return [...rows]
    ..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
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

IconData _kindIcon(String kind) => switch (kind) {
  'machine' => Icons.monitor_outlined,
  'probe' => Icons.cable_outlined,
  'printer' => Icons.print_outlined,
  _ => Icons.settings_outlined,
};

InventoryItem _toItem(Map<String, dynamic> row) {
  final kind = row['kind'] as String;
  final date = '${row['acquisition_date'] ?? ''}';
  return InventoryItem(
    kind: kind,
    id: row['id'] as int,
    code: '${row[codeColumnFor(kind)] ?? ''}',
    name: '${row[nameColumnFor(kind)] ?? ''}',
    serial: '${row['serial_number'] ?? ''}',
    status: '${row['status'] ?? ''}',
    location: '${row['current_location'] ?? ''}',
    date: date.isEmpty ? null : date,
    assignedMachineId: row['assigned_machine_id'] is int
        ? row['assigned_machine_id'] as int
        : null,
  );
}

/// One branch row, drawn exactly like the Inventory list: code on top,
/// name · serial and the status chip below, the location on the right.
class _BranchTile extends ConsumerWidget {
  const _BranchTile({required this.row, this.indented = false, this.withCode});

  final Map<String, dynamic> row;
  final bool indented;
  final String? withCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = row['kind'] as String;
    final code = '${row[codeColumnFor(kind)] ?? ''}';
    final name = '${row[nameColumnFor(kind)] ?? ''}';
    final serial = '${row['serial_number'] ?? ''}';
    final phone = isPhoneLayout(context);
    final detail = [
      '${row['current_location'] ?? ''}',
      if ((withCode ?? '').isNotEmpty) 'with $withCode',
    ].where((value) => value.isNotEmpty).join(' · ');
    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: indented ? 32 : 0),
      child: AppCard(
        child: ListTile(
          onTap: () => showItemDetails(context, ref, _toItem(row)),
          leading: CircleAvatar(
            backgroundColor: context.colors.tintBlue,
            child: Icon(
              _kindIcon(kind),
              size: indented ? 18 : 22,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: Text(
            code.isEmpty ? name : code,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: phone ? 13.5 : 14,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                serial.isEmpty ? name : '$name · $serial',
                style: TextStyle(fontSize: phone ? 12 : 13),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  StatusChip(status: '${row['status'] ?? ''}'),
                  const SizedBox(width: 6),
                  FlagDot(targetKey: flagItemKey(kind, row['id'] as int)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: phone ? 11.5 : 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
        ),
      ),
    );
  }
}
