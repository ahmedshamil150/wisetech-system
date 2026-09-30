import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
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
/// they only show up under their own chip.
const _typeFilters = ['Equipment', 'Machine', 'Probe', 'Printer', 'Part'];

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _query = '';
  String _type = 'Equipment';

  bool _matchesFilter(InventoryItem item) => switch (_type) {
        'Equipment' => item.kind != 'part',
        'Machine' => item.kind == 'machine',
        'Probe' => item.kind == 'probe',
        'Printer' => item.kind == 'printer',
        _ => item.kind == 'part',
      };

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final items = ref.watch(inventoryProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SearchField(
            hint: 'Search by code, model or serial',
            onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
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
              final selected = _type == label;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                onSelected: (_) => setState(() => _type = label),
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : kMuted,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                backgroundColor: Colors.white,
                side: const BorderSide(color: Color(0xFFE2E9F0)),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: items.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (rows) {
              final filtered = rows.where((item) {
                if (!_matchesFilter(item)) return false;
                if (_query.isEmpty) return true;
                return item.code.toLowerCase().contains(_query) ||
                    item.name.toLowerCase().contains(_query) ||
                    (item.serial ?? '').toLowerCase().contains(_query);
              }).toList();
              if (filtered.isEmpty) {
                return const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    message: 'No items match this filter.');
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: filtered.length,
                itemBuilder: (context, index) =>
                    _itemTile(context, filtered[index]),
              );
            },
          ),
        ),
        if (isAdmin)
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

  Widget _itemTile(BuildContext context, InventoryItem item) {
    final icon = switch (item.kind) {
      'machine' => Icons.monitor_outlined,
      'probe' => Icons.cable_outlined,
      'printer' => Icons.print_outlined,
      _ => Icons.settings_outlined,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
    final history = ref
        .watch(movementsProvider)
        .maybeWhen(
            data: (rows) => rows, orElse: () => const <Map<String, dynamic>>[])
        .where((row) => row['${item.kind}_id'] == item.id)
        .toList();

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
              KeyValue(label: 'Acquired', value: item.date ?? '—'),
              KeyValue(label: 'Batch', value: item.batch ?? '—'),
            ],
          ),
        ),
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
                    title: Text('${row['to_location'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text([
                      row['movement_date'] ?? '',
                      row['movement_type'] ?? '',
                      if (((row['reference'] ?? '') as String).isNotEmpty)
                        row['reference'],
                    ].join(' · ')),
                  ),
              ],
            ),
          ),
      ],
    );
  }
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

      await db.from(table).insert(payload);

      ref.invalidate(inventoryProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
          SnackBar(content: Text('${_code.text.trim()} added.')));
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
          data: (rows) =>
              rows.where((item) => item.kind == 'machine').toList(),
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
                    decoration:
                        const InputDecoration(labelText: 'Serial number'),
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
