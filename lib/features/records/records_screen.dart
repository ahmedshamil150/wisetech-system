import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart';

/// Reference data: products, brands, customers, dealers and batches.
/// Admins can add records here; viewers can only read them.
class RecordsScreen extends ConsumerStatefulWidget {
  const RecordsScreen({super.key});

  @override
  ConsumerState<RecordsScreen> createState() => _RecordsScreenState();
}

const _sections = ['product', 'brand', 'customer', 'dealer', 'batch', 'box'];
const _addLabels = [
  'Add product',
  'Add brand',
  'Add customer',
  'Add dealer',
  'New batch',
  'New box',
];

class _RecordsScreenState extends ConsumerState<RecordsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 6, vsync: this);
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tab.addListener(_sync);
  }

  void _sync() => setState(() {});

  @override
  void dispose() {
    _tab.removeListener(_sync);
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    return Column(
      children: [
        Material(
          color: Colors.white,
          child: TabBar(
            controller: _tab,
            isScrollable: true,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700),
            tabs: const [
              Tab(text: 'Products'),
              Tab(text: 'Brands'),
              Tab(text: 'Customers'),
              Tab(text: 'Dealers'),
              Tab(text: 'Batches'),
              Tab(text: 'Boxes'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SearchField(
            hint: 'Search records',
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: AppRefresh(
            child: TabBarView(
              controller: _tab,
              children: [
                _ProductsPane(query: _query),
                _BrandsPane(query: _query),
                _PeoplePane(table: 'customers', query: _query),
                _PeoplePane(table: 'dealers', query: _query),
                _BatchesPane(query: _query),
                _BoxesPane(query: _query),
              ],
            ),
          ),
        ),
        if (isAdmin)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.icon(
              onPressed: () => showRecordForm(context, _sections[_tab.index]),
              icon: const Icon(Icons.add),
              label: Text(_addLabels[_tab.index]),
            ),
          ),
      ],
    );
  }
}

Future<void> showRecordForm(BuildContext context, String kind,
    {Map<String, dynamic>? editRow}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: kind == 'batch'
          ? _BatchForm(editRow: editRow)
          : kind == 'box'
              ? _BoxForm(editRow: editRow)
              : _RecordForm(kind: kind, editRow: editRow),
    ),
  );
}

// ---------------------------------------------------------------------------
// list panes
// ---------------------------------------------------------------------------

class _ProductsPane extends ConsumerWidget {
  const _ProductsPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(productsProvider);
    final isAdmin = ref.watch(isAdminProvider);
    return products.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final filtered = rows.where((row) {
          if (query.isEmpty) return true;
          final name = (row['name_model'] ?? '').toString().toLowerCase();
          final brand =
              ((row['brands'] as Map?)?['name'] ?? '').toString().toLowerCase();
          return name.contains(query) || brand.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.inventory_2_outlined, message: 'No products found.');
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) =>
              _productTile(context, ref, filtered[index], isAdmin: isAdmin),
        );
      },
    );
  }

  Widget _productTile(BuildContext context, WidgetRef ref,
      Map<String, dynamic> row,
      {required bool isAdmin}) {
    final category = (row['category'] ?? 'Other').toString();
    final brand = ((row['brands'] as Map?)?['name'] ?? '').toString();
    final probeType = (row['probe_type'] ?? '').toString();
    final icon = switch (category) {
      'Machine' => Icons.monitor_outlined,
      'Probe' => Icons.cable_outlined,
      'Printer' => Icons.print_outlined,
      'Part' => Icons.settings_outlined,
      _ => Icons.category_outlined,
    };
    void openEdit() => showRecordForm(context, 'product', editRow: row);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          onTap: isAdmin ? openEdit : null,
          leading: CircleAvatar(
            backgroundColor: const Color(0xFFEAF3F8),
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
          title: Text((row['name_model'] ?? '').toString(),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text([
            category,
            if (brand.isNotEmpty) brand,
            if (probeType.isNotEmpty) probeType,
          ].join(' · ')),
          trailing: isAdmin
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit product',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: openEdit,
                    ),
                    IconButton(
                      tooltip: 'Delete product',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _confirmDelete(context, ref, row),
                    ),
                  ],
                )
              : null,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Map<String, dynamic> row) async {
    final name = (row['name_model'] ?? '').toString();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
            'It disappears from the product list. Items already using '
            'it keep their model name.'),
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
    if (confirmed != true) return;
    try {
      await db.from('catalog_products').delete().eq('id', row['id'] as int);
      ref.invalidate(productsProvider);
      messenger.showSnackBar(SnackBar(content: Text('$name deleted.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }
}

class _BrandsPane extends ConsumerWidget {
  const _BrandsPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brands = ref.watch(brandsProvider);
    final isAdmin = ref.watch(isAdminProvider);
    return brands.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final filtered = rows
            .where((row) =>
                query.isEmpty ||
                (row['name'] ?? '').toString().toLowerCase().contains(query))
            .toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.branding_watermark_outlined,
              message: 'No brands found.');
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final note = (row['notes'] ?? '').toString();
            void openEdit() => showRecordForm(context, 'brand', editRow: row);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  onTap: isAdmin ? openEdit : null,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEAF3F8),
                    child: Icon(Icons.branding_watermark_outlined),
                  ),
                  title: Text((row['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: note.isEmpty ? null : Text(note),
                  trailing: isAdmin
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit brand',
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: openEdit,
                            ),
                            IconButton(
                              tooltip: 'Delete brand',
                              icon:
                                  const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _confirmDelete(context, ref, row),
                            ),
                          ],
                        )
                      : null,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Map<String, dynamic> row) async {
    final name = (row['name'] ?? '').toString();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text(
            'It disappears from the brand list. Products already using it '
            'must pick another brand first.'),
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
    if (confirmed != true) return;
    try {
      await db.from('brands').delete().eq('id', row['id'] as int);
      ref
        ..invalidate(brandsProvider)
        ..invalidate(productsProvider);
      messenger.showSnackBar(SnackBar(content: Text('$name deleted.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }
}

class _PeoplePane extends ConsumerWidget {
  const _PeoplePane({required this.table, required this.query});

  final String table; // customers | dealers
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = table == 'customers' ? customersProvider : dealersProvider;
    final rows = ref.watch(provider);
    final isAdmin = ref.watch(isAdminProvider);
    final kind = table == 'customers' ? 'customer' : 'dealer';
    return rows.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (records) {
        final filtered = records.where((row) {
          if (query.isEmpty) return true;
          final name = (row['name'] ?? '').toString().toLowerCase();
          final city = (row['city'] ?? '').toString().toLowerCase();
          final phone = (row['phone'] ?? '').toString().toLowerCase();
          return name.contains(query) ||
              city.contains(query) ||
              phone.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return EmptyState(
            icon: table == 'customers'
                ? Icons.people_outline
                : Icons.handshake_outlined,
            message: 'No $table found.',
          );
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final parts = [
              if ((row['phone'] ?? '').toString().isNotEmpty)
                row['phone'].toString(),
              if ((row['city'] ?? '').toString().isNotEmpty)
                row['city'].toString(),
              if ((row['address'] ?? '').toString().isNotEmpty)
                row['address'].toString(),
            ];
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  onTap: isAdmin
                      ? () => showRecordForm(context, kind, editRow: row)
                      : null,
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEAF3F8),
                    child: Icon(
                      table == 'customers'
                          ? Icons.person_outline
                          : Icons.handshake_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  title: Text((row['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle:
                      parts.isEmpty ? null : Text(parts.join(' · ')),
                  trailing: isAdmin
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit $kind',
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () =>
                                  showRecordForm(context, kind, editRow: row),
                            ),
                            IconButton(
                              tooltip: 'Delete $kind',
                              icon:
                                  const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _confirmDelete(context, ref, row),
                            ),
                          ],
                        )
                      : null,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Map<String, dynamic> row) async {
    final name = (row['name'] ?? '').toString();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $name?'),
        content: Text(
            'It disappears from the $table list. Movements or sales that '
            'still point at it will keep the app from deleting it.'),
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
    if (confirmed != true) return;
    try {
      await db.from(table).delete().eq('id', row['id'] as int);
      ref.invalidate(
          table == 'customers' ? customersProvider : dealersProvider);
      messenger.showSnackBar(SnackBar(content: Text('$name deleted.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }
}

// ---------------------------------------------------------------------------
// batches
// ---------------------------------------------------------------------------

class _BatchesPane extends ConsumerWidget {
  const _BatchesPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batches = ref.watch(batchesProvider);
    final current = ref.watch(currentBatchProvider);
    final isAdmin = ref.watch(isAdminProvider);

    return batches.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) =>
          EmptyState(icon: Icons.error_outline, message: errorMessage(error)),
      data: (rows) {
        final currentId = current.maybeWhen(
          data: (row) => row?['id'],
          orElse: () => null,
        );
        final filtered = rows.where((row) {
          if (query.isEmpty) return true;
          final letter = (row['letter'] ?? '').toString().toLowerCase();
          final code = (row['code'] ?? '').toString().toLowerCase();
          final vendor = ((row['vendors'] as Map?)?['name'] ?? '')
              .toString()
              .toLowerCase();
          final date = (row['arrival_date'] ?? '').toString().toLowerCase();
          return letter.contains(query) ||
              code.contains(query) ||
              vendor.contains(query) ||
              date.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.inventory_outlined,
              message: 'No batches yet. Create one so you can enter stock.');
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final letter = (row['letter'] ?? '?').toString();
            final vendor = ((row['vendors'] as Map?)?['name'] ?? '')
                .toString();
            final isCurrent = row['id'] == currentId;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  onTap: isAdmin
                      ? () => showRecordForm(context, 'batch', editRow: row)
                      : null,
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFEAF3F8),
                    child: Text(letter,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w800)),
                  ),
                  title: Text('Batch $letter',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([
                    row['arrival_date'] ?? '',
                    if (vendor.isNotEmpty) vendor,
                    (row['code'] ?? '').toString(),
                  ].join(' · ')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isCurrent)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('New stock',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                      if (isAdmin) ...[
                        IconButton(
                          tooltip: 'Edit batch',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () =>
                              showRecordForm(context, 'batch', editRow: row),
                        ),
                        IconButton(
                          tooltip: 'Delete batch',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _confirmDelete(context, ref, row),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Map<String, dynamic> row) async {
    final letter = (row['letter'] ?? '?').toString();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete batch $letter?'),
        content: const Text(
            'It disappears from the list. Machines that still belong to it '
            'must be moved or deleted first.'),
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
    if (confirmed != true) return;
    try {
      await db.from('batches').delete().eq('id', row['id'] as int);
      ref.invalidate(batchesProvider);
      messenger
          .showSnackBar(SnackBar(content: Text('Batch $letter deleted.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }
}

// ---------------------------------------------------------------------------
// probe boxes (where the leftover probes are kept)
// ---------------------------------------------------------------------------

class _BoxesPane extends ConsumerWidget {
  const _BoxesPane({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boxes = ref.watch(probeBoxesProvider);
    final isAdmin = ref.watch(isAdminProvider);
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
          if (query.isEmpty) return true;
          final name = (row['name'] ?? '').toString().toLowerCase();
          final type = (row['probe_type'] ?? '').toString().toLowerCase();
          return name.contains(query) || type.contains(query);
        }).toList();
        if (filtered.isEmpty) {
          return const EmptyState(
              icon: Icons.inbox_outlined,
              message: 'No boxes yet. Make one for each probe type.');
        }
        return ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final row = filtered[index];
            final count = items
                .where(
                    (item) => item.kind == 'probe' && item.boxId == row['id'])
                .length;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFEAF3F8),
                    child: Icon(Icons.inbox_outlined),
                  ),
                  title: Text((row['name'] ?? '').toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${row['probe_type']} · $count probes'),
                  trailing: isAdmin
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Edit box',
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () =>
                                  showRecordForm(context, 'box', editRow: row),
                            ),
                            IconButton(
                              tooltip: 'Delete box',
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _confirmDelete(context, ref, row),
                            ),
                          ],
                        )
                      : const Icon(Icons.chevron_right, size: 20),
                  onTap: () => showBoxSheet(context, ref, row),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Map<String, dynamic> box) async {
    final items = ref.read(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    final count = items
        .where((item) => item.kind == 'probe' && item.boxId == box['id'])
        .length;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${box['name']}?'),
        content: Text(count == 0
            ? 'The box will be removed.'
            : 'The $count probe(s) inside go back to company stock.'),
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
    if (confirmed != true) return;
    try {
      await deleteProbeBox(box);
      ref
        ..invalidate(probeBoxesProvider)
        ..invalidate(inventoryProvider);
      messenger.showSnackBar(
          SnackBar(content: Text('${box['name']} deleted.')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(error))));
    }
  }
}

class _BatchForm extends ConsumerStatefulWidget {
  const _BatchForm({this.editRow});

  /// Existing batch to edit; null means "add new".
  final Map<String, dynamic>? editRow;

  @override
  ConsumerState<_BatchForm> createState() => _BatchFormState();
}

class _BatchFormState extends ConsumerState<_BatchForm> {
  final _letter = TextEditingController();
  final _vendor = TextEditingController();
  final _date = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;
  bool _loadingLetter = true;

  @override
  void initState() {
    super.initState();
    final row = widget.editRow;
    if (row != null) {
      _letter.text = (row['letter'] ?? '').toString();
      _vendor.text = ((row['vendors'] as Map?)?['name'] ?? '').toString();
      _date.text = (row['arrival_date'] ?? '').toString();
      _notes.text = (row['notes'] ?? '').toString();
      _loadingLetter = false;
    } else {
      _date.text = DateField.format(DateTime.now());
      _loadLetter();
    }
  }

  @override
  void dispose() {
    for (final c in [_letter, _vendor, _date, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLetter() async {
    try {
      final letter = await suggestedBatchLetter();
      if (mounted) _letter.text = letter;
    } catch (_) {
      if (mounted) _letter.text = 'U';
    } finally {
      if (mounted) setState(() => _loadingLetter = false);
    }
  }

  Future<void> _save() async {
    final letter = _letter.text.trim().toUpperCase();
    if (letter.length != 1 || !RegExp(r'^[A-Z]$').hasMatch(letter)) {
      showSnack(context, 'The batch letter must be a single letter (U).',
          error: true);
      return;
    }
    if (_vendor.text.trim().isEmpty) {
      showSnack(context, 'Vendor is required.', error: true);
      return;
    }
    if (_date.text.trim().isEmpty) {
      showSnack(context, 'Arrival date is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final vendorId = await resolveReferenceId(
          table: 'vendors', name: _vendor.text.trim());
      final editId = widget.editRow?['id'];
      if (editId != null) {
        await db.from('batches').update({
          'code': 'BATCH-$letter',
          'letter': letter,
          'arrival_date': _date.text.trim(),
          'vendor_id': vendorId,
          'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        }).eq('id', editId as int);
        ref.invalidate(batchesProvider);
        if (!mounted) return;
        Navigator.pop(context);
        messenger
            .showSnackBar(SnackBar(content: Text('Batch $letter saved.')));
        return;
      }
      final row = await db
          .from('batches')
          .insert({
            'code': 'BATCH-$letter',
            'letter': letter,
            'arrival_date': _date.text.trim(),
            'vendor_id': vendorId,
            if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
          })
          .select('id')
          .single();
      await setCurrentBatch(row['id'] as int);
      ref
        ..invalidate(batchesProvider)
        ..invalidate(currentBatchProvider)
        ..invalidate(vendorsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text(
              'Batch $letter created — new stock goes into it.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vendorNames = ref.watch(vendorsProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    widget.editRow != null ? 'Edit batch' : 'New batch',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
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
                  TextField(
                    controller: _letter,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 1,
                    decoration: InputDecoration(
                      labelText: 'Batch letter',
                      hintText: 'U',
                      counterText: '',
                      suffixIcon: _loadingLetter
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  PickyField(
                    controller: _vendor,
                    label: 'Vendor *',
                    hint: 'Search vendors',
                    options: vendorNames,
                    pickTitle: 'vendors',
                  ),
                  const SizedBox(height: 12),
                  DateField(controller: _date, label: 'Arrival date *'),
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
                : Text(widget.editRow != null ? 'Save batch' : 'Create batch'),
          ),
        ],
      ),
    );
  }
}

class _BoxForm extends ConsumerStatefulWidget {
  const _BoxForm({this.editRow});

  /// Existing box to edit; null means "add new".
  final Map<String, dynamic>? editRow;

  @override
  ConsumerState<_BoxForm> createState() => _BoxFormState();
}

class _BoxFormState extends ConsumerState<_BoxForm> {
  final _name = TextEditingController();
  final _type = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.editRow;
    if (row != null) {
      _name.text = (row['name'] ?? '').toString();
      _type.text = (row['probe_type'] ?? '').toString();
      _notes.text = (row['notes'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _type, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final type = _type.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Box name is required.', error: true);
      return;
    }
    if (type.isEmpty) {
      showSnack(context, 'Choose the probe type this box holds.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final editId = widget.editRow?['id'];
      if (editId != null) {
        await db.from('probe_boxes').update({
          'name': name,
          'probe_type': type,
          'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        }).eq('id', editId as int);
        ref.invalidate(probeBoxesProvider);
        if (!mounted) return;
        Navigator.pop(context);
        messenger.showSnackBar(SnackBar(content: Text('$name saved.')));
        return;
      }
      await db.from('probe_boxes').insert({
        'name': name,
        'probe_type': type,
        if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      });
      ref.invalidate(probeBoxesProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
          SnackBar(content: Text('$name added for $type probes.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeNames = ref.watch(productsProvider).maybeWhen(
          data: (rows) => rows
              .map((row) => (row['probe_type'] ?? '').toString())
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort(),
          orElse: () => const <String>[],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    widget.editRow != null ? 'Edit box' : 'New box',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
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
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                        labelText: 'Box name *', hintText: 'Box 1'),
                  ),
                  const SizedBox(height: 12),
                  PickyField(
                    controller: _type,
                    label: 'Probe type *',
                    hint: 'Convex, Linear, Phased Array…',
                    options: typeNames,
                    pickTitle: 'probe types',
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
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// add form
// ---------------------------------------------------------------------------

class _RecordForm extends ConsumerStatefulWidget {
  const _RecordForm({required this.kind, this.editRow});

  final String kind; // product | brand | customer | dealer

  /// Existing row to edit; null means "add new".
  final Map<String, dynamic>? editRow;

  @override
  ConsumerState<_RecordForm> createState() => _RecordFormState();
}

class _RecordFormState extends ConsumerState<_RecordForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  final _address = TextEditingController();
  final _brand = TextEditingController();
  final _probeType = TextEditingController();
  final _notes = TextEditingController();
  String _category = 'Machine';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.editRow;
    if (row == null) return;
    if (widget.kind == 'product') {
      _name.text = (row['name_model'] ?? '').toString();
      _category = (row['category'] ?? 'Machine').toString();
      _brand.text = ((row['brands'] as Map?)?['name'] ?? '').toString();
      _probeType.text = (row['probe_type'] ?? '').toString();
    } else if (widget.kind == 'brand') {
      _name.text = (row['name'] ?? '').toString();
      _notes.text = (row['notes'] ?? '').toString();
    } else {
      _name.text = (row['name'] ?? '').toString();
      _phone.text = (row['phone'] ?? '').toString();
      _city.text = (row['city'] ?? '').toString();
      _address.text = (row['address'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _city, _address, _brand, _probeType, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _title {
    if (widget.editRow != null) return 'Edit ${widget.kind}';
    return switch (widget.kind) {
      'product' => 'Add product',
      'brand' => 'Add brand',
      'customer' => 'Add customer',
      _ => 'Add dealer',
    };
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Name is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final editId = widget.editRow?['id'] as int?;
      final notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();
      switch (widget.kind) {
        case 'brand':
          final payload = {'name': name, 'notes': notes};
          if (editId != null) {
            await db.from('brands').update(payload).eq('id', editId);
          } else {
            await db.from('brands').insert({
              'name': name,
              'notes': notes,
            });
          }
          ref
            ..invalidate(brandsProvider)
            ..invalidate(productsProvider);
        case 'product':
          int? brandId;
          if (_brand.text.trim().isNotEmpty) {
            brandId = await resolveReferenceId(
                table: 'brands', name: _brand.text.trim());
          }
          final payload = <String, dynamic>{
            'name_model': name,
            'category': _category,
            'brand_id': brandId,
            'probe_type': _category == 'Probe' &&
                    _probeType.text.trim().isNotEmpty
                ? _probeType.text.trim()
                : null,
          };
          if (editId != null) {
            await db.from('catalog_products').update(payload).eq('id', editId);
          } else {
            await db.from('catalog_products').insert(payload);
          }
          ref
            ..invalidate(productsProvider)
            ..invalidate(brandsProvider);
        case 'customer':
          final payload = {
            'name': name,
            'phone': _phone.text.trim(),
            'city': _city.text.trim(),
            'address': _address.text.trim(),
          };
          if (editId != null) {
            await db.from('customers').update(payload).eq('id', editId);
          } else {
            await db.from('customers')
                .insert({'customer_type': 'Customer', ...payload});
          }
          ref
            ..invalidate(customersProvider)
            ..invalidate(recentPartiesProvider);
        default:
          final payload = {
            'name': name,
            'phone': _phone.text.trim(),
            'city': _city.text.trim(),
            'address': _address.text.trim(),
          };
          if (editId != null) {
            await db.from('dealers').update(payload).eq('id', editId);
          } else {
            await db.from('dealers').insert(payload);
          }
          ref
            ..invalidate(dealersProvider)
            ..invalidate(recentPartiesProvider);
      }
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text(widget.editRow != null ? '$name saved.' : '$name added.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brandNames = ref.watch(brandsProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_title,
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
                  if (widget.kind == 'product') ...[
                    PickyField(
                      controller: _name,
                      label: 'Product name *',
                      hint: 'e.g. LOGIQ P6',
                      options: ref.watch(productsProvider).maybeWhen(
                            data: (rows) => rows
                                .map((r) => r['name_model'].toString())
                                .toList(),
                            orElse: () => const <String>[],
                          ),
                      pickTitle: 'products',
                    ),
                    const SizedBox(height: 12),
                    const Text('Category',
                        style: TextStyle(fontSize: 13, color: kMuted)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      key: ValueKey('category-$_category'),
                      initialValue: _category,
                      items: const [
                        'Machine',
                        'Probe',
                        'Printer',
                        'Accessory',
                        'Part',
                        'Other',
                      ]
                          .map((c) =>
                              DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _category = v ?? 'Machine'),
                    ),
                    const SizedBox(height: 12),
                    PickyField(
                      controller: _brand,
                      label: 'Brand',
                      hint: 'Start typing or search',
                      options: brandNames,
                      pickTitle: 'brands',
                    ),
                    if (_category == 'Probe') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _probeType,
                        decoration: const InputDecoration(
                          labelText: 'Probe type',
                          hintText: 'Convex, Linear, Phased Array…',
                        ),
                      ),
                    ],
                  ] else if (widget.kind == 'brand') ...[
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                          labelText: 'Brand name *'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _notes,
                      maxLines: 2,
                      decoration:
                          const InputDecoration(labelText: 'Notes (optional)'),
                    ),
                  ] else ...[
                    TextField(
                      controller: _name,
                      decoration:
                          InputDecoration(labelText: '${_title.split(' ').last} name *'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      decoration:
                          const InputDecoration(labelText: 'Phone'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _city,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _address,
                      decoration:
                          const InputDecoration(labelText: 'Address'),
                    ),
                  ],
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
                : Text('Save'),
          ),
        ],
      ),
    );
  }
}
