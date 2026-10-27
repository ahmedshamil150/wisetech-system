import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';
import 'old_item_form.dart';

/// Opens the sell form for one old-stock item: records the sale — a
/// `sales` row plus the `sale_items` line linked to this item — and
/// marks the item Sold. Nothing else about the item is touched, and no
/// existing row is changed apart from this item's status.
Future<void> showOldSellSheet(
  BuildContext context, {
  required String kind,
  required Map<String, dynamic> row,
}) {
  return showAppSheet<void>(
    context: context,
    title: 'Sell ${(row[codeColumnFor(kind)] ?? row['code'] ?? '').toString()}',
    heightFraction: 0.9,
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: _OldSellForm(kind: kind, row: row),
    ),
  );
}

class _OldSellForm extends ConsumerStatefulWidget {
  const _OldSellForm({required this.kind, required this.row});

  final String kind;
  final Map<String, dynamic> row;

  @override
  ConsumerState<_OldSellForm> createState() => _OldSellFormState();
}

class _OldSellFormState extends ConsumerState<_OldSellForm> {
  late final TextEditingController _date;
  late final TextEditingController _buyer;
  late final TextEditingController _price;
  late final TextEditingController _invoice;
  late final TextEditingController _notes;
  late String _buyerType;
  bool _saving = false;

  static const _buyerTypes = ['Customer', 'Dealer', 'Branch'];

  /// A row's display field: full rows carry the real column, the parts
  /// pane only carries the display map ('code', 'name', 'serial').
  String _field(String column, String fallback) =>
      (widget.row[column] ?? widget.row[fallback] ?? '').toString();

  String get _code => _field(codeColumnFor(widget.kind), 'code');
  String get _name => _field(nameColumnFor(widget.kind), 'name');
  String get _serial => _field('serial_number', 'serial');

  String get _description {
    final text = [_code, _name].where((s) => s.isNotEmpty).join(' ');
    return text.isEmpty ? _serial : text;
  }

  @override
  void initState() {
    super.initState();
    _date = TextEditingController(text: DateField.format(DateTime.now()));
    _buyer = TextEditingController();
    _price = TextEditingController();
    _invoice = TextEditingController();
    _notes = TextEditingController();
    _buyerType = 'Customer';
  }

  @override
  void dispose() {
    for (final c in [_date, _buyer, _price, _invoice, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _buyer.text.trim();
    if (name.isEmpty) {
      showSnack(context, 'Buyer name is required.', error: true);
      return;
    }
    final displayDate = _date.text.trim();
    if (displayDate.isEmpty) {
      showSnack(context, 'Date is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final price = double.tryParse(_price.text.trim());
    try {
      // A buyer who already exists as a customer is linked by id; every
      // other buyer is written as the `party:kind:NAME` notes line the
      // sales list already parses back, so no new customer rows appear.
      int? customerId;
      if (_buyerType == 'Customer') {
        final customers = ref.read(customersProvider).maybeWhen(
              data: (rows) => rows,
              orElse: () => const <Map<String, dynamic>>[],
            );
        for (final c in customers) {
          if ((c['name'] ?? '').toString().trim().toLowerCase() ==
              name.toLowerCase()) {
            customerId = c['id'] as int;
            break;
          }
        }
      }
      final notes = <String>[
        if (customerId == null) oldSalePartyNote(_buyerType.toLowerCase(), name),
        if (_notes.text.trim().isNotEmpty) _notes.text.trim(),
      ].join('\n');
      final sale = await db.from('sales').insert({
        'sale_date': oldDisplayToIso(displayDate),
        'sale_price': ?price,
        if (_invoice.text.trim().isNotEmpty)
          'invoice_reference': _invoice.text.trim(),
        'customer_id': ?customerId,
        if (notes.isNotEmpty) 'notes': notes,
        'actor_id': ref.read(authControllerProvider).currentUser?.id,
      }).select('id').single();
      await db.from('sale_items').insert({
        'sale_id': sale['id'],
        'item_type': widget.kind,
        '${widget.kind}_id': widget.row['id'],
        'item_description': _description,
        if (_serial.isNotEmpty) 'item_serial': _serial,
        'item_price': ?price,
        'is_main_item': 1,
      });
      await db
          .from(tableFor(widget.kind))
          .update({'status': 'Sold'}).eq('id', widget.row['id']);
      ref.invalidate(oldSalesProvider);
      ref.invalidate(oldMachinesProvider);
      ref.invalidate(oldProbesProvider);
      ref.invalidate(oldPrintersProvider);
      ref.invalidate(inventoryProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
          SnackBar(content: Text('Sold ${_code.isEmpty ? _name : _code} to $name.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final customers = ref.watch(customersProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final dealers = ref.watch(dealersProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final options = switch (_buyerType) {
      'Customer' => [
          for (final c in customers) (c['name'] ?? '').toString(),
        ],
      'Dealer' => [
          for (final d in dealers) (d['name'] ?? '').toString(),
        ],
      _ => const <String>[],
    };
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
                    'Sell ${_code.isEmpty ? _name : _code}',
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
          Text(
            [_name, if (_serial.isNotEmpty) 'Serial $_serial']
                .where((s) => s.isNotEmpty)
                .join(' · '),
            style: TextStyle(fontSize: 13, color: scheme.outline),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DateField(controller: _date, label: 'Sale date'),
                  const SizedBox(height: 12),
                  Text('Buyer type',
                      style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    key: ValueKey('old-sell-type-$_buyerType'),
                    initialValue: _buyerType,
                    items: [
                      for (final v in _buyerTypes)
                        DropdownMenuItem(value: v, child: Text(v)),
                    ],
                    onChanged: (v) => setState(
                        () => _buyerType = v ?? 'Customer'),
                  ),
                  const SizedBox(height: 12),
                  PickyField(
                    controller: _buyer,
                    label: 'Buyer *',
                    hint: options.isEmpty
                        ? 'Type any name'
                        : 'Type or pick a name',
                    pickTitle: 'Pick a buyer',
                    options: options,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _price,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Price (optional)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _invoice,
                          decoration: const InputDecoration(
                              labelText: 'Invoice (optional)'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Notes (optional)'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sell_outlined, size: 18),
            label: Text(_saving ? 'Saving…' : 'Sell'),
          ),
        ],
      ),
    );
  }
}
