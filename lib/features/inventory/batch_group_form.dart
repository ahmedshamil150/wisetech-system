import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Conditions a machine/group can be entered with.
const _machineConditions = ['Good', 'Used', 'Faulty', 'Unknown'];

/// Conditions probes, printers and parts share (same CHECK set in the DB).
const _kitItemConditions = ['Good', 'Used', 'Needs Inspection', 'Damaged'];

/// Opens the one-screen entry for adding stock: a whole batch group
/// (machine + its probes + printer), any of those on its own, or one or
/// more parts. The batch is chosen inside the form, so BATCH-PARTS can be
/// picked for a parts-only entry and BATCH-U for a machine group.
Future<void> showBatchGroupSheet(BuildContext context) {
  return showAppSheet<void>(
    context: context,
    title: 'Add to inventory',
    heightFraction: 0.92,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: const BatchGroupForm(),
    ),
  );
}

/// One probe inside an entry: model, serial and its own condition.
class _ProbeLine {
  final model = TextEditingController();
  final serial = TextEditingController();
  String condition = 'Good';

  void dispose() {
    model.dispose();
    serial.dispose();
  }
}

/// One part inside an entry: name, serial and condition.
class _PartLine {
  final name = TextEditingController();
  final serial = TextEditingController();
  String condition = 'Good';

  void dispose() {
    name.dispose();
    serial.dispose();
  }
}

/// Entry form for batch stock. A machine group is the default; turning the
/// machine off adds a lone probe/printer (optionally attached to an existing
/// machine), and the Part switch adds one or more parts to whichever batch
/// is selected.
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
  final _attachMachineCode = TextEditingController();
  final _notes = TextEditingController();
  final _code = TextEditingController();

  String _machineCondition = 'Good';
  String _printerCondition = 'Good';
  bool _withMachine = true;
  bool _withProbe = true;
  bool _withPrinter = true;
  bool _withPart = false;

  final List<_ProbeLine> _probeLines = [_ProbeLine()];
  final List<_PartLine> _partLines = [];

  int? _batchId;
  InventoryItem? _attachTo;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final c in [
      _machineModel,
      _machineSerial,
      _printerModel,
      _printerSerial,
      _attachMachineCode,
      _notes,
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

  Future<void> _init() async {
    try {
      final current = await ref.read(currentBatchProvider.future);
      _batchId = current?['id'] as int?;
    } catch (_) {
      // Leave the picker empty; the user can choose a batch.
    }
    await _refreshCode();
    if (mounted) setState(() => _loading = false);
  }

  Future<Map<String, dynamic>?> _batchRow() async {
    final rows = await ref.read(batchesProvider.future);
    for (final row in rows) {
      if (row['id'] == _batchId) return row;
    }
    return null;
  }

  /// Regenerates the machine id from the selected batch's letter.
  Future<void> _refreshCode() async {
    String code = '';
    try {
      final batch = await _batchRow();
      final letter = (batch?['letter'] ?? '').toString();
      if (letter.isNotEmpty) {
        code = await suggestedId('machine', letter: letter);
      }
    } catch (_) {
      code = '';
    }
    if (mounted) setState(() => _code.text = code);
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
    if (!_withMachine && !_withProbe && !_withPrinter && !_withPart) {
      showSnack(context, 'Pick at least one item to add.', error: true);
      return;
    }
    final batch = await _batchRow();
    if (batch == null) {
      showSnack(
        context,
        'No batch selected — create one in Records → Batches first.',
        error: true,
      );
      return;
    }
    if (_withMachine) {
      if (_machineModel.text.trim().isEmpty) {
        showSnack(context, 'Machine model is required.', error: true);
        return;
      }
      if (_code.text.trim().isEmpty) {
        showSnack(context, 'The machine ID could not be generated.', error: true);
        return;
      }
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
    if (_withPart) {
      for (var i = 0; i < _partLines.length; i++) {
        if (_partLines[i].name.text.trim().isEmpty) {
          showSnack(
            context,
            _partLines.length == 1
                ? 'Part name is required.'
                : 'Part ${i + 1} name is required.',
            error: true,
          );
          return;
        }
      }
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final batchId = batch['id'] as int;
      final vendorId = batch['vendor_id'] as int?;
      final date = (batch['arrival_date'] ?? '').toString();
      final notes = _notes.text.trim();
      final created = <String>[];

      int? machineRowId;
      String? groupCode;
      String machineLocation = 'Company';
      if (_withMachine) {
        final model = _machineModel.text.trim();
        groupCode = _code.text.trim();
        final (productId, brandId) = await _productFor(model, 'Machine');
        final row = await db
            .from('machines')
            .insert({
              'machine_id': groupCode,
              'model': model,
              'catalog_product_id': productId,
              'batch_id': batchId,
              'vendor_id': ?vendorId,
              if (date.isNotEmpty) 'acquisition_date': date,
              'status': 'In Stock',
              'current_location': 'Company',
              'condition': _machineCondition,
              'image_group_code': groupCode,
              'brand_id': ?brandId,
              if (_machineSerial.text.trim().isNotEmpty)
                'serial_number': _machineSerial.text.trim(),
              if (notes.isNotEmpty) 'notes': notes,
            })
            .select('id')
            .single();
        machineRowId = row['id'] as int;
        machineLocation = 'Company';
        created.add(groupCode);
      } else if (_attachTo != null) {
        machineRowId = _attachTo!.id;
        groupCode = _attachTo!.code;
        machineLocation = _attachTo!.location;
      }

      if (_withProbe) {
        final linked = machineRowId != null;
        for (final line in _probeLines) {
          final model = line.model.text.trim();
          final (productId, brandId) = await _productFor(model, 'Probe');
          final code = linked ? groupCode! : await suggestedId('probe');
          await db.from('probes').insert({
            'internal_id': code,
            'model': model,
            'catalog_product_id': productId,
            'batch_id': batchId,
            'vendor_id': ?vendorId,
            if (date.isNotEmpty) 'acquisition_date': date,
            'status': linked ? 'With Machine' : 'Available',
            'current_location': linked ? machineLocation : 'Company',
            'condition': line.condition,
            if (linked) 'assigned_machine_id': machineRowId,
            // Only a brand-new machine's group is known to own this code.
            if (_withMachine && linked) 'image_group_code': code,
            'brand_id': ?brandId,
            if (line.serial.text.trim().isNotEmpty)
              'serial_number': line.serial.text.trim(),
            if (notes.isNotEmpty) 'notes': notes,
          });
          if (!created.contains(code)) created.add(code);
        }
      }

      if (_withPrinter) {
        final model = _printerModel.text.trim();
        final linked = machineRowId != null;
        final (productId, brandId) = await _productFor(model, 'Printer');
        final code = linked ? groupCode! : await suggestedId('printer');
        await db.from('printers').insert({
          'internal_id': code,
          'name_model': model,
          'catalog_product_id': productId,
          'batch_id': batchId,
          'vendor_id': ?vendorId,
          if (date.isNotEmpty) 'acquisition_date': date,
          'status': linked ? 'With Machine' : 'Available',
          'current_location': linked ? machineLocation : 'Company',
          'condition': _printerCondition,
          if (linked) 'assigned_machine_id': machineRowId,
          if (_withMachine && linked) 'image_group_code': code,
          'brand_id': ?brandId,
          if (_printerSerial.text.trim().isNotEmpty)
            'serial_number': _printerSerial.text.trim(),
          if (notes.isNotEmpty) 'notes': notes,
        });
        if (!created.contains(code)) created.add(code);
      }

      if (_withPart) {
        for (final line in _partLines) {
          final name = line.name.text.trim();
          final (productId, brandId) = await _productFor(name, 'Part');
          final code = await suggestedId('part');
          await db.from('parts').insert({
            'internal_id': code,
            'name_model': name,
            'catalog_product_id': productId,
            'batch_id': batchId,
            'vendor_id': ?vendorId,
            'acquisition_date': date.isEmpty ? null : date,
            'status': 'Available',
            'current_location': 'Company',
            'condition': line.condition,
            'brand_id': ?brandId,
            if (line.serial.text.trim().isNotEmpty)
              'serial_number': line.serial.text.trim(),
            if (notes.isNotEmpty) 'notes': notes,
          });
          created.add(code);
        }
      }

      ref.invalidate(inventoryProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      final shown = created.length > 4
          ? '${created.take(3).join(', ')} +${created.length - 3} more'
          : created.join(', ');
      messenger.showSnackBar(
        SnackBar(content: Text('$shown added to stock.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  Widget _toggleChip(String label, bool selected, VoidCallback onTap) {
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

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
  );

  Widget _label(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 12.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
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

  Widget _partLine(int i, List<String> partNames) {
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
                child: Text(
                  'Part ${i + 1}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
          controller: line.name,
          label: 'Name *',
          hint: 'e.g. CB board',
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
    final products = ref
        .watch(productsProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final productNames = [
      for (final row in products) row['name_model'].toString(),
    ];
    final partNames = [
      for (final row in products)
        if (row['category'] == 'Part') row['name_model'].toString(),
    ];
    final batches = ref
        .watch(batchesProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final machines = ref
        .watch(inventoryProvider)
        .maybeWhen(
          data: (rows) => rows
              .where((item) => item.kind == 'machine' && !item.isSold)
              .toList(),
          orElse: () => const <InventoryItem>[],
        );
    Map<String, dynamic>? batch;
    for (final row in batches) {
      if (row['id'] == _batchId) batch = row;
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
                child: Text(
                  'Add to inventory',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
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
                  _label('Batch'),
                  const SizedBox(height: 6),
                  if (batches.isEmpty)
                    Text(
                      'No batch yet — create one in Records → Batches.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    )
                  else
                    DropdownButtonFormField<int>(
                      key: ValueKey('batch-$_batchId'),
                      initialValue: _batchId,
                      isDense: true,
                      items: [
                        for (final row in batches)
                          DropdownMenuItem(
                            value: row['id'] as int,
                            child: Text(
                              [
                                if ((row['letter'] ?? '').toString().isNotEmpty)
                                  'Batch ${row['letter']}',
                                (row['code'] ?? '').toString(),
                                (row['arrival_date'] ?? '').toString(),
                              ].where((s) => s.isNotEmpty).join(' · '),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _batchId = value;
                          _code.text = '';
                        });
                        _refreshCode();
                      },
                    ),
                  if (batch != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Vendor: '
                        '${((batch['vendors'] as Map?)?['name'] ?? '').toString().isEmpty ? '—' : ((batch['vendors'] as Map?)?['name'] ?? '')}'
                        '  ·  Arrived: ${batch['arrival_date'] ?? '—'}',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _sectionTitle("What's in this entry"),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _toggleChip(
                        'Machine',
                        _withMachine,
                        () => setState(() {
                          _withMachine = !_withMachine;
                          if (_withMachine) {
                            _refreshCode();
                          } else {
                            _code.text = '';
                          }
                        }),
                      ),
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
                      _toggleChip(
                        'Part',
                        _withPart,
                        () => setState(() {
                          _withPart = !_withPart;
                          if (_withPart && _partLines.isEmpty) {
                            _partLines.add(_PartLine());
                          }
                        }),
                      ),
                    ],
                  ),
                  if (_withMachine) ...[
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
                        labelText: 'Machine / group ID (generated)',
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
                  ] else if (_withProbe || _withPrinter) ...[
                    const SizedBox(height: 16),
                    PickyField(
                      controller: _attachMachineCode,
                      label: 'Belongs to machine (optional)',
                      hint: 'e.g. 12T',
                      options: [for (final item in machines) item.code],
                      pickTitle: 'machines',
                      onChanged: (value) {
                        InventoryItem? found;
                        for (final item in machines) {
                          if (item.code.toLowerCase() ==
                              value.trim().toLowerCase()) {
                            found = item;
                          }
                        }
                        if (found?.code != _attachTo?.code) {
                          setState(() => _attachTo = found);
                        }
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _attachTo == null
                            ? 'Leave empty for a standalone item with its own ID.'
                            : 'Probes/printer share ${_attachTo!.code} and travel with it.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (_withProbe) ...[
                    const SizedBox(height: 16),
                    _sectionTitle(
                      _probeLines.length > 1 ? 'Probes' : 'Probe',
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Text(
                        _withMachine
                            ? "Comes with the machine — shares the group's ID and travels with it."
                            : (_attachTo != null
                                ? 'Joins ${_attachTo!.code}.'
                                : 'Standalone probe with its own ID.'),
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
                        _withMachine
                            ? "Comes with the machine — shares the group's ID and travels with it."
                            : (_attachTo != null
                                ? 'Joins ${_attachTo!.code}.'
                                : 'Standalone printer with its own ID.'),
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
                  if (_withPart) ...[
                    const SizedBox(height: 16),
                    _sectionTitle(_partLines.length > 1 ? 'Parts' : 'Part'),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 8),
                      child: Text(
                        'Parts stand on their own and are numbered PART-…',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (var i = 0; i < _partLines.length; i++)
                      _partLine(i, partNames),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _partLines.add(_PartLine())),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add another part'),
                    ),
                  ],
                  const SizedBox(height: 16),
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
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
