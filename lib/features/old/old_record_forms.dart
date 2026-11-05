import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

/// `yyyy-MM-dd` → `dd-MM-yyyy` for the DateField.
String _isoToDisplay(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  return '${parts[2]}-${parts[1]}-${parts[0]}';
}

/// `dd-MM-yyyy` → `yyyy-MM-dd` for the database.
String _displayToIso(String display) {
  final parts = display.split('-');
  if (parts.length != 3) return display;
  return '${parts[2]}-${parts[1]}-${parts[0]}';
}

IconData _kindIcon(String kind) => switch (kind) {
  'machine' => Icons.computer_outlined,
  'probe' => Icons.cable_outlined,
  'printer' => Icons.print_outlined,
  'part' => Icons.settings_outlined,
  _ => Icons.inventory_2_outlined,
};

String _tableForKind(String kind) => switch (kind) {
  'machine' => 'machines',
  'probe' => 'probes',
  'printer' => 'printers',
  _ => 'parts',
};

String _amountText(double? amount) {
  if (amount == null || amount == 0) return '';
  return amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : '$amount';
}

/// The buyer as the sale carries it: a customers row, or a dealer/branch
/// tag written into the notes.
({String kind, String name}) _buyerOf(Map<String, dynamic> row) {
  if (row['customer_id'] != null) return (kind: 'Customer', name: '');
  final notes = (row['notes'] ?? '').toString();
  for (final line in notes.split('\n')) {
    final match = RegExp(
      r'^party:(dealer|branch):(.+)$',
    ).firstMatch(line.trim());
    if (match == null) continue;
    return (
      kind: match.group(1) == 'dealer' ? 'Dealer' : 'Branch',
      name: match.group(2)!.trim(),
    );
  }
  return (kind: 'None', name: '');
}

/// The notes minus the buyer tags and the import's placeholder line —
/// those are edited through the buyer fields instead.
String _freeNotes(String notes) => notes
    .split('\n')
    .where((line) {
      final text = line.trim();
      return text.isNotEmpty &&
          !text.startsWith('party:') &&
          text != 'Unknown legacy customer' &&
          !text.startsWith('Unknown legacy customer (');
    })
    .join('\n');

// ---------------------------------------------------------------------------
// movements
// ---------------------------------------------------------------------------

/// Opens the edit form for one imported Legacy movement.
Future<void> showOldMovementForm(
  BuildContext context, {
  required Map<String, dynamic> row,
}) {
  return showAppSheet<void>(
    context: context,
    title: 'Edit legacy movement #${row['id']}',
    heightFraction: 0.9,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _OldMovementForm(row: row),
    ),
  );
}

class _OldMovementForm extends ConsumerStatefulWidget {
  const _OldMovementForm({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_OldMovementForm> createState() => _OldMovementFormState();
}

class _OldMovementFormState extends ConsumerState<_OldMovementForm> {
  late final TextEditingController _date;
  late final TextEditingController _from;
  late final TextEditingController _to;
  late final TextEditingController _reason;
  late final TextEditingController _reference;
  late final TextEditingController _notes;
  String? _itemKind;
  int? _itemId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    _date = TextEditingController(
      text: (row['movement_date'] ?? '').toString(),
    );
    _from = TextEditingController(
      text: (row['from_location'] ?? '').toString(),
    );
    _to = TextEditingController(text: (row['to_location'] ?? '').toString());
    _reason = TextEditingController(text: (row['reason'] ?? '').toString());
    _reference = TextEditingController(
      text: (row['reference'] ?? '').toString(),
    );
    _notes = TextEditingController(text: (row['notes'] ?? '').toString());
    for (final kind in kItemKinds) {
      final id = row['${kind}_id'];
      if (id is int) {
        _itemKind = kind;
        _itemId = id;
        break;
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_date, _from, _to, _reason, _reference, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  String? get _itemKey =>
      _itemId == null ? null : '${_itemKind ?? 'machine'}:$_itemId';

  Future<void> _pickItem() async {
    try {
      final items = await ref.read(allItemsProvider.future);
      if (!mounted) return;
      final item = await showPickItem(
        context,
        items: items,
        selectedKey: _itemKey,
      );
      if (item == null || !mounted) return;
      setState(() {
        _itemKind = item.kind;
        _itemId = item.id;
      });
    } catch (error) {
      if (!mounted) return;
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db
          .from('movements')
          .update({
            'movement_date': _date.text.trim(),
            'from_location': _from.text.trim(),
            'to_location': _to.text.trim(),
            'reason': _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            'reference': _reference.text.trim().isEmpty
                ? null
                : _reference.text.trim(),
            'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            'machine_id': _itemKind == 'machine' ? _itemId : null,
            'probe_id': _itemKind == 'probe' ? _itemId : null,
            'printer_id': _itemKind == 'printer' ? _itemId : null,
            'part_id': _itemKind == 'part' ? _itemId : null,
          })
          .eq('id', widget.row['id']);
      ref.invalidate(oldMovementsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('Movement updated.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this movement?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db.from('movements').delete().eq('id', widget.row['id']);
      ref.invalidate(oldMovementsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('Movement deleted.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(itemLabelsProvider);
    final key = _itemKey;
    final itemLabel = key == null ? null : labels[key];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Edit movement',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
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
                  Text(
                    'Item',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  AppCard(
                    child: ListTile(
                      leading: Icon(
                        _kindIcon(_itemKind ?? 'machine'),
                        size: 20,
                      ),
                      title: Text(
                        itemLabel ??
                            (_itemId == null
                                ? 'No item linked'
                                : '${itemKindLabel(_itemKind ?? 'machine')} #$_itemId'),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          if (_itemId != null)
                            TextButton(
                              onPressed: () => setState(() {
                                _itemKind = null;
                                _itemId = null;
                              }),
                              child: const Text('Clear'),
                            ),
                          TextButton(
                            onPressed: _pickItem,
                            child: Text(_itemId == null ? 'Pick' : 'Change'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DateField(controller: _date),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _from,
                    decoration: const InputDecoration(
                      labelText: 'From location',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _to,
                    decoration: const InputDecoration(labelText: 'To location'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    decoration: const InputDecoration(labelText: 'Reason'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reference,
                    decoration: const InputDecoration(
                      labelText: 'Reference (optional)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save changes'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// sales
// ---------------------------------------------------------------------------

/// One line of a sale while it is being edited. [id] is the stored
/// sale_items row; null means the line is new and will be inserted.
class _SaleLine {
  _SaleLine({
    this.id,
    required this.kind,
    this.itemId,
    required this.description,
    required this.serial,
    this.price,
    this.isMain = false,
  });

  final int? id;
  String kind; // machine | probe | printer | part | other
  int? itemId;
  String description;
  String serial;
  double? price;
  bool isMain;

  bool get linked => itemId != null && kind != 'other';

  _SaleLine copyWith({
    String? kind,
    String? description,
    String? serial,
    double? price,
    bool? isMain,
  }) {
    return _SaleLine(
      id: id,
      kind: kind ?? this.kind,
      itemId: itemId,
      description: description ?? this.description,
      serial: serial ?? this.serial,
      price: price,
      isMain: isMain ?? this.isMain,
    );
  }
}

/// Asks once, then removes a sale and its line items. Returns true when
/// the rows are gone — the caller refreshes its list and closes its sheet.
/// Nothing else is touched: only this sale's own rows go.
Future<bool> confirmDeleteOldSale(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> row,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this sale?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  try {
    final lines = await db
        .from('sale_items')
        .select('item_type, machine_id, probe_id, printer_id, part_id')
        .eq('sale_id', row['id']);
    // remove the line items first in case there is no cascade
    await db.from('sale_items').delete().eq('sale_id', row['id']);
    await db.from('sales').delete().eq('id', row['id']);
    await _putBackUnsoldItems(lines);
    ref.invalidate(oldSalesProvider);
    ref.invalidate(oldStockItemsProvider);
    ref.invalidate(inventoryProvider);
    return true;
  } catch (error) {
    if (context.mounted) showSnack(context, errorMessage(error), error: true);
    return false;
  }
}

/// Puts the items of a just-deleted sale back in stock. The old sell
/// flow only changed status to Sold, so undoing the sale undoes exactly
/// that — an item still named by another sale keeps its Sold status.
Future<void> _putBackUnsoldItems(List<Map<String, dynamic>> lines) async {
  for (final line in lines) {
    final kind = '${line['item_type'] ?? ''}';
    if (kind != 'machine' &&
        kind != 'probe' &&
        kind != 'printer' &&
        kind != 'part') {
      continue;
    }
    final id = line['${kind}_id'];
    if (id is! int) continue;
    if (await _itemStillUsed(kind, id)) continue;
    await db
        .from(_tableForKind(kind))
        .update({'status': defaultStatus(kind)})
        .eq('id', id)
        .eq('status', 'Sold');
  }
}

/// Whether anything else still records this item as sold — another sale
/// line, or a send marked Sold (the old import has such duplicates).
/// Only an item nothing else claims goes back to stock.
Future<bool> _itemStillUsed(String kind, int id) async {
  final otherSale = await db
      .from('sale_items')
      .select('id')
      .eq('${kind}_id', id)
      .limit(1)
      .maybeSingle();
  if (otherSale != null) return true;
  final soldSend = await db
      .from('movements')
      .select('id')
      .eq('${kind}_id', id)
      .like('reason', '%Sold%')
      .limit(1)
      .maybeSingle();
  return soldSend != null;
}

/// Opens the full edit form for one imported sale: its invoice, buyer,
/// dates, money and every line item.
Future<void> showOldSaleForm(
  BuildContext context, {
  required Map<String, dynamic> row,
}) {
  return showAppSheet<void>(
    context: context,
    title: 'Edit sale #${row['id']}',
    heightFraction: 0.92,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _OldSaleForm(row: row),
    ),
  );
}

class _OldSaleForm extends ConsumerStatefulWidget {
  const _OldSaleForm({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_OldSaleForm> createState() => _OldSaleFormState();
}

class _OldSaleFormState extends ConsumerState<_OldSaleForm> {
  late final TextEditingController _date;
  late final TextEditingController _trno;
  late final TextEditingController _invoice;
  late final TextEditingController _price;
  late final TextEditingController _notes;
  late final TextEditingController _dealerName;
  late final TextEditingController _branchName;
  String _buyerKind = 'None';
  int? _customerId;
  bool _wasUnknownLegacy = false;
  final List<_SaleLine> _lines = [];
  bool _loadingLines = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    // sales.sale_date is ISO yyyy-MM-dd; DateField shows dd-MM-yyyy.
    _date = TextEditingController(
      text: _isoToDisplay((row['sale_date'] ?? '').toString()),
    );
    final trno = (row['old_trno'] ?? '').toString().trim();
    // '0' is the old system's "no invoice number", not an invoice.
    _trno = TextEditingController(text: trno == '0' ? '' : trno);
    _invoice = TextEditingController(
      text: (row['invoice_reference'] ?? '').toString(),
    );
    _price = TextEditingController(text: (row['sale_price'] ?? '').toString());
    final notes = (row['notes'] ?? '').toString();
    _wasUnknownLegacy = notes.contains('Unknown legacy customer');
    _notes = TextEditingController(text: _freeNotes(notes));
    final buyer = _buyerOf(row);
    _buyerKind = buyer.kind;
    _customerId = row['customer_id'] as int?;
    _dealerName = TextEditingController(
      text: buyer.kind == 'Dealer' ? buyer.name : '',
    );
    _branchName = TextEditingController(
      text: buyer.kind == 'Branch' ? buyer.name : '',
    );
    _loadLines();
  }

  @override
  void dispose() {
    for (final c in [
      _date,
      _trno,
      _invoice,
      _price,
      _notes,
      _dealerName,
      _branchName,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadLines() async {
    try {
      final rows = await db
          .from('sale_items')
          .select(
            'id, item_type, machine_id, probe_id, printer_id, part_id, '
            'item_description, item_serial, item_price, is_main_item',
          )
          .eq('sale_id', widget.row['id'])
          .order('id');
      if (!mounted) return;
      setState(() {
        _lines
          ..clear()
          ..addAll([
            for (final line in rows)
              _SaleLine(
                id: line['id'] as int,
                kind: '${line['item_type'] ?? 'other'}',
                itemId: line['${line['item_type']}_id'] as int?,
                description: (line['item_description'] ?? '').toString(),
                serial: (line['item_serial'] ?? '').toString(),
                price: (line['item_price'] as num?)?.toDouble(),
                isMain: line['is_main_item'] == 1,
              ),
          ]);
        _loadingLines = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingLines = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Future<void> _addFromStock() async {
    try {
      final items = await ref.read(allItemsProvider.future);
      if (!mounted) return;
      final item = await showPickItem(context, items: items);
      if (item == null || !mounted) return;
      setState(() {
        _lines.add(
          _SaleLine(
            kind: item.kind,
            itemId: item.id,
            description: item.name,
            serial: item.serial ?? '',
          ),
        );
      });
    } catch (error) {
      if (!mounted) return;
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Future<void> _addCustom() async {
    final line = await showDialog<_SaleLine>(
      context: context,
      builder: (_) => const _SaleLineDialog(line: null, linked: false),
    );
    if (line == null || !mounted) return;
    setState(() => _lines.add(line));
  }

  Future<void> _editLine(int index) async {
    final edited = await showDialog<_SaleLine>(
      context: context,
      builder: (_) =>
          _SaleLineDialog(line: _lines[index], linked: _lines[index].linked),
    );
    if (edited == null || !mounted) return;
    setState(() => _lines[index] = edited);
  }

  Future<void> _save() async {
    final kind = _buyerKind;
    final dealerName = _dealerName.text.trim();
    final branchName = _branchName.text.trim();
    if (kind == 'Customer' && _customerId == null) {
      showSnack(
        context,
        'Pick the customer who bought this sale.',
        error: true,
      );
      return;
    }
    if (kind == 'Dealer' && dealerName.isEmpty) {
      showSnack(context, 'Type the dealer name.', error: true);
      return;
    }
    if (kind == 'Branch' && branchName.isEmpty) {
      showSnack(context, 'Type the branch name.', error: true);
      return;
    }
    final priceText = _price.text.trim();
    final salePrice = parseSaleAmount(priceText);
    if (priceText.isNotEmpty && salePrice == null) {
      showSnack(context, 'Sale price must be a number.', error: true);
      return;
    }

    final freeNotes = _notes.text.trim();
    final noteLines = <String>[
      if (freeNotes.isNotEmpty) freeNotes,
      if (kind == 'Dealer') oldSalePartyNote('dealer', dealerName),
      if (kind == 'Branch') oldSalePartyNote('branch', branchName),
      if (kind == 'None' && _wasUnknownLegacy) 'Unknown legacy customer',
    ];

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db
          .from('sales')
          .update({
            'sale_date': _displayToIso(_date.text.trim()),
            'old_trno': _trno.text.trim().isEmpty ? null : _trno.text.trim(),
            'invoice_reference': _invoice.text.trim().isEmpty
                ? null
                : _invoice.text.trim(),
            'sale_price': salePrice,
            'customer_id': kind == 'Customer' ? _customerId : null,
            'notes': noteLines.isEmpty ? null : noteLines.join('\n'),
          })
          .eq('id', widget.row['id']);

      final stored = await db
          .from('sale_items')
          .select('id, item_type, machine_id, probe_id, printer_id, part_id')
          .eq('sale_id', widget.row['id']);
      final keep = <int>{};
      final newlyLinked = <String>{};
      for (final line in _lines) {
        final payload = {
          'item_type': line.kind,
          'machine_id': line.kind == 'machine' ? line.itemId : null,
          'probe_id': line.kind == 'probe' ? line.itemId : null,
          'printer_id': line.kind == 'printer' ? line.itemId : null,
          'part_id': line.kind == 'part' ? line.itemId : null,
          'item_description': line.description.trim().isEmpty
              ? null
              : line.description.trim(),
          'item_serial': line.serial.trim().isEmpty ? null : line.serial.trim(),
          'item_price': line.price,
          'is_main_item': line.isMain ? 1 : 0,
        };
        if (line.id != null) {
          await db.from('sale_items').update(payload).eq('id', line.id!);
          keep.add(line.id!);
        } else {
          final inserted = await db
              .from('sale_items')
              .insert({...payload, 'sale_id': widget.row['id']})
              .select('id')
              .single();
          keep.add(inserted['id'] as int);
          if (line.linked) newlyLinked.add('${line.kind}:${line.itemId}');
        }
      }
      for (final line in stored) {
        final id = line['id'] as int;
        if (keep.contains(id)) continue;
        await db.from('sale_items').delete().eq('id', id);
        await _releaseItem(line);
      }
      for (final key in newlyLinked) {
        final parts = key.split(':');
        await db
            .from(_tableForKind(parts[0]))
            .update({'status': 'Sold'})
            .eq('id', int.parse(parts[1]))
            .neq('status', 'Sold');
      }

      ref.invalidate(oldSalesProvider);
      ref.invalidate(oldStockItemsProvider);
      ref.invalidate(inventoryProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Sale updated.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  /// A removed line's item goes back to stock when no other sale names
  /// it — the same rule the delete-sale flow uses.
  Future<void> _releaseItem(Map<String, dynamic> line) async {
    final kind = '${line['item_type'] ?? ''}';
    if (kind != 'machine' &&
        kind != 'probe' &&
        kind != 'printer' &&
        kind != 'part') {
      return;
    }
    final id = line['${kind}_id'];
    if (id is! int) return;
    if (await _itemStillUsed(kind, id)) return;
    await db
        .from(_tableForKind(kind))
        .update({'status': defaultStatus(kind)})
        .eq('id', id)
        .eq('status', 'Sold');
  }

  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmDeleteOldSale(context, ref, widget.row)) return;
    if (!mounted) return;
    Navigator.pop(context);
    messenger.showSnackBar(const SnackBar(content: Text('Sale deleted.')));
  }

  Widget _lineCard(BuildContext context, int index) {
    final line = _lines[index];
    final scheme = Theme.of(context).colorScheme;
    final meta = [
      itemKindLabel(line.kind),
      if (line.serial.isNotEmpty) 'SN ${line.serial}',
      if (_amountText(line.price).isNotEmpty) _amountText(line.price),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        onTap: () => _editLine(index),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(_kindIcon(line.kind), size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            line.description.isEmpty
                                ? '(no description)'
                                : line.description,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (line.isMain) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.star, size: 14, color: scheme.primary),
                        ],
                      ],
                    ),
                    Text(
                      meta,
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove from sale',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _lines.removeAt(index)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref
        .watch(customersProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final customerIds = {for (final c in customers) c['id'] as int};
    final currentName =
        (widget.row['customers'] as Map?)?['name']?.toString() ?? '';
    final customerOptions = [
      if (_customerId != null && !customerIds.contains(_customerId))
        {
          'id': _customerId,
          'name': currentName.isEmpty ? 'Customer #$_customerId' : currentName,
        },
      ...customers,
    ];
    final selectedCustomer = customerOptions.any((c) => c['id'] == _customerId)
        ? _customerId
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Edit sale',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
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
                  DateField(controller: _date, label: 'Sale date'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _trno,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Old invoice number',
                      hintText: 'The number from the old system',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _invoice,
                    decoration: const InputDecoration(
                      labelText: 'Invoice reference',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Sale price'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Buyer',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    key: ValueKey('old-sale-buyer-$_buyerKind'),
                    initialValue: _buyerKind,
                    items: const [
                      DropdownMenuItem(
                        value: 'Customer',
                        child: Text('Customer'),
                      ),
                      DropdownMenuItem(value: 'Dealer', child: Text('Dealer')),
                      DropdownMenuItem(value: 'Branch', child: Text('Branch')),
                      DropdownMenuItem(
                        value: 'None',
                        child: Text('No buyer recorded'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _buyerKind = value ?? 'None'),
                  ),
                  const SizedBox(height: 12),
                  if (_buyerKind == 'Customer')
                    DropdownButtonFormField<int?>(
                      key: ValueKey('old-sale-customer-$_customerId'),
                      initialValue: selectedCustomer,
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('(none)'),
                        ),
                        for (final c in customerOptions)
                          DropdownMenuItem<int?>(
                            value: c['id'] as int,
                            child: Text(
                              (c['name'] ?? '').toString(),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() => _customerId = value),
                    )
                  else if (_buyerKind == 'Dealer')
                    PickyField(
                      controller: _dealerName,
                      label: 'Dealer name',
                      hint: 'Type or browse dealers',
                      options: [
                        for (final dealer
                            in ref
                                .watch(dealersProvider)
                                .maybeWhen(
                                  data: (rows) => rows,
                                  orElse: () => const <Map<String, dynamic>>[],
                                ))
                          (dealer['name'] ?? '').toString(),
                      ],
                      pickTitle: 'dealers',
                    )
                  else if (_buyerKind == 'Branch')
                    TextField(
                      controller: _branchName,
                      decoration: const InputDecoration(
                        labelText: 'Branch name',
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        'Items (${_lines.length})',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (_loadingLines)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (!_loadingLines && _lines.isEmpty)
                    Text(
                      'No items on this sale yet.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  for (var i = 0; i < _lines.length; i++) _lineCard(context, i),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _loadingLines ? null : _addFromStock,
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: const Text('Add from stock'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loadingLines ? null : _addCustom,
                        icon: const Icon(Icons.playlist_add, size: 18),
                        label: const Text('Add custom item'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: _saving ? null : _delete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _saving || _loadingLines ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save changes'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The add/edit dialog of one sale line. [linked] lines keep the item
/// they point at — only their description, serial, price and main flag
/// change; a custom line can also pick its kind.
class _SaleLineDialog extends StatefulWidget {
  const _SaleLineDialog({required this.line, required this.linked});

  final _SaleLine? line;
  final bool linked;

  @override
  State<_SaleLineDialog> createState() => _SaleLineDialogState();
}

class _SaleLineDialogState extends State<_SaleLineDialog> {
  late final TextEditingController _description;
  late final TextEditingController _serial;
  late final TextEditingController _price;
  late String _kind;
  late bool _isMain;

  bool get _editing => widget.line != null;

  @override
  void initState() {
    super.initState();
    final line = widget.line;
    _description = TextEditingController(text: line?.description ?? '');
    _serial = TextEditingController(text: line?.serial ?? '');
    _price = TextEditingController(text: _amountText(line?.price));
    _kind = line?.kind ?? 'other';
    _isMain = line?.isMain ?? false;
  }

  @override
  void dispose() {
    for (final c in [_description, _serial, _price]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    final text = _price.text.trim();
    final price = parseSaleAmount(text);
    if (text.isNotEmpty && price == null) {
      showSnack(context, 'Price must be a number.', error: true);
      return;
    }
    final line = widget.line;
    Navigator.pop(
      context,
      line == null
          ? _SaleLine(
              kind: _kind,
              description: _description.text.trim(),
              serial: _serial.text.trim(),
              price: price,
              isMain: _isMain,
            )
          : line.copyWith(
              kind: widget.linked ? line.kind : _kind,
              description: _description.text.trim(),
              serial: _serial.text.trim(),
              price: price,
              isMain: _isMain,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? 'Edit item' : 'Add custom item'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.linked)
            DropdownButtonFormField<String>(
              key: ValueKey('sale-line-kind-$_kind'),
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Item type'),
              items: const [
                DropdownMenuItem(value: 'machine', child: Text('Machine')),
                DropdownMenuItem(value: 'probe', child: Text('Probe')),
                DropdownMenuItem(value: 'printer', child: Text('Printer')),
                DropdownMenuItem(value: 'part', child: Text('Part')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (value) => setState(() => _kind = value ?? 'other'),
            )
          else
            Text(
              'Linked ${itemKindLabel(_kind)}',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serial,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Serial number'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Price'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Main item'),
            value: _isMain,
            onChanged: (value) => setState(() => _isMain = value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _apply,
          child: Text(_editing ? 'Save item' : 'Add item'),
        ),
      ],
    );
  }
}
