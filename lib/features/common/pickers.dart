import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/data.dart';
import 'widgets.dart';
import '../../core/layout.dart';

/// Relevance score for a search query; lower is better.
/// -1 = no match.
int _scoreMatch(InventoryItem item, String q) {
  final code = item.code.toLowerCase();
  if (code == q) return 0;
  if (code.startsWith(q)) return 1;
  if (code.contains(q)) return 2;
  final name = item.name.toLowerCase();
  if (name == q) return 3;
  if (name.startsWith(q)) return 4;
  if (name.contains(q)) return 5;
  final serial = (item.serial ?? '').toLowerCase();
  if (serial == q) return 6;
  if (serial.startsWith(q)) return 7;
  if (serial.contains(q)) return 8;
  return -1;
}

const _kindRank = {'machine': 0, 'printer': 1, 'probe': 2, 'part': 3};

/// Amber pill marking an item that came from the old-data import, so a
/// picker row makes the two sides obvious at a glance.
class _OldDataBadge extends StatelessWidget {
  const _OldDataBadge();

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF9A5A00);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'old data',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// Full-height sheet listing inventory items with a search box.
/// Returns the chosen item, or null when cancelled.
///
/// With [allowCreate], a search that matches nothing offers to add the
/// typed serial as a new item instead — old stock included, since the
/// batch chosen in the form decides the side.
Future<InventoryItem?> showPickItem(
  BuildContext context, {
  required List<InventoryItem> items,
  String? selectedKey,
  bool allowCreate = false,
}) {
  return showAppSheet<InventoryItem>(
    context: context,
    title: 'Pick an item',
    heightFraction: 0.75,
    builder: (sheetContext) {
      var query = '';
      var adding = false;
      return StatefulBuilder(
        builder: (context, setState) {
          final q = query.trim().toLowerCase();
          List<InventoryItem> matches;
          if (q.isEmpty) {
            matches = items;
          } else {
            final scored = <(int, int, InventoryItem)>[];
            for (var i = 0; i < items.length; i++) {
              final s = _scoreMatch(items[i], q);
              if (s >= 0) scored.add((s, i, items[i]));
            }
            scored.sort((a, b) {
              if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
              final ka = _kindRank[a.$3.kind] ?? 4;
              final kb = _kindRank[b.$3.kind] ?? 4;
              if (ka != kb) return ka.compareTo(kb);
              return a.$2.compareTo(b.$2);
            });
            matches = [for (final t in scored) t.$3];
          }
          final hasSerial = items.any(
            (item) => (item.serial ?? '').toLowerCase() == q,
          );
          final canAdd = allowCreate && q.length >= 3 && !hasSerial;
          final screen = MediaQuery.of(context).size.height;
          final inset = MediaQuery.of(sheetContext).viewInsets.bottom;
          final height = (screen * 0.8 - inset).clamp(
            screen * 0.45,
            screen * 0.9,
          );
          return Padding(
            padding: EdgeInsets.only(bottom: inset),
            child: SizedBox(
              height: height,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Choose an item',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                  if (!adding) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SearchField(
                        hint:
                            'Search ${items.length} items by code, model or serial',
                        onChanged: (value) => setState(() => query = value),
                      ),
                    ),
                    if (canAdd)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                        child: OutlinedButton.icon(
                          onPressed: () => setState(() => adding = true),
                          icon: const Icon(Icons.add_circle_outline, size: 18),
                          label: Text('Add “${query.trim()}” as a new item'),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: adding
                        ? _NewItemForm(
                            serial: query.trim(),
                            onCancel: () => setState(() => adding = false),
                            onCreated: (item) =>
                                Navigator.pop(sheetContext, item),
                          )
                        : matches.isEmpty
                        ? const EmptyState(
                            icon: Icons.search_off,
                            message: 'Nothing matches that search.',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            itemCount: matches.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = matches[index];
                              final isSelected = item.key == selectedKey;
                              return ListTile(
                                dense: true,
                                leading: Text(
                                  item.kindLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        '${item.code}  ${item.title}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    if (item.batch == 'BATCH-OLD') ...[
                                      const SizedBox(width: 6),
                                      const _OldDataBadge(),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  '${item.status} · ${item.location}',
                                ),
                                trailing: isSelected
                                    ? Icon(
                                        Icons.check,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      )
                                    : null,
                                onTap: () => Navigator.pop(sheetContext, item),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Adds a serial that is not in the inventory at all. The batch decides
/// the side (BATCH-OLD or a new-stock batch), the type decides the table.
/// The created item is returned to the picker's caller so the movement
/// records it straight away.
class _NewItemForm extends ConsumerStatefulWidget {
  const _NewItemForm({
    required this.serial,
    required this.onCancel,
    required this.onCreated,
  });

  final String serial;
  final VoidCallback onCancel;
  final ValueChanged<InventoryItem> onCreated;

  @override
  ConsumerState<_NewItemForm> createState() => _NewItemFormState();
}

class _NewItemFormState extends ConsumerState<_NewItemForm> {
  static const _kinds = ['machine', 'probe', 'printer', 'part'];
  static const _categories = {
    'machine': 'Machine',
    'probe': 'Probe',
    'printer': 'Printer',
    'part': 'Part',
  };

  late final TextEditingController _serial;
  final _model = TextEditingController();
  String? _kind;
  int? _batchId;
  List<Map<String, dynamic>> _batches = const [];
  bool _loadingBatches = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _serial = TextEditingController(text: widget.serial);
    _loadBatches();
  }

  Future<void> _loadBatches() async {
    try {
      final rows = await db
          .from('batches')
          .select('id, code, letter, arrival_date, vendor_id')
          .order('id');
      if (!mounted) return;
      setState(() {
        _batches = rows;
        _loadingBatches = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingBatches = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_serial, _model]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? get _batch {
    for (final row in _batches) {
      if (row['id'] == _batchId) return row;
    }
    return null;
  }

  Future<void> _create() async {
    final kind = _kind;
    final batch = _batch;
    final serial = _serial.text.trim();
    final model = _model.text.trim();
    if (kind == null) {
      showSnack(context, 'Pick the item type.', error: true);
      return;
    }
    if (batch == null) {
      showSnack(context, 'Pick the batch it belongs to.', error: true);
      return;
    }
    if (model.isEmpty) {
      showSnack(context, 'Model is required.', error: true);
      return;
    }
    if (serial.isEmpty) {
      showSnack(context, 'Serial number is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final existing = await findItemBySerial(serial);
      if (existing != null) {
        if (!mounted) return;
        setState(() => _saving = false);
        showSnack(
          context,
          'Serial $serial is already ${existing.code} '
          '(${existing.status}).',
          error: true,
        );
        return;
      }
      final productId = await resolveReferenceId(
        table: 'catalog_products',
        name: model,
        payload: {'category': _categories[kind]},
      );
      final productRows = await db
          .from('catalog_products')
          .select('brand_id')
          .eq('id', productId)
          .limit(1);
      final brandId = productRows.isEmpty
          ? null
          : productRows.first['brand_id'] as int?;
      final letter = (batch['letter'] ?? '').toString();
      final String code;
      if (kind == 'machine') {
        code = letter.isEmpty
            ? await db.rpc('next_old_machine_code') as String
            : await suggestedId('machine', letter: letter);
      } else {
        code = await suggestedId(kind);
      }
      final table = switch (kind) {
        'machine' => 'machines',
        'probe' => 'probes',
        'printer' => 'printers',
        _ => 'parts',
      };
      final status = defaultStatus(kind);
      final row = await db
          .from(table)
          .insert({
            (kind == 'machine' ? 'machine_id' : 'internal_id'): code,
            (kind == 'machine' || kind == 'probe' ? 'model' : 'name_model'):
                model,
            'catalog_product_id': productId,
            'batch_id': batch['id'],
            'status': status,
            'current_location': defaultLocationFor(status),
            'acquisition_date': ?batch['arrival_date'],
            'vendor_id': ?batch['vendor_id'],
            'brand_id': ?brandId,
            'serial_number': serial,
          })
          .select('id')
          .single();
      ref.invalidate(inventoryProvider);
      ref.invalidate(oldStockItemsProvider);
      ref.invalidate(allItemsProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      widget.onCreated(
        InventoryItem(
          kind: kind,
          id: row['id'] as int,
          code: code,
          name: model,
          serial: serial,
          status: status,
          location: defaultLocationFor(status),
          date: batch['arrival_date'] as String?,
          batch: (batch['code'] ?? '').toString(),
          productId: productId,
          vendorId: batch['vendor_id'] as int?,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final productNames = ref
        .watch(productsProvider)
        .maybeWhen(
          data: (rows) => rows.map((r) => r['name_model'].toString()).toList(),
          orElse: () => const <String>[],
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Not in old or new stock — add it here.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Type *'),
            items: [
              for (final kind in _kinds)
                DropdownMenuItem(value: kind, child: Text(itemKindLabel(kind))),
            ],
            onChanged: (value) => setState(() => _kind = value),
          ),
          const SizedBox(height: 12),
          if (_loadingBatches)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            DropdownButtonFormField<int>(
              initialValue: _batchId,
              decoration: const InputDecoration(labelText: 'Batch *'),
              items: [
                for (final row in _batches)
                  DropdownMenuItem(
                    value: row['id'] as int,
                    child: Text(
                      [
                        (row['code'] ?? '').toString(),
                        if (row['code'] == 'BATCH-OLD')
                          'old stock'
                        else if ((row['arrival_date'] ?? '')
                            .toString()
                            .isNotEmpty)
                          (row['arrival_date'] ?? '').toString(),
                      ].join(' · '),
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _batchId = value),
            ),
          const SizedBox(height: 12),
          PickyField(
            controller: _model,
            label: 'Model *',
            options: productNames,
            pickTitle: 'models',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serial,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Serial number *'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : widget.onCancel,
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _saving ? null : _create,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Add and use it'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
