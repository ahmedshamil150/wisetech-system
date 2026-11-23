import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Conditions a batch machine can be entered with.
const _machineConditions = ['Good', 'Used', 'Faulty', 'Unknown'];

/// Conditions probes and printers share (same CHECK set in the database).
const _kitItemConditions = ['Good', 'Used', 'Needs Inspection', 'Damaged'];

/// Opens the one-screen entry for a whole batch group: the machine, every
/// probe that comes with it and its printer. The machine id (1U, 2U, ...)
/// is generated from the current batch letter, and the probes/printer share
/// it, so the group is numbered exactly like the physical marker label.
Future<void> showBatchGroupSheet(BuildContext context) {
  return showAppSheet<void>(
    context: context,
    title: 'Add batch group',
    heightFraction: 0.9,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: const BatchGroupForm(),
    ),
  );
}

/// One probe inside a group: model, serial and its own condition.
class _ProbeLine {
  final model = TextEditingController();
  final serial = TextEditingController();
  String condition = 'Good';

  void dispose() {
    model.dispose();
    serial.dispose();
  }
}

/// Entry form for one batch group. Everything entered here joins the
/// current batch (the one set in Records), so vendor and arrival date are
/// inherited instead of typed again.
class BatchGroupForm extends ConsumerStatefulWidget {
  const BatchGroupForm({super.key});

  @override
  ConsumerState<BatchGroupForm> createState() => _BatchGroupFormState();
}

class _BatchGroupFormState extends ConsumerState<BatchGroupForm> {
  final _machineModel = TextEditingController();
  final _machineSerial = TextEditingController();
  final _printerModel = TextEditingController();
  final _printerSerial = TextEditingController();
  final _notes = TextEditingController();
  final _price = TextEditingController();
  final _code = TextEditingController();

  String _machineCondition = 'Good';
  String _printerCondition = 'Good';
  bool _withProbe = true;
  bool _withPrinter = true;

  final List<_ProbeLine> _probeLines = [_ProbeLine()];

  Map<String, dynamic>? _batch;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadBatch();
  }

  @override
  void dispose() {
    for (final c in [
      _machineModel,
      _machineSerial,
      _printerModel,
      _printerSerial,
      _notes,
      _price,
      _code,
    ]) {
      c.dispose();
    }
    for (final line in _probeLines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBatch() async {
    try {
      final batch = await ref.read(currentBatchProvider.future);
      _batch = batch;
      final letter = (batch?['letter'] ?? '').toString();
      String code = '';
      if (letter.isNotEmpty) {
        code = await suggestedId('machine', letter: letter);
      }
      if (mounted) {
        setState(() {
          _code.text = code;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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
    return (productId, rows.isEmpty ? null : rows.first['brand_id'] as int?);
  }

  Future<void> _save() async {
    final machineModel = _machineModel.text.trim();
    if (machineModel.isEmpty) {
      showSnack(context, 'Machine model is required.', error: true);
      return;
    }
    if (_batch == null) {
      showSnack(
        context,
        'No current batch — create one in Records → Batches first.',
        error: true,
      );
      return;
    }
    if (_code.text.trim().isEmpty) {
      showSnack(context, 'The group ID could not be generated.', error: true);
      return;
    }
    if (_withProbe) {
      for (var i = 0; i < _probeLines.length; i++) {
        if (_probeLines[i].model.text.trim().isEmpty) {
          showSnack(
            context,
            _probeLines.length == 1
                ? 'Probe model is required.'
                : 'Probe ${i + 1} model is required.',
            error: true,
          );
          return;
        }
      }
    }
    if (_withPrinter && _printerModel.text.trim().isEmpty) {
      showSnack(context, 'Printer model is required.', error: true);
      return;
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final batch = _batch!;
      final batchId = batch['id'] as int;
      final vendorId = batch['vendor_id'] as int?;
      final date = (batch['arrival_date'] ?? '').toString();
      final code = _code.text.trim();
      final notes = _notes.text.trim();
      final price = double.tryParse(_price.text.trim());

      final (machineProductId, machineBrandId) = await _productFor(
        machineModel,
        'Machine',
      );
      final machineRow = await db
          .from('machines')
          .insert({
            'machine_id': code,
            'model': machineModel,
            'catalog_product_id': machineProductId,
            'batch_id': batchId,
            'vendor_id': ?vendorId,
            if (date.isNotEmpty) 'acquisition_date': date,
            'status': 'In Stock',
            'current_location': 'Company',
            'condition': _machineCondition,
            'image_group_code': code,
            'brand_id': ?machineBrandId,
            if (_machineSerial.text.trim().isNotEmpty)
              'serial_number': _machineSerial.text.trim(),
            'purchase_price': ?price,
            if (notes.isNotEmpty) 'notes': notes,
          })
          .select('id')
          .single();
      final machineRowId = machineRow['id'] as int;

      var probeCount = 0;
      if (_withProbe) {
        for (final line in _probeLines) {
          final model = line.model.text.trim();
          final (productId, brandId) = await _productFor(model, 'Probe');
          await db.from('probes').insert({
            'internal_id': code,
            'model': model,
            'catalog_product_id': productId,
            'batch_id': batchId,
            'vendor_id': ?vendorId,
            if (date.isNotEmpty) 'acquisition_date': date,
            'status': 'With Machine',
            'current_location': 'Company',
            'condition': line.condition,
            'assigned_machine_id': machineRowId,
            'image_group_code': code,
            'brand_id': ?brandId,
            if (line.serial.text.trim().isNotEmpty)
              'serial_number': line.serial.text.trim(),
            if (notes.isNotEmpty) 'notes': notes,
          });
          probeCount++;
        }
      }

      if (_withPrinter) {
        final printerModel = _printerModel.text.trim();
        final (productId, brandId) = await _productFor(printerModel, 'Printer');
        await db.from('printers').insert({
          'internal_id': code,
          'name_model': printerModel,
          'catalog_product_id': productId,
          'batch_id': batchId,
          'vendor_id': ?vendorId,
          if (date.isNotEmpty) 'acquisition_date': date,
          'status': 'With Machine',
          'current_location': 'Company',
          'condition': _printerCondition,
          'assigned_machine_id': machineRowId,
          'image_group_code': code,
          'brand_id': ?brandId,
          if (_printerSerial.text.trim().isNotEmpty)
            'serial_number': _printerSerial.text.trim(),
          if (notes.isNotEmpty) 'notes': notes,
        });
      }

      ref.invalidate(inventoryProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      final parts = [
        code,
        if (probeCount > 0)
          '$probeCount probe${probeCount == 1 ? '' : 's'}',
        if (_withPrinter) 'printer',
      ];
      messenger.showSnackBar(
        SnackBar(content: Text('${parts.join(' + ')} added to stock.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Widget _toggleChip(String label, bool selected, VoidCallback? onTap) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap(),
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

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
  );

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

  Widget _probeLine(int i, List<String> productNames) {
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
                child: Text(
                  'Probe ${i + 1}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
          options: productNames,
          pickTitle: 'models',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: line.serial,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Serial number',
            hintText: 'Auto if empty',
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

  @override
  Widget build(BuildContext context) {
    final productNames = ref
        .watch(productsProvider)
        .maybeWhen(
          data: (rows) => rows.map((r) => r['name_model'].toString()).toList(),
          orElse: () => const <String>[],
        );
    final batch = _batch;
    final batchLabel = batch == null
        ? 'No current batch'
        : [
            (batch['code'] ?? '').toString(),
            (batch['arrival_date'] ?? '').toString(),
          ].where((s) => s.isNotEmpty).join(' · ');

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
                  'Add batch group',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            batchLabel,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionTitle("What's in this group"),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _toggleChip('Machine', true, null),
                      _toggleChip(
                        'Probe',
                        _withProbe,
                        () => setState(() {
                          _withProbe = !_withProbe;
                          if (_withProbe && _probeLines.isEmpty) {
                            _probeLines.add(_ProbeLine());
                          }
                        }),
                      ),
                      _toggleChip(
                        'Printer',
                        _withPrinter,
                        () => setState(() => _withPrinter = !_withPrinter),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _sectionTitle('Machine'),
                  const SizedBox(height: 8),
                  PickyField(
                    controller: _machineModel,
                    label: 'Model *',
                    options: productNames,
                    pickTitle: 'models',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _machineSerial,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Serial number',
                      hintText: 'Auto if empty',
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
                      labelText: 'Group ID (generated)',
                      hintText: 'e.g. 1U, 2U',
                      suffixIcon: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : const Icon(Icons.lock_outline, size: 18),
                    ),
                  ),
                  if (_withProbe) ...[
                    const SizedBox(height: 16),
                    _sectionTitle(
                      _probeLines.length > 1 ? 'Probes' : 'Probe',
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Text(
                        "Comes with the machine — shares the group's ID and travels with it.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (var i = 0; i < _probeLines.length; i++)
                      _probeLine(i, productNames),
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
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Text(
                        "Comes with the machine — shares the group's ID and travels with it.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    PickyField(
                      controller: _printerModel,
                      label: 'Model *',
                      options: productNames,
                      pickTitle: 'models',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _printerSerial,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Serial number',
                        hintText: 'Auto if empty',
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
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Price paid for the group',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving || _loading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save group'),
          ),
        ],
      ),
    );
  }
}
