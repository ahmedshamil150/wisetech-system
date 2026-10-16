import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Opens the "buy a machine from a local person" form.
Future<void> showLocalPurchaseSheet(BuildContext context) {
  return showAppSheet<void>(
    context: context,
    title: 'Buy local machine',
    heightFraction: 0.85,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: const LocalPurchaseForm(),
    ),
  );
}

/// Intake for a used machine bought from a local person. The machine
/// enters the standing BATCH-LOCAL batch as 'In Stock' at the company,
/// linked to the seller as its vendor, and is sold like any other stock.
class LocalPurchaseForm extends ConsumerStatefulWidget {
  const LocalPurchaseForm({super.key});

  @override
  ConsumerState<LocalPurchaseForm> createState() => _LocalPurchaseFormState();
}

class _LocalPurchaseFormState extends ConsumerState<LocalPurchaseForm> {
  final _model = TextEditingController();
  final _seller = TextEditingController();
  final _phone = TextEditingController();
  final _price = TextEditingController();
  final _serial = TextEditingController();
  final _notes = TextEditingController();
  final _date = TextEditingController();
  final _code = TextEditingController();
  String _condition = 'Used';
  int? _batchId;
  bool _loadingId = true;
  bool _saving = false;

  static const _conditions = ['Used', 'Good', 'Faulty', 'Unknown'];

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
    _loadId();
  }

  @override
  void dispose() {
    for (final c in
        [_model, _seller, _phone, _price, _serial, _notes, _date, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadId() async {
    try {
      final rows = await db
          .from('batches')
          .select('id, letter')
          .eq('code', 'BATCH-LOCAL')
          .limit(1);
      if (rows.isEmpty) {
        if (mounted) {
          setState(() {
            _loadingId = false;
            _batchId = null;
          });
        }
        return;
      }
      _batchId = rows.first['id'] as int;
      final letter = (rows.first['letter'] ?? 'L').toString();
      final code = await suggestedId('machine', letter: letter);
      if (mounted) {
        _code.text = code;
        setState(() => _loadingId = false);
      }
    } catch (_) {
      if (mounted) {
        _code.text = '';
        setState(() => _loadingId = false);
      }
    }
  }

  Future<void> _save() async {
    final model = _model.text.trim();
    final seller = _seller.text.trim();
    if (model.isEmpty) {
      showSnack(context, 'Model is required.', error: true);
      return;
    }
    if (seller.isEmpty) {
      showSnack(context, 'Seller name is required.', error: true);
      return;
    }
    if (_batchId == null) {
      showSnack(context,
          'The BATCH-LOCAL batch is missing — migration 0017 was not run.',
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
      final sellerId = await resolveReferenceId(
        table: 'vendors',
        name: seller,
        payload: {
          if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
        },
      );
      final productId = await resolveReferenceId(
        table: 'catalog_products',
        name: model,
        payload: {'category': 'Machine'},
      );
      final productRows = await db
          .from('catalog_products')
          .select('brand_id')
          .eq('id', productId)
          .limit(1);
      final brandId =
          productRows.isEmpty ? null : productRows.first['brand_id'] as int?;
      final price = double.tryParse(_price.text.trim());

      final payload = <String, dynamic>{
        'machine_id': _code.text.trim(),
        'model': model,
        'catalog_product_id': productId,
        'batch_id': _batchId,
        'vendor_id': sellerId,
        'status': 'In Stock',
        'current_location': 'Company',
        'acquisition_date': _date.text.trim(),
        'condition': _condition,
      };
      if (brandId != null) payload['brand_id'] = brandId;
      if (_serial.text.trim().isNotEmpty) {
        payload['serial_number'] = _serial.text.trim();
      }
      if (price != null) payload['purchase_price'] = price;
      if (_notes.text.trim().isNotEmpty) payload['notes'] = _notes.text.trim();

      final row = await db
          .from('machines')
          .insert(payload)
          .select('serial_number')
          .single();

      ref.invalidate(inventoryProvider);
      ref.invalidate(vendorsProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      final serialNote =
          _serial.text.trim().isEmpty ? ' — serial ${row['serial_number']}' : '';
      messenger.showSnackBar(SnackBar(
          content: Text('${_code.text.trim()} added to stock$serialNote.')));
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Buy local machine',
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
          if (_batchId == null && !_loadingId)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'The BATCH-LOCAL batch is missing — migration 0017 was not run.',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 13),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PickyField(
                    controller: _model,
                    label: 'Model *',
                    hint: 'Start typing — suggestions appear',
                    options: productNames,
                    pickTitle: 'models',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _seller,
                    decoration: const InputDecoration(
                      labelText: 'Seller name *',
                      hintText: 'Person you bought the machine from',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Seller phone',
                      hintText: 'Optional',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: DateField(controller: _date)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _condition,
                          decoration: const InputDecoration(labelText: 'Condition'),
                          items: _conditions
                              .map((c) =>
                                  DropdownMenuItem(value: c, child: Text(c)))
                              .toList(),
                          onChanged: (value) => setState(
                              () => _condition = value ?? 'Used'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Price paid',
                      hintText: 'Optional — what we paid the seller',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serial,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Serial number',
                      hintText: 'Empty → system number (WT-…)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'Optional',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'ID (generated)',
                      hintText: 'BATCH-LOCAL machines are numbered 1L, 2L ...',
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
