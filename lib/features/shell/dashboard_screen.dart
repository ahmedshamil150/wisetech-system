import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../inventory/inventory_screen.dart';
import '../movements/movements_screen.dart';
import '../sales/sales_screen.dart';
import 'dashboard_stats.dart';
import 'navigation_providers.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  /// The window every number on the page counts — the running month
  /// until another period is picked.
  DashPeriod _period = dashThisMonth();
  String _batch = '';

  // Derived maps are rebuilt only when the data behind them changes,
  // so a tab switch or a scroll does not redo the whole join.
  List<InventoryItem>? _batchSource;
  Map<String, String> _batchByItemCache = const {};
  List<Map<String, dynamic>>? _entriesSalesSource;
  List<Map<String, dynamic>>? _entriesMovementsSource;
  Map<String, String>? _entriesLabelsSource;
  List<SaleEntry>? _entriesCache;

  List<Map<String, dynamic>>? _statsMovementsSource;
  List<SaleEntry>? _statsEntriesSource;
  List<Map<String, dynamic>>? _statsRepairsSource;
  Map<String, String>? _statsBatchSource;
  String _statsKey = '';
  DashStats? _statsCache;

  Map<String, String> _batchByItemFor(List<InventoryItem> items) {
    if (!identical(items, _batchSource)) {
      _batchSource = items;
      _batchByItemCache = {
        for (final item in items) item.key: item.batch ?? '',
      };
    }
    return _batchByItemCache;
  }

  List<SaleEntry> _entriesFor(List<Map<String, dynamic>> salesRows,
      List<Map<String, dynamic>> movementRows, Map<String, String> labels) {
    if (identical(salesRows, _entriesSalesSource) &&
        identical(movementRows, _entriesMovementsSource) &&
        identical(labels, _entriesLabelsSource)) {
      return _entriesCache!;
    }
    _entriesSalesSource = salesRows;
    _entriesMovementsSource = movementRows;
    _entriesLabelsSource = labels;
    return _entriesCache = mergeSaleEntries(
      salesRows: salesRows,
      movementRows: movementRows,
      labels: labels,
    );
  }

  DashStats _statsFor(
      {required List<Map<String, dynamic>> movementRows,
      required List<SaleEntry> saleEntries,
      required List<Map<String, dynamic>> repairRows,
      required Map<String, String> batchByItem}) {
    final key = '${_period.from?.toIso8601String()}|'
        '${_period.to?.toIso8601String()}|$_batch';
    if (identical(movementRows, _statsMovementsSource) &&
        identical(saleEntries, _statsEntriesSource) &&
        identical(repairRows, _statsRepairsSource) &&
        identical(batchByItem, _statsBatchSource) &&
        key == _statsKey) {
      return _statsCache!;
    }
    _statsMovementsSource = movementRows;
    _statsEntriesSource = saleEntries;
    _statsRepairsSource = repairRows;
    _statsBatchSource = batchByItem;
    _statsKey = key;
    return _statsCache = computeDashStats(
      movementRows: movementRows,
      saleEntries: saleEntries,
      repairRows: repairRows,
      batchByItem: batchByItem,
      period: _period,
      batch: _batch,
      includeRepairs: _batch.isEmpty,
    );
  }

  Future<void> _pickPeriod() async {
    final picked = await showAppSheet<DashPeriod>(
      context: context,
      title: 'Period',
      heightFraction: 0.8,
      builder: (_) => _PeriodSheet(current: _period),
    );
    if (picked != null) setState(() => _period = picked);
  }

  Future<void> _pickBatch(List<({String code, String label})> options) async {
    final picked = await showAppSheet<String>(
      context: context,
      title: 'Batch',
      builder: (_) => _BatchSheet(options: options, selected: _batch),
    );
    if (picked != null) setState(() => _batch = picked);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider);
    final name = profile.maybeWhen(
          data: (p) => (p?['display_name'] ?? p?['username'] ?? '') as String,
          orElse: () => '',
        );
    final scheme = Theme.of(context).colorScheme;
    final myId = ref.read(authControllerProvider).currentUser?.id;
    final inRepair = ref.watch(openRepairsCountProvider);

    final inventoryItems = ref.watch(inventoryProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <InventoryItem>[],
        );
    final allItems = ref.watch(allItemsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => inventoryItems,
        );
    final batchByItem = _batchByItemFor(allItems);
    final batchRows = ref.watch(batchesProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final batchOptions = <({String code, String label})>[
      (code: '', label: 'All batches'),
      for (final row in batchRows)
        (
          code: '${row['code']}',
          label: row['letter'] == null
              ? '${row['code']}'
              : '${row['letter']} · ${row['code']}',
        ),
      (code: 'BATCH-OLD', label: 'Old stock · BATCH-OLD'),
    ];

    final movementRows = ref.watch(movementsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final allMovementRows = ref.watch(allMovementsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final labels = ref.watch(itemLabelsProvider);
    final salesRows = ref.watch(allSalesProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final saleEntries =
        _entriesFor(salesRows, allMovementRows, labels);
    final repairRows = ref.watch(repairsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );

    final stats = _statsFor(
      movementRows: movementRows,
      saleEntries: saleEntries,
      repairRows: repairRows,
      batchByItem: batchByItem,
    );

    // stock is a snapshot of now — the period never narrows it
    final stock = _batch.isEmpty
        ? inventoryItems
        : [
            for (final item in allItems)
              if (item.batch == _batch) item,
          ];
    int stockCount(bool Function(InventoryItem) test) =>
        stock.where(test).length;
    final stockCards = <(String, IconData, String, String)>[
      (
        'In stock',
        Icons.inventory_2_outlined,
        '${stockCount((i) => i.status == 'In Stock' || i.status == 'Available')}',
        'In Stock'
      ),
      (
        'With workshop',
        Icons.build_outlined,
        '${stockCount((i) => i.status == 'With Workshop')}',
        'With Workshop'
      ),
      (
        'With branch',
        Icons.storefront_outlined,
        '${stockCount((i) => i.status == 'With Branch')}',
        'With Branch'
      ),
      (
        'With dealer',
        Icons.handshake_outlined,
        '${stockCount((i) => i.status == 'With Dealer')}',
        'With Dealer'
      ),
      (
        'With customer',
        Icons.person_outline,
        '${stockCount((i) => i.status == 'With Customer')}',
        'With Customer'
      ),
      if (_batch.isEmpty)
        ('In repair', Icons.handyman_outlined, '$inRepair', 'repairs'),
    ];

    // sends recorded without a dealer/customer name — mine only
    final missingMine = movementRows
        .where((row) =>
            movementPartyMissing(row) && row['actor_id'] == myId)
        .toList();
    final missingSends = missingMine
        .map((row) =>
            ((row['group_ref'] ?? '').toString().isNotEmpty
                    ? row['group_ref']
                    : row['id'])
                .toString())
        .toSet()
        .length;

    final desktop = isDesktopLayout(context);
    final batchLabel = _batch.isEmpty
        ? 'All batches'
        : _batchShortLabel(_batch, batchRows);

    return AppRefresh(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(desktop ? 24 : 16),
        children: [
          Text(
            name.isEmpty ? 'Welcome' : 'Welcome, $name',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickPeriod,
                  icon: const Icon(Icons.calendar_month_outlined, size: 18),
                  label: Text(_period.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickBatch(batchOptions),
                  icon: const Icon(Icons.layers_outlined, size: 18),
                  label: Text(batchLabel,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text('This period · ${_period.label}',
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: desktop ? 4 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: desktop ? 1.55 : 1.2,
            children: [
              _StatCard(
                label: 'Sales',
                value: saleAmountText(stats.salesAmount),
                sub: stats.salesCount == 1
                    ? '1 sale'
                    : '${stats.salesCount} sales',
                icon: Icons.sell_outlined,
                onTap: () => ref.read(shellTabProvider.notifier).set(3),
              ),
              _StatCard(
                label: 'Sent out',
                value: '${stats.sendCount}',
                sub: stats.itemCount == 1
                    ? '1 item'
                    : '${stats.itemCount} items',
                icon: Icons.swap_horiz_outlined,
                onTap: () => ref.read(shellTabProvider.notifier).set(2),
              ),
              _StatCard(
                label: 'Returned',
                value: '${stats.returnedBack}',
                sub: stats.returnedItems == 1
                    ? '1 return recorded'
                    : '${stats.returnedItems} returns recorded',
                icon: Icons.assignment_return_outlined,
                onTap: () => ref.read(shellTabProvider.notifier).set(2),
              ),
              if (_batch.isEmpty)
                _StatCard(
                  label: 'Repairs in',
                  value: '${stats.repairsReceived}',
                  sub: stats.repairsReceived == 0
                      ? 'None received'
                      : '${stats.repairsReturnedOfReceived} back · '
                          '${stats.repairsReceived - stats.repairsReturnedOfReceived} '
                          'still here',
                  icon: Icons.handyman_outlined,
                  onTap: () => ref.read(shellTabProvider.notifier).set(4),
                ),
            ],
          ),
          if (_batch.isEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final kind in const [
                  'Workshop',
                  'Branch',
                  'Dealer',
                  'Customer'
                ])
                  if ((stats.sendsByKind[kind] ?? 0) > 0)
                    _CountChip(
                      label: kind,
                      value: '${stats.sendsByKind[kind]}',
                    ),
                if (stats.repairsBack > 0)
                  _CountChip(
                    label: 'Repairs given back',
                    value: '${stats.repairsBack}',
                  ),
                if (stats.repairsMoney > 0)
                  _CountChip(
                    label: 'Repair money',
                    value: saleAmountText(stats.repairsMoney),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          const Text('Right now',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: desktop ? 4 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: [
              for (final (label, icon, value, target) in stockCards)
                AppCard(
                  onTap: () => openStat(ref, target),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 22, color: scheme.primary),
                        const SizedBox(height: 8),
                        Text(label,
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 2),
                        Text(value,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (missingSends > 0) ...[
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: context.colors.warningContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: context.colors.warningBorder),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: kAmber, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$missingSends send${missingSends == 1 ? '' : 's'} '
                            'without a name',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonal(
                      onPressed: () =>
                          showAddPartySheet(context, ref, missingMine),
                      child: const Text('Add now'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _batchShortLabel(
    String code, List<Map<String, dynamic>> rows) {
  if (code.isEmpty) return 'All batches';
  if (code == 'BATCH-OLD') return 'Old stock';
  for (final row in rows) {
    if ('${row['code']}' == code) {
      return '${row['letter'] ?? code}';
    }
  }
  return code;
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    this.onTap,
  });

  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: scheme.primary),
            const SizedBox(height: 8),
            Text(label,
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.colors.quietFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('$label $value',
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
    );
  }
}

/// Period picker: quick windows, any month, or a typed From–To range.
class _PeriodSheet extends StatefulWidget {
  const _PeriodSheet({required this.current});

  final DashPeriod current;

  @override
  State<_PeriodSheet> createState() => _PeriodSheetState();
}

class _PeriodSheetState extends State<_PeriodSheet> {
  final _from = TextEditingController();
  final _to = TextEditingController();
  late int _monthValue;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _monthValue = now.year * 100 + now.month;
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final months = <int>[];
    var month = DateTime(now.year, now.month, 1);
    for (var i = 0; i < 24; i++) {
      months.add(month.year * 100 + month.month);
      month = DateTime(month.year, month.month - 1, 1);
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              label: const Text('This month'),
              onPressed: () => Navigator.pop(context, dashThisMonth()),
            ),
            ActionChip(
              label: const Text('Last month'),
              onPressed: () => Navigator.pop(context, dashLastMonth()),
            ),
            ActionChip(
              label: Text('${now.year}'),
              onPressed: () => Navigator.pop(context, dashThisYear()),
            ),
            ActionChip(
              label: const Text('All time'),
              onPressed: () => Navigator.pop(context, dashAllTime),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('A month',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _monthValue,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Month'),
                items: [
                  for (final value in months)
                    DropdownMenuItem(
                      value: value,
                      child: Text(
                          dashMonthLabel(value ~/ 100, value % 100)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _monthValue = value);
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                dashMonthPeriod(_monthValue ~/ 100, _monthValue % 100),
              ),
              child: const Text('Show'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Any dates',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        DateField(controller: _from, label: 'From'),
        const SizedBox(height: 10),
        DateField(controller: _to, label: 'To'),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(_error,
              style: TextStyle(fontSize: 12, color: scheme.error)),
        ],
        const SizedBox(height: 10),
        FilledButton.tonal(
          onPressed: () {
            final period = dashCustomPeriod(_from.text, _to.text);
            if (period == null) {
              setState(() => _error = 'Type both dates as DD-MM-YYYY.');
              return;
            }
            Navigator.pop(context, period);
          },
          child: const Text('Show these dates'),
        ),
        const SizedBox(height: 8),
        Text('Now showing: ${widget.current.label}',
            style: TextStyle(fontSize: 12, color: scheme.outline)),
      ],
    );
  }
}

/// Batch picker — all batches, one current batch, or the old stock.
class _BatchSheet extends StatelessWidget {
  const _BatchSheet({required this.options, required this.selected});

  final List<({String code, String label})> options;
  final String selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        for (final option in options)
          ListTile(
            leading: Icon(
              option.code.isEmpty
                  ? Icons.layers_outlined
                  : Icons.inventory_2_outlined,
              size: 20,
              color: scheme.primary,
            ),
            title: Text(option.label,
                style: const TextStyle(fontSize: 14)),
            trailing: option.code == selected
                ? Icon(Icons.check, size: 20, color: scheme.primary)
                : null,
            onTap: () => Navigator.pop(context, option.code),
          ),
      ],
    );
  }
}

/// A stat card was tapped — open the page it counts, pre-filtered.
void openStat(WidgetRef ref, String target) {
  if (target == 'repairs') {
    ref.read(shellTabProvider.notifier).set(4);
    return;
  }
  ref.read(inventoryStatusFilterProvider.notifier).set(target);
  ref.read(shellTabProvider.notifier).set(1);
}
