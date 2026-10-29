import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../common/flag_sheet.dart';
import '../common/pickers.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../../core/layout.dart';
import 'repair_filters.dart';

/// Repair jobs: machines fixed for customers — ours or theirs.
/// Everyone on the team can add and update them.
class RepairsScreen extends ConsumerStatefulWidget {
  const RepairsScreen({super.key});

  @override
  ConsumerState<RepairsScreen> createState() => _RepairsScreenState();
}

const _quickFilters = ['All', 'In repair', 'Sent back', 'Cancelled'];

class _RepairsScreenState extends ConsumerState<RepairsScreen> {
  RepairFilter _filter = defaultRepairFilter;

  RepairFilter _change({
    String? query,
    String? state,
    String? itemType,
    String? money,
    String? dateFrom,
    String? dateTo,
    bool? flaggedOnly,
  }) =>
      (
        query: query ?? _filter.query,
        state: state ?? _filter.state,
        itemType: itemType ?? _filter.itemType,
        money: money ?? _filter.money,
        dateFrom: dateFrom ?? _filter.dateFrom,
        dateTo: dateTo ?? _filter.dateTo,
        flaggedOnly: flaggedOnly ?? _filter.flaggedOnly,
      );

  void _clearSheetFilters() {
    setState(() => _filter = _change(
          state: 'All',
          itemType: 'All',
          money: 'All',
          dateFrom: '',
          dateTo: '',
          flaggedOnly: false,
        ));
  }

  Future<void> _openFilters() async {
    final result = await showAppSheet<RepairFilter>(
      context: context,
      title: 'Filter repairs',
      heightFraction: 0.85,
      builder: (sheetContext) => _RepairsFilterSheet(initial: _filter),
    );
    if (result == null) return;
    setState(() => _filter = result);
  }

  Set<int> _flaggedRepairIds() {
    final flags = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    return {
      for (final flag in flags)
        if (flag['repair_id'] is int) flag['repair_id'] as int,
    };
  }

  @override
  Widget build(BuildContext context) {
    final repairs = ref.watch(repairsProvider);
    final flaggedIds = _flaggedRepairIds();
    final scheme = Theme.of(context).colorScheme;
    final active = repairFilterCount(_filter);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: SearchField(
                  hint: 'Search customer, job number, model or serial',
                  onChanged: (value) => setState(
                      () => _filter = _change(query: value.trim().toLowerCase())),
                ),
              ),
              const SizedBox(width: 8),
              if (isPhoneLayout(context))
                IconButton(
                  tooltip: 'Filters',
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: active > 0,
                    label: Text('$active'),
                    child: const Icon(Icons.filter_list, size: 22),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: active > 0,
                    label: Text('$active'),
                    child: const Icon(Icons.filter_list, size: 20),
                  ),
                  label: const Text('Filters'),
                ),
              if (active > 0)
                IconButton(
                  tooltip: 'Clear filters',
                  icon: Icon(Icons.close, size: 20, color: scheme.error),
                  onPressed: _clearSheetFilters,
                ),
            ],
          ),
        ),
        repairs.maybeWhen(
          data: (rows) => SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              itemCount: _quickFilters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final label = _quickFilters[index];
                final selected = _filter.state == label;
                final count = filterRepairJobs(
                  rows,
                  filter: _change(state: label),
                  flaggedIds: flaggedIds,
                ).length;
                return ChoiceChip(
                  label: Text('$label ($count)'),
                  selected: selected,
                  onSelected: (_) =>
                      setState(() => _filter = _change(state: label)),
                  selectedColor: scheme.primary,
                  labelStyle: TextStyle(
                    color: selected ? Colors.white : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  backgroundColor:
                      context.colors.isDark ? context.colors.quietFill : scheme.surface,
                  side: BorderSide(color: scheme.outlineVariant),
                );
              },
            ),
          ),
          orElse: () => const SizedBox(height: 10),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: repairs.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => EmptyState(
                      icon: Icons.error_outline,
                      message: errorMessage(error)),
                  data: (rows) {
                    final filtered = filterRepairJobs(
                      rows,
                      filter: _filter,
                      flaggedIds: flaggedIds,
                    );
                    if (rows.isEmpty) {
                      return const EmptyState(
                          icon: Icons.build_outlined,
                          message: 'No repair jobs recorded yet.');
                    }
                    if (filtered.isEmpty) {
                      return const EmptyState(
                          icon: Icons.filter_alt_off_outlined,
                          message: 'Nothing matches these filters.');
                    }
                    return AppRefresh(
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 84),
                        itemCount: filtered.length + 1,
                        itemBuilder: (context, index) {
                          if (index == filtered.length) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Center(
                                child: Text(
                                  '${filtered.length} repair'
                                  '${filtered.length == 1 ? '' : 's'}',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: scheme.onSurfaceVariant),
                                ),
                              ),
                            );
                          }
                          return _tile(context, filtered[index]);
                        },
                      ),
                    );
                  },
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: AppFab(
                  tooltip: 'New repair',
                  onPressed: () => showAppSheet<void>(
                    context: context,
                    title: 'New repair',
                    heightFraction: 0.92,
                    builder: (sheetContext) => Padding(
                      padding: EdgeInsets.only(
                          bottom:
                              MediaQuery.of(sheetContext).viewInsets.bottom),
                      child: const _NewRepairForm(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> job) {
    final scheme = Theme.of(context).colorScheme;
    final state = repairStateOf(job['status']);
    final customer =
        ((job['customers'] as Map?)?['name'] ?? '').toString().trim();
    final items = repairJobItems(job);
    final cost = _amountText(job['final_cost']);
    final estimate = _amountText(job['estimated_cost']);
    final received = _amountText(job['money_received']);
    final color = switch (state) {
      'In repair' => context.colors.warning,
      'Sent back' => context.colors.success,
      _ => scheme.outline,
    };
    final models = [
      for (final item in items)
        if ('${item['name_model'] ?? ''}'.trim().isNotEmpty)
          '${item['name_model']}'.trim(),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        onTap: () => showAppSheet<void>(
          context: context,
          title: '${job['job_number']}  ·  $customer',
          heightFraction: 0.9,
          builder: (sheetContext) => _RepairDetails(job: job),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 19,
                    backgroundColor: color.withValues(alpha: 0.12),
                    child: Icon(Icons.build_outlined, size: 19, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            FlagDot(
                                targetKey:
                                    flagRepairKey(job['id'] as int)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text('${job['job_number']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          customer.isEmpty ? 'Customer not recorded' : customer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _RepairStatusChip(status: '${job['status']}'),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _InfoTag(
                    icon: Icons.event_available_outlined,
                    text: 'In ${job['received_at']}',
                  ),
                  if (state == 'Sent back')
                    _InfoTag(
                      icon: Icons.assignment_turned_in_outlined,
                      text: 'Back ${job['returned_at'] ?? '—'}',
                    ),
                  _InfoTag(
                    icon: Icons.inventory_2_outlined,
                    text: '${items.length} item'
                        '${items.length == 1 ? '' : 's'}',
                  ),
                  // what the repair was charged: the final cost once it
                  // is agreed, the estimate until then
                  if (cost.isNotEmpty)
                    _InfoTag(
                        icon: Icons.request_quote_outlined, text: 'Cost $cost')
                  else if (estimate.isNotEmpty)
                    _InfoTag(
                        icon: Icons.request_quote_outlined,
                        text: 'Est. $estimate'),
                  if (received.isNotEmpty)
                    _InfoTag(
                        icon: Icons.payments_outlined,
                        text: 'Received $received'),
                ],
              ),
              if (models.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  models,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "5000" for whole amounts, "5000.5" for the rest, '' for nothing.
String _amountText(Object? raw) {
  final value = raw == null ? null : double.tryParse('$raw');
  if (value == null) return '';
  return value == value.roundToDouble() ? value.toInt().toString() : '$value';
}

class _InfoTag extends StatelessWidget {
  const _InfoTag({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.colors.quietFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12.5, color: scheme.outline),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.top = 16});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 6, left: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}

class _RepairStatusChip extends StatelessWidget {
  const _RepairStatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final state = repairStateOf(status);
    final scheme = Theme.of(context).colorScheme;
    final color = switch (state) {
      'In repair' => context.colors.warning,
      'Sent back' => context.colors.success,
      _ => scheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        state,
        style: TextStyle(
            color: color, fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// filters
// ---------------------------------------------------------------------------

/// Every filter the repairs list understands: state, item kind, whether
/// money came back, the received-date range and flagged jobs.
class _RepairsFilterSheet extends StatefulWidget {
  const _RepairsFilterSheet({required this.initial});

  final RepairFilter initial;

  @override
  State<_RepairsFilterSheet> createState() => _RepairsFilterSheetState();
}

class _RepairsFilterSheetState extends State<_RepairsFilterSheet> {
  late final TextEditingController _from;
  late final TextEditingController _to;
  late String _state;
  late String _itemType;
  late String _money;
  late bool _flaggedOnly;

  static const _states = ['All', 'In repair', 'Sent back', 'Cancelled'];
  static const _itemTypes = {
    'All': 'All items',
    'machine': 'Machines',
    'probe': 'Probes',
    'printer': 'Printers',
    'other': 'Other items',
  };
  static const _moneyOptions = ['All', 'Received', 'Not received'];

  @override
  void initState() {
    super.initState();
    _from = TextEditingController(text: widget.initial.dateFrom);
    _to = TextEditingController(text: widget.initial.dateTo);
    _state = widget.initial.state;
    _itemType = widget.initial.itemType;
    _money = widget.initial.money;
    _flaggedOnly = widget.initial.flaggedOnly;
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.pop(context, (
      query: widget.initial.query,
      state: _state,
      itemType: _itemType,
      money: _money,
      dateFrom: _from.text.trim(),
      dateTo: _to.text.trim(),
      flaggedOnly: _flaggedOnly,
    ));
  }

  void _reset() {
    setState(() {
      _state = 'All';
      _itemType = 'All';
      _money = 'All';
      _flaggedOnly = false;
      _from.clear();
      _to.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Filter repairs',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(onPressed: _reset, child: const Text('Reset')),
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
                  const _SectionTitle('Received between', top: 8),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DateField(controller: _from, label: 'From date'),
                        const SizedBox(height: 14),
                        DateField(controller: _to, label: 'To date'),
                      ],
                    ),
                  ),
                  const _SectionTitle('Show'),
                  DropdownButtonFormField<String>(
                    initialValue: _state,
                    decoration: const InputDecoration(labelText: 'Repairs'),
                    items: [
                      for (final value in _states)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value == 'All' ? 'All repairs' : value),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _state = value ?? 'All'),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _itemType,
                    decoration: const InputDecoration(labelText: 'Item type'),
                    items: [
                      for (final option in _itemTypes.entries)
                        DropdownMenuItem(
                            value: option.key, child: Text(option.value)),
                    ],
                    onChanged: (value) =>
                        setState(() => _itemType = value ?? 'All'),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _money,
                    decoration: const InputDecoration(labelText: 'Money'),
                    items: [
                      for (final value in _moneyOptions)
                        DropdownMenuItem(
                          value: value,
                          child: Text(switch (value) {
                            'All' => 'Any',
                            'Received' => 'Money received',
                            _ => 'No money recorded',
                          }),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => _money = value ?? 'All'),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Flagged only',
                        style: TextStyle(fontSize: 14)),
                    value: _flaggedOnly,
                    onChanged: (value) =>
                        setState(() => _flaggedOnly = value),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _apply, child: const Text('Apply filters')),
        ],
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
    final scheme = Theme.of(context).colorScheme;
    final state = repairStateOf(job['status']);
    final open = state == 'In repair';
    final customer = ((job['customers'] as Map?)?['name'] ?? '').toString();
    final enteredBy = job['profiles'];
    final enteredName = enteredBy is Map
        ? ((enteredBy['display_name'] ?? enteredBy['username'] ?? '').toString())
        : '';
    final items = repairJobItems(job);
    final isAdmin = ref.watch(isAdminProvider);
    final flags = ref.watch(flagsProvider).maybeWhen(
        data: (value) => value, orElse: () => const <Map<String, dynamic>>[]);
    final jobFlags =
        flagIndex(flags)[flagRepairKey(job['id'] as int)] ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${job['job_number']}',
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    customer.isEmpty ? 'Customer not recorded' : customer,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _RepairStatusChip(status: '${job['status']}'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => showAppSheet<void>(
                context: context,
                title: 'Edit ${job['job_number']}',
                heightFraction: 0.95,
                builder: (sheetContext) => Padding(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                  child: _EditRepairForm(job: job),
                ),
              ),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit job'),
            ),
          ],
        ),
        const _SectionTitle('Customer & dates'),
        AppCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              KeyValue(label: 'Sent by', value: customer.isEmpty ? '—' : customer),
              KeyValue(
                  label: 'Contact',
                  value: '${job['customer_contact'] ?? '—'}'),
              KeyValue(label: 'Received on', value: '${job['received_at']}'),
              if ('${job['delivered_by'] ?? ''}'.isNotEmpty)
                KeyValue(label: 'Delivered by', value: '${job['delivered_by']}'),
              if (enteredName.isNotEmpty)
                KeyValue(label: 'Entered by', value: enteredName),
            ],
          ),
        ),
        if ('${job['problem_description'] ?? ''}'.isNotEmpty ||
            '${job['accessories_received'] ?? ''}'.isNotEmpty ||
            '${job['condition_on_arrival'] ?? ''}'.isNotEmpty ||
            '${job['repair_notes'] ?? ''}'.isNotEmpty) ...[
          const _SectionTitle('Problem & condition'),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
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
                if ('${job['repair_notes'] ?? ''}'.isNotEmpty)
                  KeyValue(
                      label: 'Repair notes',
                      value: '${job['repair_notes']}'),
              ],
            ),
          ),
        ],
        if (job['estimated_cost'] != null ||
            job['final_cost'] != null ||
            repairMoneyText(job).isNotEmpty) ...[
          const _SectionTitle('Cost'),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                if (job['estimated_cost'] != null)
                  KeyValue(
                      label: 'Estimated',
                      value: '${job['estimated_cost']}'),
                if (job['final_cost'] != null)
                  KeyValue(
                      label: 'Final cost', value: '${job['final_cost']}'),
                if (repairMoneyText(job).isNotEmpty)
                  KeyValue(
                      label: 'Money received', value: repairMoneyText(job)),
              ],
            ),
          ),
        ],
        _SectionTitle('Items (${items.length})'),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
            child: Text('No items recorded.',
                style: TextStyle(fontSize: 13, color: scheme.outline)),
          ),
        for (final item in items) _itemCard(context, item),
        if (state == 'Sent back') ...[
          const _SectionTitle('Return'),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                KeyValue(
                    label: 'Sent back on',
                    value: '${job['returned_at'] ?? '—'}'),
                if ('${job['collected_by'] ?? ''}'.isNotEmpty)
                  KeyValue(
                      label: 'Collected by',
                      value: '${job['collected_by']}'),
                if ('${job['return_notes'] ?? ''}'.isNotEmpty)
                  KeyValue(
                      label: 'Return notes',
                      value: '${job['return_notes']}'),
              ],
            ),
          ),
        ],
        if (jobFlags.isNotEmpty) ...[
          const _SectionTitle('Flags'),
          AppCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final flag in jobFlags)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: colorFromHex('${flag['color']}'),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
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
        const SizedBox(height: 20),
        if (isAdmin)
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
        if (isAdmin && open) const SizedBox(height: 10),
        if (open)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => showAppSheet<void>(
              context: context,
              title: 'Repaired — send it back',
              heightFraction: 0.85,
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

  Widget _itemCard(BuildContext context, Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    final serial = '${item['serial_number'] ?? ''}'.trim();
    final quantity = (item['quantity'] as num? ?? 1).toInt();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: context.colors.primaryTint,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                itemKindLabel('${item['equipment_type'] ?? 'machine'}'),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: context.colors.brandText),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item['name_model'] ?? ''}',
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                  if (serial.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('Serial $serial',
                          style: TextStyle(
                              fontSize: 12, color: scheme.outline)),
                    ),
                ],
              ),
            ),
            if (quantity > 1)
              Text('×$quantity',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
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
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('Return', top: 8),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DateField(controller: _date, label: 'Sent back on *'),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _collectedBy,
                          decoration: const InputDecoration(
                              labelText: 'Collected by (optional)'),
                        ),
                      ],
                    ),
                  ),
                  const _SectionTitle('Money'),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _money,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Money received (optional)'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _receivedBy,
                          decoration: const InputDecoration(
                              labelText: 'Received by (optional)'),
                        ),
                      ],
                    ),
                  ),
                  const _SectionTitle('Notes'),
                  TextField(
                    controller: _notes,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'What was repaired (optional)'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
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
    final scheme = Theme.of(context).colorScheme;
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Item ${index + 1}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurfaceVariant)),
                ),
                IconButton(
                  tooltip: 'Remove this item',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, size: 18, color: scheme.error),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              key: ValueKey('repair-type-$index-${line.type}'),
              initialValue: line.type,
              decoration: const InputDecoration(labelText: 'Item type'),
              items: const ['machine', 'probe', 'printer', 'other']
                  .map((t) => DropdownMenuItem(
                      value: t, child: Text(itemKindLabel(t))))
                  .toList(),
              onChanged: (value) {
                line.type = value ?? 'machine';
                onChanged();
              },
            ),
            const SizedBox(height: 14),
            PickyField(
              controller: line.model,
              label: 'Model *',
              hint: 'Start typing — suggestions appear',
              options: models,
              pickTitle: 'models',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: line.serial,
              decoration: const InputDecoration(
                labelText: 'Serial number (optional)',
              ),
            ),
          ],
        ),
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
      messenger.showSnackBar(SnackBar(
          content: Text('Repair recorded for ${_customer.text.trim()}.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, errorMessage(error), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final customerNames = ref.watch(customersProvider).maybeWhen(
          data: (rows) => rows.map((r) => r['name'].toString()).toList(),
          orElse: () => const <String>[],
        );
    // both sides of the split: a machine sent to a customer from our
    // stock (current or old-data) can come back for repair
    final stock = ref.watch(allItemsProvider).maybeWhen(
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
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('Who sent it', top: 8),
                  AppCard(
                    padding: const EdgeInsets.all(14),
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
                        const SizedBox(height: 14),
                        TextField(
                          controller: _contact,
                          keyboardType: TextInputType.phone,
                          decoration:
                              const InputDecoration(labelText: 'Contact'),
                        ),
                        const SizedBox(height: 14),
                        DateField(controller: _date, label: 'Received on *'),
                      ],
                    ),
                  ),
                  const _SectionTitle('What is wrong'),
                  TextField(
                    controller: _problem,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Problem (optional)',
                        hintText: 'What did the customer report?'),
                  ),
                  const _SectionTitle('Items *'),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked =
                                await showPickItem(context, items: stock);
                            if (picked != null) _addStockItem(picked);
                          },
                          icon: const Icon(Icons.inventory_2_outlined,
                              size: 18),
                          label: const Text('From our stock'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _addOutsideItem,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Outside item'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_lines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                      child: Text(
                          'Add the machine — plus its probes and printer.',
                          style: TextStyle(
                              color: scheme.outline, fontSize: 13)),
                    )
                  else
                    for (var index = 0; index < _lines.length; index++)
                      _RepairLineCard(
                        index: index,
                        line: _lines[index],
                        onChanged: () => setState(() {}),
                        onRemove: () {
                          _lines[index].dispose();
                          setState(() => _lines.removeAt(index));
                        },
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save repair'),
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
    // both sides of the split — see _NewRepairForm
    final stock = ref.watch(allItemsProvider).maybeWhen(
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
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SectionTitle('Customer & dates', top: 8),
                  AppCard(
                    padding: const EdgeInsets.all(14),
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
                        const SizedBox(height: 14),
                        TextField(
                          controller: _contact,
                          keyboardType: TextInputType.phone,
                          decoration:
                              const InputDecoration(labelText: 'Contact'),
                        ),
                        const SizedBox(height: 14),
                        DateField(controller: _date, label: 'Received on *'),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _deliveredBy,
                          decoration: const InputDecoration(
                              labelText: 'Delivered by (optional)'),
                        ),
                      ],
                    ),
                  ),
                  const _SectionTitle('Problem & condition'),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _problem,
                          maxLines: 2,
                          decoration: const InputDecoration(
                              labelText: 'Problem (optional)'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _accessories,
                          decoration: const InputDecoration(
                              labelText: 'Accessories received (optional)'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _condition,
                          decoration: const InputDecoration(
                              labelText: 'Condition on arrival (optional)'),
                        ),
                      ],
                    ),
                  ),
                  const _SectionTitle('Cost & notes'),
                  AppCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _estimated,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Estimated cost (optional)'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _finalCost,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Final cost (optional)'),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _repairNotes,
                          maxLines: 3,
                          decoration: const InputDecoration(
                              labelText: 'Repair notes (optional)'),
                        ),
                      ],
                    ),
                  ),
                  const _SectionTitle('Status'),
                  DropdownButtonFormField<String>(
                    initialValue: statusOptions.contains(_status)
                        ? _status
                        : 'Received',
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: [
                      for (final value in statusOptions)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (value) =>
                        setState(() => _status = value ?? 'Received'),
                  ),
                  if (returned) ...[
                    const _SectionTitle('Return details'),
                    AppCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DateField(
                              controller: _returnedAt,
                              label: 'Sent back on'),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _collectedBy,
                            decoration: const InputDecoration(
                                labelText: 'Collected by (optional)'),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _returnNotes,
                            maxLines: 2,
                            decoration: const InputDecoration(
                                labelText: 'Return notes (optional)'),
                          ),
                        ],
                      ),
                    ),
                    const _SectionTitle('Money received'),
                    AppCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _money,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Money received (optional)'),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _receivedBy,
                            decoration: const InputDecoration(
                                labelText: 'Received by (optional)'),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const _SectionTitle('Items *'),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picked =
                                await showPickItem(context, items: stock);
                            if (picked != null) {
                              setState(() => _lines.add(_RepairLine(
                                    type: picked.kind,
                                    model: '${picked.code}  ${picked.name}',
                                    serial: picked.serial ?? '',
                                  )));
                            }
                          },
                          icon: const Icon(Icons.inventory_2_outlined,
                              size: 18),
                          label: const Text('From our stock'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => setState(
                              () => _lines.add(_RepairLine(type: 'machine'))),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Outside item'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_lines.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                      child: Text(
                          'A repair needs at least one item — add it back.',
                          style: TextStyle(
                              color: scheme.outline, fontSize: 13)),
                    )
                  else
                    for (var index = 0; index < _lines.length; index++)
                      _RepairLineCard(
                        index: index,
                        line: _lines[index],
                        onChanged: () => setState(() {}),
                        onRemove: () {
                          _lines[index].dispose();
                          setState(() => _lines.removeAt(index));
                        },
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
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
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
