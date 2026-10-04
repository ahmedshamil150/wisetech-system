import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../records/records_screen.dart';

/// Full list of machines, probes, printers and parts, newest first.
/// Admins get an "Add product" form; viewers can only browse.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

/// "Equipment" = machines, probes and printers. Parts are so numerous that
/// they only show up under their own chip. Boxes shows where the leftover
/// probes are kept.
const _typeFilters = ['Equipment', 'Machine', 'Probe', 'Printer', 'Part', 'Boxes'];

/// Status row under the type row. "In Stock" covers both words the app
/// uses for stock — machines say "In Stock", everything else says
/// "Available". Sold items never appear in the inventory, so there is
/// no chip for them.
const _statusFilters = [
  'All',
  'In Stock',
  'With Machine',
  'With Workshop',
  'With Branch',
  'With Dealer',
  'With Customer',
  'Archived',
];

/// Newest item first, the order the whole list already uses.
int _newestFirst(InventoryItem a, InventoryItem b) {
  final byDate =
      (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
  return byDate != 0 ? byDate : b.id.compareTo(a.id);
}

/// Inside one machine: printer, then probes, then anything else.
int _kitRank(InventoryItem item) => switch (item.kind) {
      'printer' => 0,
      'probe' => 1,
      _ => 2,
    };

/// Arranges the visible rows as kits - a machine followed by its printer and
/// its probes, then the next machine, and so on. The bool says whether the
/// row belongs under the machine above it (drawn indented).
List<(InventoryItem, bool)> arrangeAsKits(List<InventoryItem> items) {
  final machines = items.where((item) => item.kind == 'machine').toList()
    ..sort(_newestFirst);
  final machineIds = machines.map((machine) => machine.id).toSet();

  final kits = <int, List<InventoryItem>>{};
  final loose = <InventoryItem>[];
  for (final item in items) {
    if (item.kind == 'machine') continue;
    final machineId = item.assignedMachineId;
    if (machineId != null && machineIds.contains(machineId)) {
      kits.putIfAbsent(machineId, () => <InventoryItem>[]).add(item);
    } else {
      loose.add(item);
    }
  }
  for (final members in kits.values) {
    members.sort((a, b) {
      final byKind = _kitRank(a).compareTo(_kitRank(b));
      return byKind != 0 ? byKind : _newestFirst(a, b);
    });
  }
  // Items with no machine shown here stay together, grouped by the machine
  // they are assigned to; completely loose ones come last.
  loose.sort((a, b) {
    final byMachine =
        (b.assignedMachineId ?? -1).compareTo(a.assignedMachineId ?? -1);
    if (byMachine != 0) return byMachine;
    final byKind = _kitRank(a).compareTo(_kitRank(b));
    return byKind != 0 ? byKind : _newestFirst(a, b);
  });

  return [
    for (final machine in machines) ...[
      (machine, false),
      for (final member in kits[machine.id] ?? const <InventoryItem>[])
        (member, true),
    ],
    for (final item in loose) (item, false),
  ];
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _query = '';
  String _type = 'Equipment';
  String _status = 'All';

  bool _matchesFilter(InventoryItem item) => switch (_type) {
        'Equipment' => item.kind != 'part',
        'Machine' => item.kind == 'machine',
        'Probe' => item.kind == 'probe',
        'Printer' => item.kind == 'printer',
        _ => item.kind == 'part',
      };

  bool _matchesQuery(InventoryItem item) {
    if (_query.isEmpty) return true;
    return item.code.toLowerCase().contains(_query) ||
        item.name.toLowerCase().contains(_query) ||
        (item.serial ?? '').toLowerCase().contains(_query);
  }

  bool _matchesStatus(InventoryItem item) => switch (_status) {
        'All' => true,
        'In Stock' =>
          item.status == 'In Stock' || item.status == 'Available',
        _ => item.status == _status,
      };

  /// Numbers for the type chips — counted after the status filter and
  /// the search, so the number always matches what a tap would show.
  Map<String, int> _typeCounts(
      List<InventoryItem> rows, List<Map<String, dynamic>> boxes) {
    final counts = <String, int>{
      'Machine': 0,
      'Probe': 0,
      'Printer': 0,
      'Part': 0,
      'Equipment': 0,
    };
    for (final item in rows) {
      if (item.isSold || !_matchesStatus(item) || !_matchesQuery(item)) {
        continue;
      }
      counts[item.kind] = (counts[item.kind] ?? 0) + 1;
      if (item.kind != 'part') {
        counts['Equipment'] = counts['Equipment']! + 1;
      }
    }
    var boxCount = 0;
    for (final box in boxes) {
      if (_query.isNotEmpty) {
        final name = (box['name'] ?? '').toString().toLowerCase();
        final type = (box['probe_type'] ?? '').toString().toLowerCase();
        if (!name.contains(_query) && !type.contains(_query)) continue;
      }
      boxCount++;
    }
    counts['Boxes'] = boxCount;
    return counts;
  }

  /// Numbers for the status chips — counted after the type filter and
  /// the search.
  Map<String, int> _statusCounts(List<InventoryItem> rows) {
    final counts = <String, int>{for (final f in _statusFilters) f: 0};
    for (final item in rows) {
      if (item.isSold || !_matchesFilter(item) || !_matchesQuery(item)) {
        continue;
      }
      counts['All'] = counts['All']! + 1;
      if (item.status == 'In Stock' || item.status == 'Available') {
        counts['In Stock'] = counts['In Stock']! + 1;
      } else {
        counts[item.status] = (counts[item.status] ?? 0) + 1;
      }
    }
    return counts;
  }

  Widget _filterChip(BuildContext context, String label, int count,
      {required bool selected, required VoidCallback onTap}) {
    return ChoiceChip(
      label: Text('$label ($count)'),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: Theme.of(context).colorScheme.primary,
      labelStyle: TextStyle(
        color: selected ? Colors.white : kMuted,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      backgroundColor: Colors.white,
      side: const BorderSide(color: Color(0xFFE2E9F0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final items = ref.watch(inventoryProvider);
    final allRows = items.maybeWhen(
        data: (rows) => rows, orElse: () => const <InventoryItem>[]);
    final boxes = ref.watch(probeBoxesProvider).maybeWhen(
        data: (rows) => rows, orElse: () => const <Map<String, dynamic>>[]);
    final typeCounts = _typeCounts(allRows, boxes);
    final statusCounts = _statusCounts(allRows);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: SearchField(
                  hint: 'Search by code, model or serial',
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
              if (isAdmin) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Stock check',
                  icon: const Icon(Icons.fact_check_outlined),
                  onPressed: () => showStockCheckSheet(context),
                ),
              ],
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _typeFilters.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final label = _typeFilters[index];
              return _filterChip(
                context,
                label,
                typeCounts[label] ?? 0,
                selected: _type == label,
                onTap: () => setState(() => _type = label),
              );
            },
          ),
        ),
        if (_type != 'Boxes') ...[
          const SizedBox(height: 4),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _statusFilters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final label = _statusFilters[index];
                return _filterChip(
                  context,
                  label,
                  statusCounts[label] ?? 0,
                  selected: _status == label,
                  onTap: () => setState(() => _status = label),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 4),
        Expanded(
          child: _type == 'Boxes'
              ? _boxesList(context)
              : items.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (rows) {
              final filtered = rows.where((item) {
                // A sold machine already belongs to the dealer or customer,
                // so it must not show up in the inventory any more.
                if (item.isSold) return false;
                if (!_matchesFilter(item)) return false;
                if (!_matchesStatus(item)) return false;
                if (!_matchesQuery(item)) return false;
                return true;
              }).toList();
              final entries = arrangeAsKits(filtered);
              if (entries.isEmpty) {
                return const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    message: 'No items match this filter.');
              }
              return AppRefresh(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _itemTile(
                    context,
                    entries[index].$1,
                    indented: entries[index].$2,
                  ),
                ),
              );
            },
          ),
        ),
        if (isAdmin && _type != 'Boxes')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (sheetContext) => Padding(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                  child: const _AddItemForm(),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add product'),
            ),
          ),
      ],
    );
  }

  /// The Boxes chip: every box, its probe type and how many probes are in it.
  Widget _boxesList(BuildContext context) {
    final boxes = ref.watch(probeBoxesProvider);
    final items = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );

    return boxes.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final filtered = rows.where((row) {
          if (_query.isEmpty) return true;
          final name = (row['name'] ?? '').toString().toLowerCase();
          final type = (row['probe_type'] ?? '').toString().toLowerCase();
          return name.contains(_query) || type.contains(_query);
        }).toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.inbox_outlined,
              message: 'No boxes yet. The admin adds them under Records.');
        }
        return AppRefresh(
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final box = filtered[index];
            final count = items
                .where(
                    (item) => item.kind == 'probe' && item.boxId == box['id'])
                .length;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEAF3F8),
                    child: Icon(Icons.inbox_outlined),
                  ),
                  title: Text((box['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${box['probe_type']} · $count probes'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => showBoxSheet(context, ref, box),
                ),
              ),
            );
            },
          ),
        );
      },
    );
  }

  Widget _itemTile(BuildContext context, InventoryItem item,
      {bool indented = false}) {
    final icon = _kindIcon(item.kind);
    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: indented ? 32 : 0),
      child: AppCard(
        child: ListTile(
          onTap: () => showItemDetails(context, ref, item),
          leading: CircleAvatar(
            backgroundColor: const Color(0xFFEAF3F8),
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          title: Text(item.code,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title),
              const SizedBox(height: 4),
              Row(
                children: [
                  StatusChip(status: item.status),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${item.location}${item.date == null ? '' : ' · ${item.date}'}',
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 12, color: kHint),
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

IconData _kindIcon(String kind) => switch (kind) {
      'machine' => Icons.monitor_outlined,
      'probe' => Icons.cable_outlined,
      'printer' => Icons.print_outlined,
      _ => Icons.settings_outlined,
    };

/// Sorts machine ids the way a person counts: 23T before 60T before
/// 100T, letters staying together.
int _naturalCompare(String a, String b) {
  final ra = RegExp(r'^(\d+)(.*)$').firstMatch(a);
  final rb = RegExp(r'^(\d+)(.*)$').firstMatch(b);
  if (ra != null && rb != null) {
    final byNumber = int.parse(ra.group(1)!).compareTo(int.parse(rb.group(1)!));
    if (byNumber != 0) return byNumber;
    return ra.group(2)!.compareTo(rb.group(2)!);
  }
  return a.toLowerCase().compareTo(b.toLowerCase());
}

/// The categories a physical count can target, and what counts as
/// "in stock" for each: machines say "In Stock", everything else
/// says "Available".
const _stockKinds = [
  ('machine', 'Machines'),
  ('probe', 'Probes'),
  ('printer', 'Printers'),
  ('part', 'Parts'),
];

String _stockStatusFor(String kind) => kind == 'machine' ? 'In Stock' : 'Available';

/// Admin tool for a physical count: pick a category, type the ids of
/// the items you can see in the room, and the sheet lists everything
/// the app still has as in stock that was not typed — plus typed ids
/// the app has as out, in a different category, or does not know.
Future<void> showStockCheckSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.of(sheetContext).size.height * 0.85,
      child: const _StockCheckSheet(),
    ),
  );
}

class _StockCheckSheet extends ConsumerStatefulWidget {
  const _StockCheckSheet();

  @override
  ConsumerState<_StockCheckSheet> createState() => _StockCheckSheetState();
}

class _StockCheckSheetState extends ConsumerState<_StockCheckSheet> {
  final _input = TextEditingController();
  String _kind = 'machine';

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Whatever was typed, split on newlines / spaces / commas and
  /// normalised so "23t" matches "23T".
  Set<String> get _entered => _input.text
      .toUpperCase()
      .split(RegExp(r'[\s,;]+'))
      .where((token) => token.isNotEmpty)
      .toSet();

  /// An item matches a typed token by its code or its serial, so the
  /// count works whether the label shows the WT number or the maker's.
  static InventoryItem? _matchToken(
      String token, Iterable<InventoryItem> pool) {
    for (final item in pool) {
      if (item.code.toUpperCase() == token) return item;
      final serial = item.serial;
      if (serial != null && serial.isNotEmpty && serial.toUpperCase() == token) {
        return item;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    final stockStatus = _stockStatusFor(_kind);
    final sameKind = [for (final item in items) if (item.kind == _kind) item];
    final expected = [
      for (final item in sameKind)
        if (item.status == stockStatus) item,
    ]..sort((a, b) => _naturalCompare(a.code, b.code));

    final entered = _entered;
    final missing = [
      for (final item in expected)
        if (!entered.contains(item.code.toUpperCase()) &&
            (item.serial == null ||
                item.serial!.isEmpty ||
                !entered.contains(item.serial!.toUpperCase())))
          item,
    ];
    final seenOut = <InventoryItem>[];
    final wrongKind = <InventoryItem>[];
    final unknown = <String>[];
    for (final token in entered) {
      final found = _matchToken(token, sameKind);
      if (found != null) {
        if (found.status != stockStatus) seenOut.add(found);
        continue;
      }
      final elsewhere = _matchToken(token, items);
      if (elsewhere != null) {
        wrongKind.add(elsewhere);
      } else {
        unknown.add(token);
      }
    }
    seenOut.sort((a, b) => _naturalCompare(a.code, b.code));
    wrongKind.sort((a, b) => _naturalCompare(a.code, b.code));
    unknown.sort(_naturalCompare);

    final kindWord =
        _kind[0].toUpperCase() + _kind.substring(1); // Machine, Probe, …
    const sectionStyle =
        TextStyle(fontSize: 15, fontWeight: FontWeight.w800);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Stock check',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
            'Pick what you are counting, then type the IDs you see — '
            'one per line, or separated by spaces or commas.',
            style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (kind, label) in _stockKinds)
              ChoiceChip(
                label: Text(
                    '$label (${[for (final item in items) if (item.kind == kind && item.status == _stockStatusFor(kind)) item].length})'),
                selected: _kind == kind,
                onSelected: (_) => setState(() {
                  if (_kind != kind) {
                    _kind = kind;
                    _input.clear();
                  }
                }),
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: _kind == kind ? Colors.white : kMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFE2E9F0)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _input,
          minLines: 4,
          maxLines: 6,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: '$kindWord IDs you can see',
            hintText: _kind == 'machine'
                ? '23T\n60T\n71T'
                : 'Serial or WT number\none per line',
          ),
        ),
        const SizedBox(height: 16),
        AppCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              KeyValue(
                  label: 'App expects in stock',
                  value: '${expected.length}'),
              KeyValue(label: 'You typed', value: '${entered.length}'),
              KeyValue(label: 'Missing', value: '${missing.length}'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (entered.isEmpty)
          const Text(
              'Type what you see — the items you missed are listed here.',
              style: TextStyle(color: kHint, fontSize: 13))
        else ...[
          Text('Missing — should be in stock (${missing.length})',
              style: sectionStyle),
          const SizedBox(height: 8),
          if (missing.isEmpty)
            const Text(
                'Everything the app expects in stock was counted.',
                style: TextStyle(color: Color(0xFF1B7F4B), fontSize: 13.5))
          else
            AppCard(
              padding: const EdgeInsets.all(4),
              child: Column(
                children: [
                  for (final item in missing)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.help_outline, size: 20),
                      title: Text(item.code,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      subtitle: Text('${item.title} · ${item.location}',
                          style: const TextStyle(fontSize: 12.5)),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => showItemDetails(context, ref, item),
                    ),
                ],
              ),
            ),
          if (seenOut.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('You typed these — the app says they are out (${seenOut.length})',
                style: sectionStyle),
            const SizedBox(height: 8),
            AppCard(
              padding: const EdgeInsets.all(4),
              child: Column(
                children: [
                  for (final item in seenOut)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.outbox_outlined, size: 20),
                      title: Text(item.code,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      subtitle: Text('${item.status} · ${item.location}',
                          style: const TextStyle(fontSize: 12.5)),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () => showItemDetails(context, ref, item),
                    ),
                ],
              ),
            ),
          ],
          if (wrongKind.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
                'Found, but not a ${kindWord.toLowerCase()} (${wrongKind.length})',
                style: sectionStyle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in wrongKind)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1668A8).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFD5E4F2)),
                    ),
                    child: Text('${item.code} · ${item.kindLabel}',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1668A8))),
                  ),
              ],
            ),
          ],
          if (unknown.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Not found in the app (${unknown.length})',
                style: sectionStyle),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final token in unknown)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFB3261E).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFF1D9D7)),
                    ),
                    child: Text(token,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFB3261E))),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

/// Sheet for one box: the probes inside it and a way to put more in.
Future<void> showBoxSheet(
    BuildContext context, WidgetRef ref, Map<String, dynamic> box) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.75,
        child: _BoxSheet(box: box),
      ),
    ),
  );
}

class _BoxSheet extends ConsumerStatefulWidget {
  const _BoxSheet({required this.box});

  final Map<String, dynamic> box;

  @override
  ConsumerState<_BoxSheet> createState() => _BoxSheetState();
}

class _BoxSheetState extends ConsumerState<_BoxSheet> {
  bool _adding = false;
  bool _loadingId = true;
  bool _saving = false;
  String? _id;
  final _model = TextEditingController();
  final _serial = TextEditingController();

  @override
  void dispose() {
    _model.dispose();
    _serial.dispose();
    super.dispose();
  }

  Future<void> _loadId() async {
    setState(() => _loadingId = true);
    try {
      final id = await suggestedId('probe');
      if (mounted) setState(() => _id = id);
    } catch (_) {
      if (mounted) setState(() => _id = null);
    } finally {
      if (mounted) setState(() => _loadingId = false);
    }
  }

  /// Creates a brand-new probe straight into this box — for stock that
  /// is not in the inventory yet.
  Future<void> _createProbe() async {
    final model = _model.text.trim();
    if (model.isEmpty) {
      showSnack(context, 'Model is required.', error: true);
      return;
    }
    if (_id == null || _id!.isEmpty) {
      showSnack(context, 'The ID could not be generated.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final type = (widget.box['probe_type'] ?? '').toString();
      final productId = await resolveReferenceId(
        table: 'catalog_products',
        name: model,
        payload: {
          'category': 'Probe',
          if (type.isNotEmpty) 'probe_type': type,
        },
      );
      final wantSerial = _serial.text.trim().isEmpty;
      final row = await db.from('probes').insert({
        'internal_id': _id,
        'model': model,
        'catalog_product_id': productId,
        'status': 'Available',
        'current_location': (widget.box['name'] ?? '').toString(),
        'box_id': widget.box['id'],
        if (!wantSerial) 'serial_number': _serial.text.trim(),
      }).select('serial_number').single();
      ref.invalidate(inventoryProvider);
      if (!mounted) return;
      setState(() {
        _adding = false;
        _saving = false;
        _model.clear();
        _serial.clear();
      });
      final serialNote = wantSerial
          ? ' — serial ${row['serial_number']}'
          : '';
      messenger.showSnackBar(SnackBar(
          content:
              Text('$_id added to ${widget.box['name']}$serialNote.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final items = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    final productNames = ref.watch(productsProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name_model'].toString()).toList(),
          orElse: () => const <String>[],
        );
    final box = widget.box;
    final type = (box['probe_type'] ?? '').toString();
    final inBox = items
        .where((item) => item.kind == 'probe' && item.boxId == box['id'])
        .toList();
    final candidates = items.where((item) {
      if (item.kind != 'probe') return false;
      if (item.status == 'Sold' ||
          item.status == 'Archived' ||
          item.status == 'With Customer') {
        return false;
      }
      if (item.boxId != null) return false;
      final probeType = item.probeType;
      return probeType == null || probeType.isEmpty || probeType == type;
    }).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text((box['name'] ?? '').toString(),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(type,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary)),
            ),
          ],
        ),
        if (((box['notes'] ?? '') as String).isNotEmpty) ...[
          const SizedBox(height: 4),
          Text((box['notes'] ?? '').toString(),
              style: const TextStyle(color: kMuted)),
        ],
        const SizedBox(height: 16),
        const Text('Probes in this box',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (inBox.isEmpty)
          const Text('Empty — no probes in it yet.',
              style: TextStyle(color: kMuted, fontSize: 13))
        else
          AppCard(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: [
                for (final item in inBox)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.cable_outlined, size: 20),
                    title: Text('${item.code}  ${item.title}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                    subtitle: Text('${item.status} · ${item.location}'),
                    trailing: isAdmin
                        ? IconButton(
                            tooltip: 'Take out of the box',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () async {
                              try {
                                await takeProbeOutOfBox(item);
                                ref.invalidate(inventoryProvider);
                              } catch (error) {
                                if (!context.mounted) return;
                                showSnack(context, errorMessage(error),
                                    error: true);
                              }
                            },
                          )
                        : null,
                  ),
              ],
            ),
          ),
        if (isAdmin) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: candidates.isEmpty
                ? null
                : () async {
                    final picked =
                        await showPickItem(context, items: candidates);
                    if (picked == null) return;
                    try {
                      await putProbeInBox(picked, box);
                      ref.invalidate(inventoryProvider);
                    } catch (error) {
                      if (!context.mounted) return;
                      showSnack(context, errorMessage(error), error: true);
                    }
                  },
            icon: const Icon(Icons.add),
            label: Text(candidates.isEmpty
                ? 'No probe available'
                : 'Add probe (${candidates.length})'),
          ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'No $type probe is free to box right now.',
                  style: const TextStyle(color: kMuted, fontSize: 12.5)),
            ),
          const SizedBox(height: 8),
          if (!_adding)
            OutlinedButton.icon(
              onPressed: () {
                setState(() => _adding = true);
                _loadId();
              },
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: const Text('New probe (not in stock yet)'),
            )
          else ...[
            AppCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('New ${type.isEmpty ? 'probe' : type} probe',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  PickyField(
                    controller: _model,
                    label: 'Model *',
                    hint: 'Start typing — suggestions appear',
                    options: productNames,
                    pickTitle: 'models',
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _serial,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'Serial number (optional)',
                        hintText: 'Empty → system number (WT-…)'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.lock_outline, size: 16, color: kHint),
                      const SizedBox(width: 6),
                      Text(
                        _loadingId
                            ? 'Generating ID…'
                            : 'ID: ${_id ?? 'not available'}',
                        style:
                            const TextStyle(fontSize: 13, color: kMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() => _adding = false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed:
                              _saving || _loadingId ? null : _createProbe,
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('Create'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// Read-only sheet with everything we know about one item.
Future<void> showItemDetails(
    BuildContext context, WidgetRef ref, InventoryItem item) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.of(sheetContext).size.height * 0.75,
      child: _ItemDetails(item: item),
    ),
  );
}

class _ItemDetails extends ConsumerWidget {
  const _ItemDetails({required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // always use the freshest copy so status and location refresh
    // right after a return
    final all = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    final item = all.firstWhere((i) => i.key == this.item.key,
        orElse: () => this.item);
    final history = ref
        .watch(movementsProvider)
        .maybeWhen(
            data: (rows) => rows, orElse: () => const <Map<String, dynamic>>[])
        .where((row) => row['${item.kind}_id'] == item.id)
        .toList();
    final canReturn =
        history.isNotEmpty && history.first['movement_type'] != 'Return';
    final isAdmin = ref.watch(isAdminProvider);
    final myId = ref.read(authControllerProvider).currentUser?.id;
    final linked = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => linkedItems(rows, item),
          orElse: () => const <InventoryItem>[],
        );
    final boxName = ref.watch(probeBoxesProvider).maybeWhen(
          data: (boxes) => boxes
              .where((row) => row['id'] == item.boxId)
              .map((row) => (row['name'] ?? '').toString())
              .join(),
          orElse: () => '',
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(item.code,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            StatusChip(status: item.status),
          ],
        ),
        Text(item.title, style: const TextStyle(color: kMuted)),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              KeyValue(label: 'Type', value: item.kindLabel),
              KeyValue(label: 'Serial', value: item.serial ?? '—'),
              KeyValue(label: 'Location', value: item.location),
              if (item.boxId != null && boxName.isNotEmpty)
                KeyValue(label: 'Box', value: boxName),
              KeyValue(label: 'Acquired', value: item.date ?? '—'),
              KeyValue(label: 'Batch', value: item.batch ?? '—'),
            ],
          ),
        ),
        if (isAdmin) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (sheetContext) => Padding(
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.of(sheetContext)
                              .viewInsets
                              .bottom),
                      child: _EditItemForm(item: item),
                    ),
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () => _confirmDelete(context, ref),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
              ),
            ],
          ),
        ],
        if (canReturn) ...[
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => _returnToInventory(context, ref),
            icon: const Icon(Icons.undo_outlined, size: 20),
            label: const Text('Return to inventory'),
          ),
        ],
        if (linked.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('Linked items',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          AppCard(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: [
                for (final other in linked)
                  ListTile(
                    dense: true,
                    leading: Icon(_kindIcon(other.kind),
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    title: Text('${other.code}  ${other.title}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                    subtitle:
                        Text('${other.kindLabel} · ${other.status}'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => showItemDetails(context, ref, other),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text('Movements',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (history.isEmpty)
          const Text('No movements recorded for this item.',
              style: TextStyle(color: kMuted, fontSize: 13))
        else
          AppCard(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: [
                for (final row in history)
                  ListTile(
                    dense: true,
                    leading: Icon(_historyIcon('${row['movement_type']}'),
                        size: 20,
                        color: row['movement_type'] == 'Return'
                            ? const Color(0xFF2E7D32)
                            : Theme.of(context).colorScheme.primary),
                    title: Text(_historyTitle(row),
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_historyMeta(row),
                            style: const TextStyle(
                                fontSize: 12, color: kMuted)),
                        if ('${row['notes'] ?? ''}'.trim().isNotEmpty)
                          Text('${row['notes']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: kHint)),
                      ],
                    ),
                    trailing: isAdmin || row['actor_id'] == myId
                        ? IconButton(
                            tooltip: 'Delete this movement',
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () =>
                                _deleteMovement(context, ref, row),
                          )
                        : null,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Confirm dialog, then the RPC does status, location and history in one
  /// call. The sheet stays open and refreshes by itself.
  Future<void> _returnToInventory(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Return to inventory?'),
        content: Text(
            '${item.code} will go back to stock and a Return movement '
            'will be recorded in its history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Return'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await returnToInventory(item);
      ref
        ..invalidate(movementsProvider)
        ..invalidate(inventoryProvider);
      if (context.mounted) {
        showSnack(context, '${item.code} is back in inventory.');
      }
    } catch (error) {
      if (context.mounted) showSnack(context, errorMessage(error), error: true);
    }
  }

  /// Erases just this one movement — the rest of the send keeps its rows
  /// and the item takes its status from the history that is left, so an
  /// accidental move falls out of the record (0014).
  Future<void> _deleteMovement(
      BuildContext context, WidgetRef ref, Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this movement?'),
        content: const Text(
            'The item returns to inventory. The other movements of this '
            'send are not touched.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await deleteMovementRow(row['id'] as int);
      ref
        ..invalidate(movementsProvider)
        ..invalidate(inventoryProvider);
      if (context.mounted) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Movement deleted.')));
      }
    } catch (error) {
      if (context.mounted) showSnack(context, errorMessage(error), error: true);
    }
  }

  /// Confirm, then hard-delete. The sheet closes; blocked deletes (still in
  /// use by movements or linked items) surface the database's reason.
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${item.code}?'),
        content: const Text(
            'It disappears from inventory. If anything still points at it, '
            'the app will show why it cannot be deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await db.from(_tableForKind(item.kind)).delete().eq('id', item.id);
      ref
        ..invalidate(inventoryProvider)
        ..invalidate(movementsProvider);
      if (!context.mounted) return;
      Navigator.pop(context);
      messenger
          .showSnackBar(SnackBar(content: Text('${item.code} deleted.')));
    } catch (error) {
      if (context.mounted) showSnack(context, errorMessage(error), error: true);
    }
  }
}

String _tableForKind(String kind) => switch (kind) {
      'machine' => 'machines',
      'probe' => 'probes',
      'printer' => 'printers',
      _ => 'parts',
    };

String _nameColumnForKind(String kind) =>
    kind == 'machine' || kind == 'probe' ? 'model' : 'name_model';

/// Admin edit sheet for an existing item: name, serial, status, location,
/// notes.
class _EditItemForm extends ConsumerStatefulWidget {
  const _EditItemForm({required this.item});

  final InventoryItem item;

  @override
  ConsumerState<_EditItemForm> createState() => _EditItemFormState();
}

class _EditItemFormState extends ConsumerState<_EditItemForm> {
  late final TextEditingController _name;
  late final TextEditingController _serial;
  late final TextEditingController _location;
  final _notes = TextEditingController();
  late String _status;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item.name);
    _serial = TextEditingController(text: item.serial ?? '');
    _location = TextEditingController(text: item.location);
    _status = item.status;
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    try {
      final rows = await db
          .from(_tableForKind(widget.item.kind))
          .select('notes')
          .eq('id', widget.item.id)
          .limit(1);
      if (rows.isNotEmpty && mounted) {
        _notes.text = (rows.first['notes'] ?? '').toString();
      }
    } catch (_) {
      // notes stay blank; saving still works
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _serial, _location, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final item = widget.item;
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Name is required.', error: true);
      return;
    }
    final serial = _serial.text.trim();
    final location = _location.text.trim();
    final notes = _notes.text.trim();
    // clearing an existing serial makes the database generate a fresh
    // system number (0012_auto_serials.sql) — say so in the message
    final regenerated =
        serial.isEmpty && (item.serial ?? '').trim().isNotEmpty;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db.from(_tableForKind(item.kind)).update({
        _nameColumnForKind(item.kind): name,
        'status': _status,
        'serial_number': serial.isEmpty ? null : serial,
        if (location.isNotEmpty) 'current_location': location,
        'notes': notes.isEmpty ? null : notes,
      }).eq('id', item.id);
      ref.invalidate(inventoryProvider);
      if (!mounted) return;
      Navigator.pop(context);
      final note = regenerated ? ' — new serial generated' : '';
      messenger.showSnackBar(
          SnackBar(content: Text('${item.code} updated$note.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Edit ${item.code}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(
                        labelText: '${item.kindLabel} name *'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serial,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'Serial number',
                        hintText: 'Empty → new system number (WT-…)'),
                  ),
                  const SizedBox(height: 12),
                  const Text('Status',
                      style: TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    key: ValueKey('edit-status-$_status'),
                    initialValue: _status,
                    items: statusOptions(item.kind)
                        .map((s) =>
                            DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _status = v ?? item.status),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _location,
                    decoration: const InputDecoration(labelText: 'Location'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
                    decoration:
                        const InputDecoration(labelText: 'Notes (optional)'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save changes'),
          ),
        ],
      ),
    );
  }
}

IconData _historyIcon(String type) => switch (type) {
      'Return' => Icons.undo_outlined,
      'Workshop' => Icons.build_outlined,
      'Branch' => Icons.storefront_outlined,
      'Dealer' => Icons.handshake_outlined,
      _ => Icons.person_outline,
    };

/// "Sent to X" / "Sold to X" / "Returned to X".
String _historyTitle(Map<String, dynamic> row) {
  final to = (row['to_location'] ?? '').toString();
  final type = (row['movement_type'] ?? '').toString();
  if (type == 'Return') return 'Returned to $to';
  if ('${row['reason'] ?? ''}'.contains('Sold')) return 'Sold to $to';
  return 'Sent to $to';
}

/// Date · type · Demo · who did it · reference.
String _historyMeta(Map<String, dynamic> row) {
  final actor = row['profiles'];
  final actorName = actor is Map
      ? ((actor['display_name'] ?? actor['username'] ?? '').toString())
      : '';
  final reference = (row['reference'] ?? '').toString();
  return [
    row['movement_date'] ?? '',
    row['movement_type'] ?? '',
    if (row['is_demo'] == true) 'Demo',
    if (actorName.isNotEmpty) 'by $actorName',
    if (reference.isNotEmpty) reference,
  ].join(' · ');
}

// ---------------------------------------------------------------------------
// add form
// ---------------------------------------------------------------------------

class _AddItemForm extends ConsumerStatefulWidget {
  const _AddItemForm();

  @override
  ConsumerState<_AddItemForm> createState() => _AddItemFormState();
}

class _AddItemFormState extends ConsumerState<_AddItemForm> {
  String _kind = 'machine';
  final _product = TextEditingController();
  final _serial = TextEditingController();
  final _code = TextEditingController();
  final _machineCode = TextEditingController();
  InventoryItem? _machine;
  int? _batchId;
  bool _loadingId = true;
  bool _saving = false;
  String _idKey = '';

  @override
  void dispose() {
    for (final c in [_product, _serial, _code, _machineCode]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _needsMachineLink => _kind == 'probe' || _kind == 'printer';

  Future<void> _loadSuggestedId(Map<String, dynamic>? batch) async {
    setState(() => _loadingId = true);
    try {
      final String id;
      if (_needsMachineLink && _machine != null) {
        id = _machine!.code; // probes and printers reuse their machine's id
      } else {
        id = await suggestedId(_kind, letter: batch?['letter']?.toString());
      }
      if (mounted) _code.text = id;
    } catch (_) {
      if (mounted) _code.text = '';
    } finally {
      if (mounted) setState(() => _loadingId = false);
    }
  }

  String _categoryFor(String kind) => switch (kind) {
        'machine' => 'Machine',
        'probe' => 'Probe',
        'printer' => 'Printer',
        _ => 'Part',
      };

  Future<void> _save(Map<String, dynamic>? batch) async {
    final product = _product.text.trim();
    if (product.isEmpty) {
      showSnack(context, 'Model is required.', error: true);
      return;
    }
    if (batch == null) {
      showSnack(context,
          'Create a batch first — Records → Batches → New batch.',
          error: true);
      return;
    }
    if (_code.text.trim().isEmpty) {
      showSnack(context, 'The ID could not be generated.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final productId = await resolveReferenceId(
        table: 'catalog_products',
        name: product,
        payload: {'category': _categoryFor(_kind)},
      );
      final productRows = await db
          .from('catalog_products')
          .select('brand_id')
          .eq('id', productId)
          .limit(1);
      final brandId =
          productRows.isEmpty ? null : productRows.first['brand_id'] as int?;

      final table = switch (_kind) {
        'machine' => 'machines',
        'probe' => 'probes',
        'printer' => 'printers',
        _ => 'parts',
      };
      final idColumn = _kind == 'machine' ? 'machine_id' : 'internal_id';
      final nameColumn =
          _kind == 'machine' || _kind == 'probe' ? 'model' : 'name_model';

      final linked = _needsMachineLink && _machine != null;
      final status =
          linked ? 'With Machine' : defaultStatus(_kind);
      // machines, probes and printers get a system serial from the
      // database when none is typed (0012_auto_serials.sql)
      final wantSerial = _kind != 'part' && _serial.text.trim().isEmpty;

      final payload = <String, dynamic>{
        idColumn: _code.text.trim(),
        nameColumn: product,
        'catalog_product_id': productId,
        'batch_id': batch['id'],
        'status': status,
        'current_location': linked
            ? _machine!.location
            : defaultLocationFor(status),
      };
      if (batch['arrival_date'] != null) {
        payload['acquisition_date'] = batch['arrival_date'];
      }
      if (batch['vendor_id'] != null) payload['vendor_id'] = batch['vendor_id'];
      if (brandId != null) payload['brand_id'] = brandId;
      if (_serial.text.trim().isNotEmpty) {
        payload['serial_number'] = _serial.text.trim();
      }
      if (linked) payload['assigned_machine_id'] = _machine!.id;

      final row = await db
          .from(table)
          .insert(payload)
          .select('serial_number')
          .single();

      ref.invalidate(inventoryProvider);
      if (!mounted) return;
      Navigator.pop(context);
      final serialNote = wantSerial
          ? ' — serial ${row['serial_number']}'
          : '';
      messenger.showSnackBar(SnackBar(
          content: Text('${_code.text.trim()} added$serialNote.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final productNames = ref.watch(productsProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name_model'].toString()).toList(),
          orElse: () => const <String>[],
        );
    final batches = ref.watch(batchesProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final current = ref.watch(currentBatchProvider).maybeWhen(
          data: (row) => row,
          orElse: () => null,
        );
    final batchId = _batchId ?? current?['id'] as int?;
    Map<String, dynamic>? batch;
    for (final row in batches) {
      if (row['id'] == batchId) batch = row;
    }
    final machines = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows
              .where((item) => item.kind == 'machine' && !item.isSold)
              .toList(),
          orElse: () => const <InventoryItem>[],
        );

    // regenerate the id whenever the batch letter, the item type or the
    // linked machine changes
    final idKey = '$_kind|${batch?['letter'] ?? ''}|${_machine?.code ?? ''}';
    if (idKey != _idKey) {
      _idKey = idKey;
      if (!(_kind == 'machine' && batch == null)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadSuggestedId(batch);
        });
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Add product',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Item type',
                      style: TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    key: ValueKey('kind-$_kind'),
                    initialValue: _kind,
                    items: kItemKinds
                        .map((k) => DropdownMenuItem(
                            value: k, child: Text(itemKindLabel(k))))
                        .toList(),
                    onChanged: (value) {
                      final kind = value ?? 'machine';
                      setState(() {
                        _kind = kind;
                        if (kind != 'probe' && kind != 'printer') {
                          _machine = null;
                          _machineCode.clear();
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('Batch',
                      style: TextStyle(fontSize: 13, color: kMuted)),
                  const SizedBox(height: 6),
                  if (batches.isEmpty)
                    AppCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                              'No batch yet. Create one so stock can be entered.',
                              style:
                                  TextStyle(color: kMuted, fontSize: 13.5)),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: () {
                              Navigator.pop(context);
                              showRecordForm(context, 'batch');
                            },
                            child: const Text('Create batch'),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    DropdownButtonFormField<int>(
                      key: ValueKey('batch-$batchId'),
                      initialValue: batchId,
                      items: [
                        for (final row in batches)
                          DropdownMenuItem(
                            value: row['id'] as int,
                            child: Text([
                              if ((row['letter'] ?? '').toString().isNotEmpty)
                                'Batch ${row['letter']}',
                              row['arrival_date'] ?? '',
                            ].join(' · ')),
                          ),
                      ],
                      onChanged: (value) => setState(() => _batchId = value),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      batch == null
                          ? 'Vendor and date are taken from this batch.'
                          : 'Vendor: '
                              '${((batch['vendors'] as Map?)?['name'] ?? '').toString().isEmpty ? '—' : ((batch['vendors'] as Map?)?['name'] ?? '')}  ·  '
                              'Arrived: ${batch['arrival_date'] ?? '—'}',
                      style: const TextStyle(fontSize: 12.5, color: kMuted),
                    ),
                  ],
                  const SizedBox(height: 16),
                  PickyField(
                    controller: _product,
                    label: 'Model *',
                    hint: 'Start typing — suggestions appear',
                    options: productNames,
                    pickTitle: 'models',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serial,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Serial number',
                      hintText: _kind == 'part'
                          ? null
                          : 'Empty → system number (WT-…)',
                    ),
                  ),
                  if (_needsMachineLink) ...[
                    const SizedBox(height: 12),
                    PickyField(
                      controller: _machineCode,
                      label: 'Belongs to machine (optional)',
                      hint: 'e.g. 12T — the id becomes the machine id',
                      options: [
                        for (final item in machines) item.code,
                      ],
                      pickTitle: 'machines',
                      onChanged: (value) {
                        InventoryItem? found;
                        for (final item in machines) {
                          if (item.code.toLowerCase() ==
                              value.trim().toLowerCase()) {
                            found = item;
                          }
                        }
                        if (found?.code != _machine?.code) {
                          setState(() => _machine = found);
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'ID (generated)',
                      hintText: _kind == 'machine'
                          ? 'Needs a batch'
                          : 'Generated automatically',
                      suffixIcon: _loadingId
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : const Icon(Icons.lock_outline, size: 18),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : () => _save(batch),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
