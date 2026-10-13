import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';

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
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
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
  late final TextEditingController _notes;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    _date = TextEditingController(text: (row['movement_date'] ?? '').toString());
    _from = TextEditingController(text: (row['from_location'] ?? '').toString());
    _to = TextEditingController(text: (row['to_location'] ?? '').toString());
    _reason = TextEditingController(text: (row['reason'] ?? '').toString());
    _notes = TextEditingController(text: (row['notes'] ?? '').toString());
  }

  @override
  void dispose() {
    for (final c in [_date, _from, _to, _reason, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db.from('movements').update({
        'movement_date': _date.text.trim(),
        'from_location': _from.text.trim(),
        'to_location': _to.text.trim(),
        'reason': _reason.text.trim().isEmpty ? null : _reason.text.trim(),
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      }).eq('id', widget.row['id']);
      ref.invalidate(oldMovementsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
          const SnackBar(content: Text('Movement updated.')));
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
        content: const Text(
            'This removes the legacy movement row. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
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
          const SnackBar(content: Text('Movement deleted.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Edit movement',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
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
                  DateField(controller: _date),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _from,
                    decoration:
                        const InputDecoration(labelText: 'From location'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _to,
                    decoration:
                        const InputDecoration(labelText: 'To location'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    decoration: const InputDecoration(labelText: 'Reason'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration:
                        const InputDecoration(labelText: 'Notes'),
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
                    backgroundColor: Theme.of(context).colorScheme.error),
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
                        child: CircularProgressIndicator(strokeWidth: 2))
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

/// Opens the edit form for one imported sale.
Future<void> showOldSaleForm(
  BuildContext context, {
  required Map<String, dynamic> row,
}) {
  return showAppSheet<void>(
    context: context,
    title: 'Edit sale #${row['id']}',
    heightFraction: 0.9,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
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
  late final TextEditingController _invoice;
  late final TextEditingController _price;
  late final TextEditingController _notes;
  int? _customerId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final row = widget.row;
    // sales.sale_date is ISO yyyy-MM-dd; DateField shows dd-MM-yyyy.
    _date = TextEditingController(text: _isoToDisplay(
        (row['sale_date'] ?? '').toString()));
    _invoice =
        TextEditingController(text: (row['invoice_reference'] ?? '').toString());
    _price =
        TextEditingController(text: (row['sale_price'] ?? '').toString());
    _notes = TextEditingController(text: (row['notes'] ?? '').toString());
    _customerId = row['customer_id'] as int?;
  }

  @override
  void dispose() {
    for (final c in [_date, _invoice, _price, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// `yyyy-MM-dd` → `dd-MM-yyyy` for the DateField.
  static String _isoToDisplay(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) return iso;
    return '${parts[2]}-${parts[1]}-${parts[0]}';
  }

  /// `dd-MM-yyyy` → `yyyy-MM-dd` for the database.
  static String _displayToIso(String display) {
    final parts = display.split('-');
    if (parts.length != 3) return display;
    return '${parts[2]}-${parts[1]}-${parts[0]}';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await db.from('sales').update({
        'sale_date': _displayToIso(_date.text.trim()),
        'invoice_reference':
            _invoice.text.trim().isEmpty ? null : _invoice.text.trim(),
        'sale_price': double.tryParse(_price.text.trim()) ?? 0,
        'customer_id': _customerId,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      }).eq('id', widget.row['id']);
      ref.invalidate(oldSalesProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Sale updated.')));
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
        title: const Text('Delete this sale?'),
        content: const Text(
            'This removes the sale and its line items. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
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
      // remove the line items first in case there is no cascade
      await db.from('sale_items').delete().eq('sale_id', widget.row['id']);
      await db.from('sales').delete().eq('id', widget.row['id']);
      ref.invalidate(oldSalesProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(const SnackBar(content: Text('Sale deleted.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(customersProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final currentName = (widget.row['customers'] as Map?)?['name']?.toString() ??
        '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Edit sale',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
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
                    controller: _invoice,
                    decoration: const InputDecoration(
                        labelText: 'Invoice reference'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Sale price'),
                  ),
                  const SizedBox(height: 12),
                  Text('Customer',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int?>(
                    key: ValueKey('old-sale-customer-$_customerId'),
                    initialValue: _customerId,
                    items: [
                      const DropdownMenuItem<int?>(
                          value: null, child: Text('(none)')),
                      for (final c in customers)
                        DropdownMenuItem<int?>(
                          value: c['id'] as int,
                          child: Text((c['name'] ?? '').toString(),
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    selectedItemBuilder: (context) => [
                      const Text('(none)'),
                      Text(
                        currentName.isEmpty
                            ? (_customerId?.toString() ?? '(none)')
                            : currentName,
                        overflow: TextOverflow.ellipsis,
                      ),
                      ...customers.skip(1).map((c) => Text(
                            (c['name'] ?? '').toString(),
                            overflow: TextOverflow.ellipsis,
                          )),
                    ],
                    onChanged: (v) => setState(() => _customerId = v),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
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
                    backgroundColor: Theme.of(context).colorScheme.error),
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
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save changes'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
