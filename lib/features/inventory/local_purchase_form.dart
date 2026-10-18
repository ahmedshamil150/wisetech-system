import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Opens the "buy equipment from a local person" form.
Future<void> showLocalPurchaseSheet(BuildContext context) {
  return showAppSheet<void>(
    context: context,
    title: 'Buy local equipment',
    heightFraction: 0.85,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: const LocalPurchaseForm(),
    ),
  );
}

/// Intake for used equipment bought from a local person. A purchase can
/// hold any combination of items — a machine with its probe and printer,
/// a machine alone, or just a probe or a printer. Everything enters the
/// standing BATCH-LOCAL batch, linked to the seller as its vendor, and a
/// probe or printer bought with the machine is attached to it so it
/// travels with the machine later.
class LocalPurchaseForm extends ConsumerStatefulWidget {
  const LocalPurchaseForm({super.key});

  @override
  ConsumerState<LocalPurchaseForm> createState() => _LocalPurchaseFormState();
}

class _LocalPurchaseFormState extends ConsumerState<LocalPurchaseForm> {
  bool _withMachine = true;
  bool _withProbe = false;
  bool _withPrinter = false;

  final _machineModel = TextEditingController();
  final _machineSerial = TextEditingController();
  final _probeModel = TextEditingController();
  final _probeSerial = TextEditingController();
  final _printerModel = TextEditingController();
  final _printerSerial = TextEditingController();
  final _seller = TextEditingController();
  final _phone = TextEditingController();
  final _price = TextEditingController();
  final _notes = TextEditingController();
  final _date = TextEditingController();
  final _code = TextEditingController();
  String _machineCondition = 'Used';
  String _probeCondition = 'Used';
  String _printerCondition = 'Used';
  int? _batchId;
  bool _loadingId = true;
  bool _saving = false;

  static const _machineConditions = ['Used', 'Good', 'Faulty', 'Unknown'];
  // Probes and printers share the same CHECK set in the database.
  static const _kitItemConditions = [
    'Used',
    'Good',
    'Needs Inspection',
    'Damaged',
    'Under Repair',
  ];

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
    _loadId();
  }

  @override
  void dispose() {
    for (final c in [
      _machineModel,
      _machineSerial,
      _probeModel,
      _probeSerial,
      _printerModel,
      _printerSerial,
      _seller,
      _phone,
      _price,
      _notes,
      _date,
      _code,
    ]) {
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

  Future<(int, int?)> _productFor(String name, String category) async {
    final productId = await resolveReferenceId(
      table: 'catalog_products',
      name: name,
      payload: {'category': category},
    );
    final rows = await db
        .from('catalog_products')
        .select('brand_id')
        .eq('id', productId)
        .limit(1);
    return (productId,
        rows.isEmpty ? null : rows.first['brand_id'] as int?);
  }

  Future<void> _save() async {
    final seller = _seller.text.trim();
    if (seller.isEmpty) {
      showSnack(context, 'Seller name is required.', error: true);
      return;
    }
    if (!_withMachine && !_withProbe && !_withPrinter) {
      showSnack(context, 'Pick at least one item — machine, probe or printer.',
          error: true);
      return;
    }
    if (_withMachine && _machineModel.text.trim().isEmpty) {
      showSnack(context, 'Machine model is required.', error: true);
      return;
    }
    if (_withProbe && _probeModel.text.trim().isEmpty) {
      showSnack(context, 'Probe model is required.', error: true);
      return;
    }
    if (_withPrinter && _printerModel.text.trim().isEmpty) {
      showSnack(context, 'Printer model is required.', error: true);
      return;
    }
    if (_batchId == null) {
      showSnack(context,
          'The BATCH-LOCAL batch is missing — migration 0017 was not run.',
          error: true);
      return;
    }
    if (_withMachine && _code.text.trim().isEmpty) {
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
      final price = double.tryParse(_price.text.trim());
      final date = _date.text.trim();
      final notes = _notes.text.trim();
      final created = <String>[];

      int? machineId;
      String? machineCode;
      if (_withMachine) {
        final model = _machineModel.text.trim();
        final (productId, brandId) = await _productFor(model, 'Machine');
        final row = await db.from('machines').insert({
          'machine_id': _code.text.trim(),
          'model': model,
          'catalog_product_id': productId,
          'batch_id': _batchId,
          'vendor_id': sellerId,
          'status': 'In Stock',
          'current_location': 'Company',
          'acquisition_date': date,
          'condition': _machineCondition,
          'brand_id': ?brandId,
          if (_machineSerial.text.trim().isNotEmpty)
            'serial_number': _machineSerial.text.trim(),
          'purchase_price': ?price,
          if (notes.isNotEmpty) 'notes': notes,
        }).select('id').single();
        machineId = row['id'] as int;
        machineCode = _code.text.trim();
        created.add(machineCode);
      }

      if (_withProbe) {
        final model = _probeModel.text.trim();
        final linked = machineId != null;
        final (productId, brandId) = await _productFor(model, 'Probe');
        final code = linked ? machineCode! : await suggestedId('probe');
        await db.from('probes').insert({
          'internal_id': code,
          'model': model,
          'catalog_product_id': productId,
          'batch_id': _batchId,
          'vendor_id': sellerId,
          'acquisition_date': date,
          'status': linked ? 'With Machine' : 'Available',
          'current_location': 'Company',
          'condition': _probeCondition,
          if (linked) 'assigned_machine_id': machineId,
          'brand_id': ?brandId,
          if (_probeSerial.text.trim().isNotEmpty)
            'serial_number': _probeSerial.text.trim(),
          // The price lands on the machine when there is one, otherwise on
          // the first standalone item.
          if (price != null && !linked) 'purchase_price': price,
          if (notes.isNotEmpty) 'notes': notes,
        });
        created.add(code);
      }

      if (_withPrinter) {
        final model = _printerModel.text.trim();
        final linked = machineId != null;
        final (productId, brandId) = await _productFor(model, 'Printer');
        final code = linked ? machineCode! : await suggestedId('printer');
        await db.from('printers').insert({
          'internal_id': code,
          'name_model': model,
          'catalog_product_id': productId,
          'batch_id': _batchId,
          'vendor_id': sellerId,
          'acquisition_date': date,
          'status': linked ? 'With Machine' : 'Available',
          'current_location': 'Company',
          'condition': _printerCondition,
          if (linked) 'assigned_machine_id': machineId,
          'brand_id': ?brandId,
          if (_printerSerial.text.trim().isNotEmpty)
            'serial_number': _printerSerial.text.trim(),
          if (price != null && !_withMachine && !_withProbe)
            'purchase_price': price,
          if (notes.isNotEmpty) 'notes': notes,
        });
        created.add(code);
      }

      ref.invalidate(inventoryProvider);
      ref.invalidate(vendorsProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(
          SnackBar(content: Text('${created.join(', ')} added to stock.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Widget _itemChip(BuildContext context, String label, bool selected,
      VoidCallback onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: Theme.of(context).colorScheme.primary,
      labelStyle: TextStyle(
        color: selected
            ? Colors.white
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      backgroundColor: context.colors.isDark
          ? context.colors.quietFill
          : Theme.of(context).colorScheme.surface,
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    );
  }

  Widget _sectionTitle(String text) => Text(text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800));

  Widget _conditionField({
    required String value,
    required List<String> options,
    required String label,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: options
          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
          .toList(),
      onChanged: (v) => setState(() => onChanged(v ?? options.first)),
    );
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
                child: Text('Buy local equipment',
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
                  _sectionTitle("What's in this purchase"),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _itemChip(context, 'Machine', _withMachine,
                          () => setState(() => _withMachine = !_withMachine)),
                      _itemChip(context, 'Probe', _withProbe,
                          () => setState(() => _withProbe = !_withProbe)),
                      _itemChip(context, 'Printer', _withPrinter,
                          () => setState(() => _withPrinter = !_withPrinter)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _seller,
                    decoration: const InputDecoration(
                      labelText: 'Seller name *',
                      hintText: 'Person you bought the equipment from',
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
                  if (_withMachine) ...[
                    const SizedBox(height: 16),
                    _sectionTitle('Machine'),
                    const SizedBox(height: 8),
                    PickyField(
                      controller: _machineModel,
                      label: 'Model *',
                      hint: 'Start typing — suggestions appear',
                      options: productNames,
                      pickTitle: 'models',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _machineSerial,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Serial number',
                        hintText: 'Empty → system number (WT-…)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _conditionField(
                      value: _machineCondition,
                      options: _machineConditions,
                      label: 'Condition',
                      onChanged: (v) => _machineCondition = v,
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
                  if (_withProbe) ...[
                    const SizedBox(height: 16),
                    _sectionTitle('Probe'),
                    if (_withMachine)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 8),
                        child: Text(
                          "Comes with the machine — shares the machine's ID and travels with it.",
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                      )
                    else
                      const SizedBox(height: 8),
                    PickyField(
                      controller: _probeModel,
                      label: 'Model *',
                      hint: 'Start typing — suggestions appear',
                      options: productNames,
                      pickTitle: 'models',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _probeSerial,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Serial number',
                        hintText: 'Empty → system number (WT-…)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _conditionField(
                      value: _probeCondition,
                      options: _kitItemConditions,
                      label: 'Condition',
                      onChanged: (v) => _probeCondition = v,
                    ),
                  ],
                  if (_withPrinter) ...[
                    const SizedBox(height: 16),
                    _sectionTitle('Printer'),
                    if (_withMachine)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 8),
                        child: Text(
                          "Comes with the machine — shares the machine's ID and travels with it.",
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                      )
                    else
                      const SizedBox(height: 8),
                    PickyField(
                      controller: _printerModel,
                      label: 'Model *',
                      hint: 'Start typing — suggestions appear',
                      options: productNames,
                      pickTitle: 'models',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _printerSerial,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Serial number',
                        hintText: 'Empty → system number (WT-…)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    _conditionField(
                      value: _printerCondition,
                      options: _kitItemConditions,
                      label: 'Condition',
                      onChanged: (v) => _printerCondition = v,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: DateField(controller: _date)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _price,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Price paid',
                            hintText: 'Optional — what we paid',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'Optional',
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
