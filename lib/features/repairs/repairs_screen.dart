import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';

/// Repair jobs: machines fixed for customers — ours or theirs.
/// Everyone on the team can add and update them.
class RepairsScreen extends ConsumerStatefulWidget {
  const RepairsScreen({super.key});

  @override
  ConsumerState<RepairsScreen> createState() => _RepairsScreenState();
}

const _filters = ['All', 'In repair', 'Sent back'];

class _RepairsScreenState extends ConsumerState<RepairsScreen> {
  String _filter = 'All';
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final repairs = ref.watch(repairsProvider);
    final rows = repairs.maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final counts = <String, int>{'All': 0, 'In repair': 0, 'Sent back': 0};
    for (final row in rows) {
      if (_query.isNotEmpty && !_searchText(row).contains(_query)) continue;
      counts['All'] = counts['All']! + 1;
      if (repairIsOpen('${row['status']}')) {
        counts['In repair'] = counts['In repair']! + 1;
      } else {
        counts['Sent back'] = counts['Sent back']! + 1;
      }
    }

    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            itemCount: _filters.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final label = _filters[index];
              final selected = _filter == label;
              return ChoiceChip(
                label: Text('$label (${counts[label] ?? 0})'),
                selected: selected,
                onSelected: (_) => setState(() => _filter = label),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SearchField(
            hint: 'Search by customer, machine or job number',
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: repairs.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (rows) {
              final filtered = rows.where((row) {
                final open = repairIsOpen('${row['status']}');
                if (_filter == 'In repair' && !open) return false;
                if (_filter == 'Sent back' && open) return false;
                if (_query.isEmpty) return true;
                return _searchText(row).contains(_query);
              }).toList();
              if (filtered.isEmpty) {
                return const EmptyState(
                    icon: Icons.build_outlined,
                    message: 'No repair records yet.');
              }
              return AppRefresh(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) =>
                      _tile(context, filtered[index]),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (sheetContext) => Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                child: const _NewRepairForm(),
              ),
            ),
            icon: const Icon(Icons.add),
            label: const Text('New repair'),
          ),
        ),
      ],
    );
  }

  String _searchText(Map<String, dynamic> row) {
    final parts = [
      '${row['job_number']}',
      '${row['customers'] is Map ? (row['customers'] as Map)['name'] ?? '' : ''}',
      '${row['received_at']}',
      '${row['returned_at'] ?? ''}',
      for (final item in _itemsOf(row))
        '${item['name_model']} ${item['serial_number'] ?? ''} ${item['equipment_type']}',
    ];
    return parts.join(' ').toLowerCase();
  }

  List<Map<String, dynamic>> _itemsOf(Map<String, dynamic> row) =>
      (row['repair_items'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

  Widget _tile(BuildContext context, Map<String, dynamic> row) {
    final open = repairIsOpen('${row['status']}');
    final customer =
        ((row['customers'] as Map?)?['name'] ?? '').toString();
    final items = _itemsOf(row);
    final color = open ? const Color(0xFFB26A00) : const Color(0xFF1B7F4B);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (sheetContext) => SizedBox(
              height: MediaQuery.of(sheetContext).size.height * 0.8,
              child: _RepairDetails(job: row),
            ),
          ),
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(Icons.build_outlined, color: color),
          ),
          title: Text(
              '${row['job_number']}  ·  $customer',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          subtitle: Text([
            'In: ${row['received_at']}',
            open
                ? '${items.length} item(s) with us'
                : 'Back: ${row['returned_at'] ?? '—'}',
          ].join(' · ')),
          trailing: _RepairStatusChip(status: '${row['status']}'),
        ),
      ),
    );
  }
}

class _RepairStatusChip extends StatelessWidget {
  const _RepairStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final open = repairIsOpen(status);
    final color = open ? const Color(0xFFB26A00) : const Color(0xFF1B7F4B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        open ? 'In repair' : 'Sent back',
        style: TextStyle(
            color: color, fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// details + mark as sent back
// ---------------------------------------------------------------------------

class _RepairDetails extends ConsumerWidget {
  const _RepairDetails({required this.job});

  final Map<String, dynamic> job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = repairIsOpen('${job['status']}');
    final customer = ((job['customers'] as Map?)?['name'] ?? '').toString();
    final enteredBy = job['profiles'];
    final enteredName = enteredBy is Map
        ? ((enteredBy['display_name'] ?? enteredBy['username'] ?? '').toString())
        : '';
    final items = (job['repair_items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${job['job_number']}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            _RepairStatusChip(status: '${job['status']}'),
          ],
        ),
        Text(customer, style: const TextStyle(color: kMuted)),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              KeyValue(label: 'Sent by', value: customer),
              KeyValue(
                  label: 'Contact',
                  value: '${job['customer_contact'] ?? '—'}'),
              KeyValue(label: 'Received on', value: '${job['received_at']}'),
              if (enteredName.isNotEmpty)
                KeyValue(label: 'Entered by', value: enteredName),
              if ('${job['problem_description'] ?? ''}'.isNotEmpty)
                KeyValue(
                    label: 'Problem',
                    value: '${job['problem_description']}'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text('Items',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        AppCard(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              for (final item in items)
                ListTile(
                  dense: true,
                  leading: Text(
                    itemKindLabel('${item['equipment_type'] ?? 'other'}'),
                    style: const TextStyle(fontSize: 12, color: kHint),
                  ),
                  title: Text('${item['name_model']}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13.5)),
                  subtitle: '${item['serial_number'] ?? ''}'.isEmpty
                      ? null
                      : Text('${item['serial_number']}'),
                ),
            ],
          ),
        ),
        if (!open) ...[
          const SizedBox(height: 16),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                KeyValue(
                    label: 'Sent back on',
                    value: '${job['returned_at'] ?? '—'}'),
                if ('${job['collected_by'] ?? ''}'.isNotEmpty)
                  KeyValue(label: 'Collected by', value: '${job['collected_by']}'),
                if ('${job['repair_notes'] ?? ''}'.isNotEmpty)
                  KeyValue(label: 'Notes', value: '${job['repair_notes']}'),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (open)
          FilledButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (sheetContext) => Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                child: _SendBackForm(job: job),
              ),
            ),
            icon: const Icon(Icons.done_all),
            label: const Text('Repaired — send it back'),
          ),
      ],
    );
  }
}

class _SendBackForm extends ConsumerStatefulWidget {
  const _SendBackForm({required this.job});

  final Map<String, dynamic> job;

  @override
  ConsumerState<_SendBackForm> createState() => _SendBackFormState();
}

class _SendBackFormState extends ConsumerState<_SendBackForm> {
  final _date = TextEditingController();
  final _collectedBy = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
  }

  @override
  void dispose() {
    for (final c in [_date, _collectedBy, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_date.text.trim().isEmpty) {
      showSnack(context, 'Date sent back is required.', error: true);
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repairSentBack(
        id: widget.job['id'] as int,
        returnedAt: _date.text.trim(),
        collectedBy: _collectedBy.text.trim(),
        notes: _notes.text.trim(),
      );
      ref.invalidate(repairsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      Navigator.pop(context); // close the details sheet too
      messenger.showSnackBar(SnackBar(
          content: Text('${widget.job['job_number']} sent back.')));
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
                child: Text('Send it back',
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
                  DateField(controller: _date, label: 'Sent back on *'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _collectedBy,
                    decoration: const InputDecoration(
                        labelText: 'Collected by (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration:
                        const InputDecoration(labelText: 'Notes (optional)'),
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
                : const Text('Mark as sent back'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// new repair
// ---------------------------------------------------------------------------

class _RepairLine {
  _RepairLine({required this.type, String model = '', String serial = ''})
      : model = TextEditingController(text: model),
        serial = TextEditingController(text: serial);

  String type;
  final TextEditingController model;
  final TextEditingController serial;

  void dispose() {
    model.dispose();
    serial.dispose();
  }
}

class _NewRepairForm extends ConsumerStatefulWidget {
  const _NewRepairForm();

  @override
  ConsumerState<_NewRepairForm> createState() => _NewRepairFormState();
}

class _NewRepairFormState extends ConsumerState<_NewRepairForm> {
  final _customer = TextEditingController();
  final _contact = TextEditingController();
  final _date = TextEditingController();
  final _problem = TextEditingController();
  final List<_RepairLine> _lines = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
  }

  @override
  void dispose() {
    for (final c in [_customer, _contact, _date, _problem]) {
      c.dispose();
    }
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  void _addStockItem(InventoryItem item) {
    setState(() {
      _lines.add(_RepairLine(
        type: item.kind,
        model: '${item.code}  ${item.name}',
        serial: item.serial ?? '',
      ));
    });
  }

  void _addOutsideItem() {
    setState(() => _lines.add(_RepairLine(type: 'machine')));
  }

  Future<void> _save() async {
    if (_customer.text.trim().isEmpty) {
      showSnack(context, 'Name of the person who sent it is required.',
          error: true);
      return;
    }
    if (_lines.isEmpty) {
      showSnack(context, 'Add the machine (and its probes, printer).',
          error: true);
      return;
    }
    final items = <Map<String, dynamic>>[];
    for (final line in _lines) {
      final model = line.model.text.trim();
      if (model.isEmpty) {
        showSnack(context, 'Every item needs a model.', error: true);
        return;
      }
      items.add({
        'type': line.type,
        'model': model,
        if (line.serial.text.trim().isNotEmpty)
          'serial': line.serial.text.trim(),
      });
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await createRepair(
        customerName: _customer.text.trim(),
        contact: _contact.text.trim(),
        receivedAt: _date.text.trim(),
        problem: _problem.text.trim(),
        items: items,
      );
      ref.invalidate(repairsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger
          .showSnackBar(SnackBar(content: Text('Repair recorded for ${_customer.text.trim()}.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customerNames = ref.watch(customersProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );
    final stock = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
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
                child: Text('New repair',
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
                  PickyField(
                    controller: _customer,
                    label: 'Sent by *',
                    hint: 'Name of the customer or person',
                    options: customerNames,
                    pickTitle: 'customers',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                          child: TextField(
                        controller: _contact,
                        keyboardType: TextInputType.phone,
                        decoration:
                            const InputDecoration(labelText: 'Contact'),
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                          child: DateField(
                              controller: _date, label: 'Received on *')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _problem,
                    maxLines: 2,
                    decoration: const InputDecoration(
                        labelText: 'Problem (optional)'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Items *',
                            style: TextStyle(fontSize: 13, color: kMuted)),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final picked =
                              await showPickItem(context, items: stock);
                          if (picked != null) _addStockItem(picked);
                        },
                        icon: const Icon(Icons.inventory_2_outlined, size: 18),
                        label: const Text('Our stock'),
                      ),
                      TextButton.icon(
                        onPressed: _addOutsideItem,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Outside'),
                      ),
                    ],
                  ),
                  if (_lines.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          'Add the machine — plus its probes and printer.',
                          style: TextStyle(color: kHint, fontSize: 13)),
                    )
                  else
                    for (var index = 0; index < _lines.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _lineCard(index),
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

  Widget _lineCard(int index) {
    final line = _lines[index];
    final productRows = ref.watch(productsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    // the line's type decides which models are offered — an "other"
    // line can be anything
    final category = switch (line.type) {
      'machine' => 'Machine',
      'probe' => 'Probe',
      'printer' => 'Printer',
      _ => null,
    };
    final models = [
      for (final row in productRows)
        if (category == null || '${row['category']}' == category)
          '${row['name_model']}',
    ];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('repair-type-$index-${line.type}'),
                  initialValue: line.type,
                  isDense: true,
                  items: const [
                    'machine',
                    'probe',
                    'printer',
                    'other',
                  ]
                      .map((t) => DropdownMenuItem(
                          value: t, child: Text(itemKindLabel(t))))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => line.type = value ?? 'machine'),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  line.dispose();
                  setState(() => _lines.removeAt(index));
                },
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: PickyField(
                  controller: line.model,
                  label: 'Model',
                  hint: 'Start typing — suggestions appear',
                  options: models,
                  pickTitle: 'models',
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 130,
                child: TextField(
                  controller: line.serial,
                  decoration: const InputDecoration(
                      labelText: 'Serial', isDense: true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
