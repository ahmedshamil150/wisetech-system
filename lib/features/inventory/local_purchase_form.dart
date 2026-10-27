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

/// One probe inside a local purchase — a seller can hand over several
/// probes with a single machine, so each one keeps its own model, serial
/// and condition.
class _ProbeLine {
  final model = TextEditingController();
  final serial = TextEditingController();
  String condition = 'Used';

  void dispose() {
    model.dispose();
    serial.dispose();
  }
}

/// One spare part inside a local purchase — a doctor sometimes sells a
/// single board, sometimes several at once, so each keeps its own name,
/// serial and condition.
class _PartLine {
  final model = TextEditingController();
  final serial = TextEditingController();
  String condition = 'Used';

  void dispose() {
    model.dispose();
    serial.dispose();
  }
}

/// Intake for used equipment bought from a local person. A purchase can
/// hold any combination of items — a machine with its probes and printer,
/// a machine alone, just a probe or a printer, or spare parts on their
/// own. Everything enters the standing BATCH-LOCAL batch, linked to the
/// seller as its vendor, and a probe or printer bought with the machine
/// is attached to it so it travels with the machine later.
class LocalPurchaseForm extends ConsumerStatefulWidget {
  const LocalPurchaseForm({super.key});

  @override
  ConsumerState<LocalPurchaseForm> createState() => _LocalPurchaseFormState();
}

class _LocalPurchaseFormState extends ConsumerState<LocalPurchaseForm> {
  bool _withMachine = true;
  bool _withProbe = false;
  bool _withPrinter = false;
  bool _withPart = false;

  final _machineModel = TextEditingController();
  final _machineSerial = TextEditingController();
  final _printerModel = TextEditingController();
  final _printerSerial = TextEditingController();
  final _seller = TextEditingController();
  final _phone = TextEditingController();
  final _price = TextEditingController();
  final _notes = TextEditingController();
  final _date = TextEditingController();
  final _code = TextEditingController();
  String _machineCondition = 'Used';
  String _printerCondition = 'Used';
  // A seller can hand over several probes with one machine, so the probe
  // section holds a line per probe; parts come one per line the same way.
  final List<_ProbeLine> _probeLines = [];
  final List<_PartLine> _partLines = [];
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
    for (final line in _probeLines) {
      line.dispose();
    }
    for (final line in _partLines) {
      line.dispose();
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
    if (!_withMachine && !_withProbe && !_withPrinter && !_withPart) {
      showSnack(context, 'Pick at least one item — machine, probe, printer '
          'or part.',
          error: true);
      return;
    }
    if (_withMachine && _machineModel.text.trim().isEmpty) {
      showSnack(context, 'Machine model is required.', error: true);
      return;
    }
    if (_withProbe) {
      if (_probeLines.isEmpty) {
        showSnack(context, 'Add a probe model or turn the probe switch off.',
            error: true);
        return;
      }
      for (var i = 0; i < _probeLines.length; i++) {
        if (_probeLines[i].model.text.trim().isEmpty) {
          showSnack(
              context,
              _probeLines.length == 1
                  ? 'Probe model is required.'
                  : 'Probe ${i + 1} model is required.',
              error: true);
          return;
        }
      }
    }
    if (_withPrinter && _printerModel.text.trim().isEmpty) {
      showSnack(context, 'Printer model is required.', error: true);
      return;
    }
    if (_withPart) {
      if (_partLines.isEmpty) {
        showSnack(context, 'Add a part name or turn the part switch off.',
            error: true);
        return;
      }
      for (var i = 0; i < _partLines.length; i++) {
        if (_partLines[i].model.text.trim().isEmpty) {
          showSnack(
              context,
              _partLines.length == 1
                  ? 'Part name is required.'
                  : 'Part ${i + 1} name is required.',
              error: true);
          return;
        }
      }
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
        final linked = machineId != null;
        for (var i = 0; i < _probeLines.length; i++) {
          final line = _probeLines[i];
          final model = line.model.text.trim();
          final (productId, brandId) = await _productFor(model, 'Probe');
          // A probe bought with the machine shares the machine's ID, the
          // same way a machine's kit has always been numbered.
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
            'condition': line.condition,
            if (linked) 'assigned_machine_id': machineId,
            'brand_id': ?brandId,
            if (line.serial.text.trim().isNotEmpty)
              'serial_number': line.serial.text.trim(),
            // The price lands on the machine when there is one, otherwise
            // on the first standalone item.
            if (price != null && !linked && i == 0) 'purchase_price': price,
            if (notes.isNotEmpty) 'notes': notes,
          });
          if (!created.contains(code)) created.add(code);
        }
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
        if (!created.contains(code)) created.add(code);
      }

      // Spare parts stand on their own: each line becomes its own part
      // row with the next PART-… number, never attached to the machine.
      if (_withPart) {
        for (var i = 0; i < _partLines.length; i++) {
          final line = _partLines[i];
          final name = line.model.text.trim();
          final (productId, brandId) = await _productFor(name, 'Part');
          final code = await suggestedId('part');
          await db.from('parts').insert({
            'internal_id': code,
            'name_model': name,
            'catalog_product_id': productId,
            'batch_id': _batchId,
            'vendor_id': sellerId,
            'acquisition_date': date,
            'status': 'Available',
            'current_location': 'Company',
            'condition': line.condition,
            'brand_id': ?brandId,
            if (line.serial.text.trim().isNotEmpty)
              'serial_number': line.serial.text.trim(),
            // the price lands on the machine first, then the first
            // standalone item — parts only when they are all there is
            if (price != null &&
                !_withMachine &&
                !_withProbe &&
                !_withPrinter &&
                i == 0)
              'purchase_price': price,
            if (notes.isNotEmpty) 'notes': notes,
          });
          if (!created.contains(code)) created.add(code);
        }
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

  /// One probe's fields inside the probe section. When the purchase holds
  /// several probes every block gets a "Probe N" header and a remove
  /// button; a single probe keeps the original plain layout.
  Widget _probeLine(BuildContext context, int i, List<String> productNames) {
    final line = _probeLines[i];
    final many = _probeLines.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (many && i > 0) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
        ],
        if (many)
          Row(
            children: [
              Expanded(
                child: Text('Probe ${i + 1}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Remove this probe',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  line.dispose();
                  setState(() => _probeLines.removeAt(i));
                },
              ),
            ],
          ),
        PickyField(
          controller: line.model,
          label: 'Model *',
          hint: 'Start typing — suggestions appear',
          options: productNames,
          pickTitle: 'models',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: line.serial,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Serial number',
            hintText: 'Empty → system number (WT-…)',
          ),
        ),
        const SizedBox(height: 12),
        _conditionField(
          value: line.condition,
          options: _kitItemConditions,
          label: 'Condition',
          onChanged: (v) => line.condition = v,
        ),
      ],
    );
  }

  /// One part's fields inside the parts section. Several parts get a
  /// "Part N" header and a remove button each, exactly like probes.
  Widget _partLine(BuildContext context, int i, List<String> partNames) {
    final line = _partLines[i];
    final many = _partLines.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (many && i > 0) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
        ],
        if (many)
          Row(
            children: [
              Expanded(
                child: Text('Part ${i + 1}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Remove this part',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  line.dispose();
                  setState(() => _partLines.removeAt(i));
                },
              ),
            ],
          ),
        PickyField(
          controller: line.model,
          label: 'Name *',
          hint: 'e.g. CB board, power supply — suggestions appear',
          options: partNames,
          pickTitle: 'part names',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: line.serial,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Serial number'),
        ),
        const SizedBox(height: 12),
        _conditionField(
          value: line.condition,
          options: _kitItemConditions,
          label: 'Condition',
          onChanged: (v) => line.condition = v,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final productNames = [
      for (final row in products) row['name_model'].toString(),
    ];
    // the part suggestions only offer catalog parts, so a board never
    // shows up next to machine models
    final partNames = [
      for (final row in products)
        if (row['category'] == 'Part') row['name_model'].toString(),
    ];

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
                      _itemChip(context, 'Probe', _withProbe, () => setState(() {
                            _withProbe = !_withProbe;
                            if (_withProbe && _probeLines.isEmpty) {
                              _probeLines.add(_ProbeLine());
                            }
                          })),
                      _itemChip(context, 'Printer', _withPrinter,
                          () => setState(() => _withPrinter = !_withPrinter)),
                      _itemChip(context, 'Part', _withPart, () => setState(() {
                            _withPart = !_withPart;
                            if (_withPart && _partLines.isEmpty) {
                              _partLines.add(_PartLine());
                            }
                          })),
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
                    _sectionTitle(
                        _probeLines.length > 1 ? 'Probes' : 'Probe'),
                    if (_withMachine)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 8),
                        child: Text(
                          _probeLines.length > 1
                              ? "Each comes with the machine — they share the machine's ID and travel with it."
                              : "Comes with the machine — shares the machine's ID and travels with it.",
                          style: TextStyle(
                              fontSize: 12.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant),
                        ),
                      )
                    else
                      const SizedBox(height: 8),
                    for (var i = 0; i < _probeLines.length; i++)
                      _probeLine(context, i, productNames),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _probeLines.add(_ProbeLine())),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add another probe'),
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
                  if (_withPart) ...[
                    const SizedBox(height: 16),
                    _sectionTitle(_partLines.length > 1 ? 'Parts' : 'Part'),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Text(
                        'Each line becomes its own part in stock, bought '
                        'from this seller.',
                        style: TextStyle(
                            fontSize: 12.5,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                    for (var i = 0; i < _partLines.length; i++)
                      _partLine(context, i, partNames),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _partLines.add(_PartLine())),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add another part'),
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
