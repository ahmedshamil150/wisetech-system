import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/flag_sheet.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../../core/layout.dart';

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
                  color: selected ? Colors.white : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                backgroundColor: context.colors.isDark
              ? context.colors.quietFill
              : Theme.of(context).colorScheme.surface,
                side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
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
            onPressed: () => showAppSheet<void>(
              context: context,
              title: 'New repair',
              heightFraction: 0.85,
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
    final color = open ? context.colors.warning : context.colors.success;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        child: ListTile(
          onTap: () => showAppSheet<void>(
            context: context,
            title: '${row['job_number']}  ·  $customer',
            heightFraction: 0.8,
            builder: (sheetContext) => _RepairDetails(job: row),
          ),
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(Icons.build_outlined, color: color),
          ),
          title: Row(
            children: [
              FlagDot(targetKey: flagRepairKey(row['id'] as int)),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${row['job_number']}  ·  $customer',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
              ),
            ],
          ),
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
    final color = open ? context.colors.warning : context.colors.success;
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
    // re-read by id so an edit or send-back done while the sheet is open
    // shows up without reopening it
    final rows = ref.watch(repairsProvider).maybeWhen(
          data: (value) => value,
          orElse: () => const <Map<String, dynamic>>[],
        );
    Map<String, dynamic>? live;
    for (final row in rows) {
      if (row['id'] == this.job['id']) {
        live = row;
        break;
      }
    }
    final job = live ?? this.job;
    final open = repairIsOpen('${job['status']}');
    final customer = ((job['customers'] as Map?)?['name'] ?? '').toString();
    final enteredBy = job['profiles'];
    final enteredName = enteredBy is Map
        ? ((enteredBy['display_name'] ?? enteredBy['username'] ?? '').toString())
        : '';
    final items = (job['repair_items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final isAdmin = ref.watch(isAdminProvider);
    final flags = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final jobFlags =
        flagIndex(flags)[flagRepairKey(job['id'] as int)] ?? const [];

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
            TextButton.icon(
              onPressed: () => showAppSheet<void>(
                context: context,
                title: 'Edit ${job['job_number']}',
                heightFraction: 0.9,
                builder: (sheetContext) => Padding(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                  child: _EditRepairForm(job: job),
                ),
              ),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
            ),
            const SizedBox(width: 4),
            _RepairStatusChip(status: '${job['status']}'),
          ],
        ),
        Text(customer, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
              if ('${job['delivered_by'] ?? ''}'.isNotEmpty)
                KeyValue(label: 'Delivered by', value: '${job['delivered_by']}'),
              if (enteredName.isNotEmpty)
                KeyValue(label: 'Entered by', value: enteredName),
              if ('${job['problem_description'] ?? ''}'.isNotEmpty)
                KeyValue(
                    label: 'Problem',
                    value: '${job['problem_description']}'),
              if ('${job['accessories_received'] ?? ''}'.isNotEmpty)
                KeyValue(
                    label: 'Accessories',
                    value: '${job['accessories_received']}'),
              if ('${job['condition_on_arrival'] ?? ''}'.isNotEmpty)
                KeyValue(
                    label: 'Condition',
                    value: '${job['condition_on_arrival']}'),
              if (job['estimated_cost'] != null)
                KeyValue(
                    label: 'Estimated cost',
                    value: '${job['estimated_cost']}'),
              if (job['final_cost'] != null)
                KeyValue(label: 'Final cost', value: '${job['final_cost']}'),
              if (open && '${job['repair_notes'] ?? ''}'.isNotEmpty)
                KeyValue(
                    label: 'Repair notes', value: '${job['repair_notes']}'),
              if (jobFlags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text('Flag',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.outline,
                                fontSize: 13)),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final flag in jobFlags)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(
                                  flagNoteText(flag),
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      color: colorFromHex('${flag['color']}')),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
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
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
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
                if (repairMoneyText(job).isNotEmpty)
                  KeyValue(
                      label: 'Money received',
                      value: repairMoneyText(job)),
                if ('${job['return_notes'] ?? ''}'.isNotEmpty)
                  KeyValue(
                      label: 'Return notes', value: '${job['return_notes']}'),
                if ('${job['repair_notes'] ?? ''}'.isNotEmpty)
                  KeyValue(label: 'Notes', value: '${job['repair_notes']}'),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (isAdmin) ...[
          OutlinedButton.icon(
            onPressed: () => showFlagSheet(
              context,
              ref,
              target: {'repair_id': job['id']},
            ),
            icon: Icon(Icons.flag_outlined,
                size: 18,
                color: jobFlags.isEmpty
                    ? null
                    : colorFromHex('${jobFlags.first['color']}')),
            label: Text(jobFlags.isEmpty
                ? 'Flag this repair'
                : 'Flags (${jobFlags.length})'),
          ),
          const SizedBox(height: 12),
        ],
        if (open)
          FilledButton.icon(
            onPressed: () => showAppSheet<void>(
              context: context,
              title: 'Repaired — send it back',
              heightFraction: 0.8,
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
  final _money = TextEditingController();
  final _receivedBy = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _date.text = DateField.format(DateTime.now());
    // whoever is handing it back usually also takes the money —
    // prefill their own name
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final profile = ref.read(profileProvider).maybeWhen(
            data: (row) => row,
            orElse: () => null,
          );
      final name =
          '${profile?['display_name'] ?? profile?['username'] ?? ''}'.trim();
      if (name.isNotEmpty && _receivedBy.text.trim().isEmpty) {
        _receivedBy.text = name;
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_date, _collectedBy, _notes, _money, _receivedBy]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_date.text.trim().isEmpty) {
      showSnack(context, 'Date sent back is required.', error: true);
      return;
    }
    double? money;
    if (_money.text.trim().isNotEmpty) {
      money = double.tryParse(_money.text.trim());
      if (money == null) {
        showSnack(context, 'Money received must be a number.', error: true);
        return;
      }
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repairSentBack(
        id: widget.job['id'] as int,
        returnedAt: _date.text.trim(),
        collectedBy: _collectedBy.text.trim(),
        notes: _notes.text.trim(),
        moneyReceived: money,
        receivedBy: _receivedBy.text.trim(),
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
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _money,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Money received (optional)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _receivedBy,
                          decoration: const InputDecoration(
                              labelText: 'Received by (optional)'),
                        ),
                      ),
                    ],
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
  _RepairLine(
      {this.id, required this.type, String model = '', String serial = ''})
      : model = TextEditingController(text: model),
        serial = TextEditingController(text: serial);

  /// Database id — set for lines that already exist on the job, null
  /// for a line still being typed.
  final int? id;

  String type;
  final TextEditingController model;
  final TextEditingController serial;

  void dispose() {
    model.dispose();
    serial.dispose();
  }
}

/// One item line's fields — type, model with suggestions, serial, and a
/// remove button. Shared by the new-repair and edit-repair forms.
class _RepairLineCard extends ConsumerWidget {
  const _RepairLineCard({
    required this.index,
    required this.line,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _RepairLine line;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                  onChanged: (value) {
                    line.type = value ?? 'machine';
                    onChanged();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close, size: 18),
                onPressed: onRemove,
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
                      Expanded(
                        child: Text('Items *',
                            style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          'Add the machine — plus its probes and printer.',
                          style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 13)),
                    )
                  else
                    for (var index = 0; index < _lines.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _RepairLineCard(
                          index: index,
                          line: _lines[index],
                          onChanged: () => setState(() {}),
                          onRemove: () {
                            _lines[index].dispose();
                            setState(() => _lines.removeAt(index));
                          },
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

// ---------------------------------------------------------------------------
// edit repair
// ---------------------------------------------------------------------------

/// Full editing for a repair job: who sent it and when, the problem, the
/// accessories and condition on arrival, the costs, notes, the status and
/// the item list. A job that already went back also lets its return
/// details (including the money taken) be corrected. Admins can delete
/// the job from here.
class _EditRepairForm extends ConsumerStatefulWidget {
  const _EditRepairForm({required this.job});

  final Map<String, dynamic> job;

  @override
  ConsumerState<_EditRepairForm> createState() => _EditRepairFormState();
}

class _EditRepairFormState extends ConsumerState<_EditRepairForm> {
  late final TextEditingController _customer;
  late final TextEditingController _contact;
  late final TextEditingController _date;
  late final TextEditingController _deliveredBy;
  late final TextEditingController _problem;
  late final TextEditingController _accessories;
  late final TextEditingController _condition;
  late final TextEditingController _estimated;
  late final TextEditingController _finalCost;
  late final TextEditingController _repairNotes;
  late final TextEditingController _returnedAt;
  late final TextEditingController _collectedBy;
  late final TextEditingController _returnNotes;
  late final TextEditingController _money;
  late final TextEditingController _receivedBy;
  late String _status;
  late final List<_RepairLine> _lines;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final job = widget.job;
    _customer = TextEditingController(
        text: ((job['customers'] as Map?)?['name'] ?? '').toString());
    _contact =
        TextEditingController(text: '${job['customer_contact'] ?? ''}');
    _date = TextEditingController(text: '${job['received_at'] ?? ''}');
    _deliveredBy =
        TextEditingController(text: '${job['delivered_by'] ?? ''}');
    _problem =
        TextEditingController(text: '${job['problem_description'] ?? ''}');
    _accessories = TextEditingController(
        text: '${job['accessories_received'] ?? ''}');
    _condition =
        TextEditingController(text: '${job['condition_on_arrival'] ?? ''}');
    _estimated = TextEditingController(text: _costText(job['estimated_cost']));
    _finalCost = TextEditingController(text: _costText(job['final_cost']));
    _repairNotes =
        TextEditingController(text: '${job['repair_notes'] ?? ''}');
    _returnedAt = TextEditingController(text: '${job['returned_at'] ?? ''}');
    _collectedBy =
        TextEditingController(text: '${job['collected_by'] ?? ''}');
    _returnNotes =
        TextEditingController(text: '${job['return_notes'] ?? ''}');
    _money = TextEditingController(text: _costText(job['money_received']));
    _receivedBy = TextEditingController(
        text: '${job['money_received_by'] ?? ''}');
    _status = '${job['status'] ?? 'Received'}';
    _lines = [
      for (final item in (job['repair_items'] as List? ?? const []))
        _RepairLine(
          id: item['id'] as int?,
          type: '${item['equipment_type'] ?? 'machine'}',
          model: '${item['name_model'] ?? ''}',
          serial: '${item['serial_number'] ?? ''}',
        ),
    ];
  }

  /// "5000" for whole amounts, "5000.5" for the rest, '' for nothing.
  static String _costText(Object? raw) {
    final value = raw == null ? null : double.tryParse('$raw');
    if (value == null) return '';
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : '$value';
  }

  @override
  void dispose() {
    for (final c in [
      _customer,
      _contact,
      _date,
      _deliveredBy,
      _problem,
      _accessories,
      _condition,
      _estimated,
      _finalCost,
      _repairNotes,
      _returnedAt,
      _collectedBy,
      _returnNotes,
      _money,
      _receivedBy,
    ]) {
      c.dispose();
    }
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  double? _number(TextEditingController controller, String label) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null) {
      showSnack(context, '$label must be a number.', error: true);
    }
    return value;
  }

  Future<void> _save() async {
    if (_customer.text.trim().isEmpty) {
      showSnack(context, 'Name of the person who sent it is required.',
          error: true);
      return;
    }
    if (_date.text.trim().isEmpty) {
      showSnack(context, 'Received date is required.', error: true);
      return;
    }
    if (_lines.isEmpty) {
      showSnack(context, 'A repair needs at least one item.', error: true);
      return;
    }
    final estimated = _number(_estimated, 'Estimated cost');
    final finalCost = _number(_finalCost, 'Final cost');
    final money = _number(_money, 'Money received');
    if (!mounted ||
        (estimated == null &&
            _estimated.text.trim().isNotEmpty) ||
        (finalCost == null && _finalCost.text.trim().isNotEmpty) ||
        (money == null && _money.text.trim().isNotEmpty)) {
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
        if (line.id != null) 'id': line.id,
        'type': line.type,
        'model': model,
        if (line.serial.text.trim().isNotEmpty)
          'serial': line.serial.text.trim(),
      });
    }

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await updateRepair(
        id: widget.job['id'] as int,
        customerName: _customer.text.trim(),
        contact: _contact.text.trim(),
        receivedAt: _date.text.trim(),
        problem: _problem.text.trim(),
        deliveredBy: _deliveredBy.text.trim(),
        accessories: _accessories.text.trim(),
        condition: _condition.text.trim(),
        estimatedCost: estimated,
        finalCost: finalCost,
        repairNotes: _repairNotes.text.trim(),
        status: _status,
        returnedAt: _returnedAt.text.trim(),
        collectedBy: _collectedBy.text.trim(),
        returnNotes: _returnNotes.text.trim(),
        moneyReceived: money,
        receivedBy: _receivedBy.text.trim(),
        items: items,
      );
      ref.invalidate(repairsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
          content: Text('${widget.job['job_number']} updated.')));
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
        title: Text('Delete ${widget.job['job_number']}?'),
        content: const Text(
            'This removes the repair job and its items. This cannot be undone.'),
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
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await deleteRepair(widget.job['id'] as int);
      ref.invalidate(repairsProvider);
      if (!mounted) return;
      Navigator.pop(context); // the edit sheet
      Navigator.pop(context); // the details sheet
      messenger.showSnackBar(SnackBar(
          content: Text('${widget.job['job_number']} deleted.')));
    } catch (error) {
      if (!mounted) return;
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final customerNames = ref.watch(customersProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );
    final stock = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    final scheme = Theme.of(context).colorScheme;
    final returned = _status == 'Returned';
    // 'Returned' comes from the send-back flow only — an already returned
    // job keeps it in the list so a save cannot silently reopen it
    final statusOptions = [
      'Received',
      'In repair',
      'Cancelled',
      if (returned) 'Returned',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Edit ${widget.job['job_number']}',
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
                    controller: _deliveredBy,
                    decoration: const InputDecoration(
                        labelText: 'Delivered by (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _problem,
                    maxLines: 2,
                    decoration: const InputDecoration(
                        labelText: 'Problem (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _accessories,
                    decoration: const InputDecoration(
                        labelText: 'Accessories received (optional)'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _condition,
                    decoration: const InputDecoration(
                        labelText: 'Condition on arrival (optional)'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _estimated,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Estimated cost (optional)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _finalCost,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Final cost (optional)'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _repairNotes,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Repair notes (optional)'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: statusOptions.contains(_status)
                        ? _status
                        : 'Received',
                    decoration:
                        const InputDecoration(labelText: 'Status'),
                    items: [
                      for (final value in statusOptions)
                        DropdownMenuItem(
                            value: value, child: Text(value)),
                    ],
                    onChanged: (value) => setState(
                        () => _status = value ?? 'Received'),
                  ),
                  if (returned) ...[
                    const SizedBox(height: 16),
                    Text('Return details',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 8),
                    DateField(
                        controller: _returnedAt, label: 'Sent back on'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _collectedBy,
                      decoration: const InputDecoration(
                          labelText: 'Collected by (optional)'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _money,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Money received (optional)'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _receivedBy,
                            decoration: const InputDecoration(
                                labelText: 'Received by (optional)'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _returnNotes,
                      maxLines: 2,
                      decoration: const InputDecoration(
                          labelText: 'Return notes (optional)'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text('Items *',
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant)),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final picked =
                              await showPickItem(context, items: stock);
                          if (picked != null) {
                            setState(() => _lines.add(_RepairLine(
                                  type: picked.kind,
                                  model:
                                      '${picked.code}  ${picked.name}',
                                  serial: picked.serial ?? '',
                                )));
                          }
                        },
                        icon: const Icon(Icons.inventory_2_outlined,
                            size: 18),
                        label: const Text('Our stock'),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() =>
                            _lines.add(_RepairLine(type: 'machine'))),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Outside'),
                      ),
                    ],
                  ),
                  if (_lines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                          'A repair needs at least one item — add it back.',
                          style: TextStyle(
                              color: scheme.outline, fontSize: 13)),
                    )
                  else
                    for (var index = 0; index < _lines.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _RepairLineCard(
                          index: index,
                          line: _lines[index],
                          onChanged: () => setState(() {}),
                          onRemove: () {
                            _lines[index].dispose();
                            setState(() => _lines.removeAt(index));
                          },
                        ),
                      ),
                  if (isAdmin) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error),
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete this repair'),
                    ),
                  ],
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
                : const Text('Save changes'),
          ),
        ],
      ),
    );
  }
}
