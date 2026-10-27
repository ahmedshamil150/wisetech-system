import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';
import 'old_item_form.dart';
import 'old_sell_sheet.dart';
import 'old_table.dart';

/// The old stock: BATCH-OLD machines, probes and printers plus the shared
/// parts list. Every row is the imported data exactly as it came in, with
/// full read and write for admins.
class OldStockScreen extends ConsumerStatefulWidget {
  const OldStockScreen({super.key});

  @override
  ConsumerState<OldStockScreen> createState() => _OldStockScreenState();
}

class _OldStockScreenState extends ConsumerState<OldStockScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 4, vsync: this);
  String _query = '';
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      setState(() {
        _page = 0;
      });
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tab,
            isScrollable: true,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700),
            tabs: const [
              Tab(text: 'Machines'),
              Tab(text: 'Probes'),
              Tab(text: 'Printers'),
              Tab(text: 'Parts'),
            ],
          ),
        ),
        oldSearchField(context,
            hint: 'Search old stock',
            onChanged: (value) => setState(() {
                  _query = value.trim();
                  _page = 0;
                })),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _MachinesPane(search: _query, page: _page, onPage: (p) =>
                  setState(() => _page = p)),
              _ProbesPane(search: _query, page: _page, onPage: (p) =>
                  setState(() => _page = p)),
              _PrintersPane(search: _query, page: _page, onPage: (p) =>
                  setState(() => _page = p)),
              _PartsPane(search: _query, page: _page, onPage: (p) =>
                  setState(() => _page = p)),
            ],
          ),
        ),
        if (isAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              onPressed: () => _pickKind(context),
              icon: const Icon(Icons.add),
              label: const Text('Add to old stock'),
            ),
          ),
      ],
    );
  }

  /// Asks which kind of item to add, then opens the form for it.
  void _pickKind(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Add to old stock',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            for (final (kind, label, icon) in const [
              ('machine', 'Machine', Icons.computer_outlined),
              ('probe', 'Probe', Icons.cable_outlined),
              ('printer', 'Printer', Icons.print_outlined),
              ('part', 'Part', Icons.settings_outlined),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () {
                  Navigator.pop(sheetContext);
                  showOldItemForm(context, kind: kind);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// A single old-stock row: code, model, serial, status chip, location.
/// Admins get a sell button on the row itself (hidden once the item is
/// Sold); tapping the row still opens the edit form.
Widget _oldItemTile(BuildContext context, Map<String, dynamic> row,
    {required String code,
    required String name,
    VoidCallback? onTap,
    VoidCallback? onSell}) {
  final serial = (row['serial_number'] ?? '').toString();
  final status = (row['status'] ?? '').toString();
  final location = (row['current_location'] ?? '').toString();
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: AppCard(
      onTap: onTap,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(code.isEmpty ? '?' : code.characters.first.toUpperCase(),
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onPrimaryContainer)),
        ),
        title: Text(
            code.isEmpty ? (serial.isEmpty ? name : serial) : code,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (name.isNotEmpty && code.isNotEmpty) Text(name),
            const SizedBox(height: 4),
            Row(
              children: [
                StatusChip(status: status),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [if (serial.isNotEmpty) serial, location]
                        .where((s) => s.isNotEmpty)
                        .join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: onSell == null
            ? const Icon(Icons.chevron_right, size: 20)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Sell',
                    visualDensity: VisualDensity.compact,
                    onPressed: onSell,
                    icon: const Icon(Icons.sell_outlined, size: 20),
                  ),
                  const Icon(Icons.chevron_right, size: 20),
                ],
              ),
      ),
    ),
  );
}

class _MachinesPane extends ConsumerWidget {
  const _MachinesPane(
      {required this.search, required this.page, required this.onPage});
  final String search;
  final int page;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    final data = ref.watch(oldMachinesProvider(
        (page: page, search: search, status: 'All')));
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (result) => OldTable(
        rows: result.rows,
        total: result.total,
        page: page,
        onPageChanged: onPage,
        emptyMessage: 'No old machines match this search.',
        rowBuilder: (row) => _oldItemTile(context, row,
            code: (row['machine_id'] ?? '').toString(),
            name: (row['model'] ?? '').toString(),
            onTap: () => showOldItemForm(context, kind: 'machine', row: row),
            onSell: isAdmin && row['status'] != 'Sold'
                ? () => showOldSellSheet(context, kind: 'machine', row: row)
                : null),
      ),
    );
  }
}

class _ProbesPane extends ConsumerWidget {
  const _ProbesPane(
      {required this.search, required this.page, required this.onPage});
  final String search;
  final int page;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    final data = ref
        .watch(oldProbesProvider((page: page, search: search, status: 'All')));
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (result) => OldTable(
        rows: result.rows,
        total: result.total,
        page: page,
        onPageChanged: onPage,
        emptyMessage: 'No old probes match this search.',
        rowBuilder: (row) => _oldItemTile(context, row,
            code: (row['internal_id'] ?? '').toString(),
            name: (row['model'] ?? '').toString(),
            onTap: () => showOldItemForm(context, kind: 'probe', row: row),
            onSell: isAdmin && row['status'] != 'Sold'
                ? () => showOldSellSheet(context, kind: 'probe', row: row)
                : null),
      ),
    );
  }
}

class _PrintersPane extends ConsumerWidget {
  const _PrintersPane(
      {required this.search, required this.page, required this.onPage});
  final String search;
  final int page;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    final data = ref.watch(oldPrintersProvider(
        (page: page, search: search, status: 'All')));
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (result) => OldTable(
        rows: result.rows,
        total: result.total,
        page: page,
        onPageChanged: onPage,
        emptyMessage: 'No old printers match this search.',
        rowBuilder: (row) => _oldItemTile(context, row,
            code: (row['internal_id'] ?? '').toString(),
            name: (row['name_model'] ?? '').toString(),
            onTap: () => showOldItemForm(context, kind: 'printer', row: row),
            onSell: isAdmin && row['status'] != 'Sold'
                ? () => showOldSellSheet(context, kind: 'printer', row: row)
                : null),
      ),
    );
  }
}

/// Parts are shared between both sides; this pane reuses the regular
/// inventory provider filtered to parts so counts stay consistent.
class _PartsPane extends ConsumerWidget {
  const _PartsPane(
      {required this.search, required this.page, required this.onPage});
  final String search;
  final int page;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider);
    final all = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows.where((i) => i.kind == 'part').toList(),
          orElse: () => const <InventoryItem>[],
        );
    final term = search.toLowerCase();
    final filtered = term.isEmpty
        ? all
        : all
            .where((i) =>
                i.code.toLowerCase().contains(term) ||
                i.name.toLowerCase().contains(term) ||
                (i.serial ?? '').toLowerCase().contains(term))
            .toList();
    final start = page * 50;
    final slice = start >= filtered.length
        ? const <InventoryItem>[]
        : filtered.skip(start).take(50).toList();
    if (filtered.isEmpty) {
      return const EmptyState(
          icon: Icons.inbox_outlined, message: 'No parts match this search.');
    }
    return OldTable(
      rows: [
        for (final item in slice)
          {
            'id': item.id,
            'code': item.code,
            'name': item.name,
            'serial': item.serial ?? '',
            'status': item.status,
            'location': item.location,
          }
      ],
      total: filtered.length,
      page: page,
      onPageChanged: onPage,
      emptyMessage: 'No parts match this search.',
      rowBuilder: (row) => _oldItemTile(context, row,
          code: (row['code'] ?? '').toString(),
          name: (row['name'] ?? '').toString(),
          onTap: () => _openPart(context, row['id'] as int),
          onSell: isAdmin && row['status'] != 'Sold'
              ? () => showOldSellSheet(context, kind: 'part', row: row)
              : null),
    );
  }

  /// The parts list only carries display fields, so pull the full row
  /// before opening the form — otherwise saving would blank out notes.
  Future<void> _openPart(BuildContext context, int id) async {
    final rows = await db
        .from('parts')
        .select(
            'id, internal_id, name_model, serial_number, status, current_location, notes')
        .eq('id', id)
        .limit(1);
    if (!context.mounted || rows.isEmpty) return;
    await showOldItemForm(context, kind: 'part', row: rows.first);
  }
}
