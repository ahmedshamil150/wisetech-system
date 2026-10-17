import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import 'old_data.dart';
import 'old_record_forms.dart';
import 'old_table.dart';

/// Every imported sale with its line items — the receipt history that
/// came in from the old system.
class OldSalesScreen extends ConsumerStatefulWidget {
  const OldSalesScreen({super.key});

  @override
  ConsumerState<OldSalesScreen> createState() => _OldSalesScreenState();
}

class _OldSalesScreenState extends ConsumerState<OldSalesScreen> {
  String _query = '';
  int _page = 0;
  // Filters, all in display form ('' / 'All' = off).
  String _dateFrom = '';
  String _dateTo = '';
  String _buyerType = 'All';
  String _itemType = 'All';
  String _invoicePresence = 'All';

  int get _activeFilterCount {
    var n = 0;
    if (_dateFrom.isNotEmpty) n++;
    if (_dateTo.isNotEmpty) n++;
    if (_buyerType != 'All') n++;
    if (_itemType != 'All') n++;
    if (_invoicePresence != 'All') n++;
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final data = ref.watch(oldSalesProvider((
      page: _page,
      search: _query,
      dateFrom: _dateFrom,
      dateTo: _dateTo,
      buyerType: _buyerType,
      itemType: _itemType,
      invoicePresence: _invoicePresence,
    )));
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        oldSearchField(context,
            hint: 'Search old sales',
            onChanged: (value) => setState(() {
                  _query = value.trim();
                  _page = 0;
                })),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: _openFilters,
                icon: Badge(
                  isLabelVisible: _activeFilterCount > 0,
                  label: Text('$_activeFilterCount'),
                  child: const Icon(Icons.filter_list, size: 20),
                ),
                label: const Text('Filters'),
              ),
              const SizedBox(width: 8),
              if (_activeFilterCount > 0)
                TextButton(
                  onPressed: () => setState(() {
                    _dateFrom = '';
                    _dateTo = '';
                    _buyerType = 'All';
                    _itemType = 'All';
                    _invoicePresence = 'All';
                    _page = 0;
                  }),
                  child: const Text('Clear'),
                ),
              const Spacer(),
              Text('${data.value?.total ?? 0} sales',
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(
          child: data.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (result) => OldTable(
              rows: result.rows,
              total: result.total,
              page: _page,
              onPageChanged: (p) => setState(() => _page = p),
              emptyMessage: 'No old sales match these filters.',
              rowBuilder: (row) => _saleTile(row, isAdmin: isAdmin),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openFilters() async {
    final result = await showAppSheet<
        ({String dateFrom, String dateTo, String buyerType, String itemType,
            String invoicePresence})>(
      context: context,
      title: 'Filter old sales',
      heightFraction: 0.8,
      builder: (sheetContext) => _SalesFilterSheet(
        dateFrom: _dateFrom,
        dateTo: _dateTo,
        buyerType: _buyerType,
        itemType: _itemType,
        invoicePresence: _invoicePresence,
      ),
    );
    if (result != null) {
      setState(() {
        _dateFrom = result.dateFrom;
        _dateTo = result.dateTo;
        _buyerType = result.buyerType;
        _itemType = result.itemType;
        _invoicePresence = result.invoicePresence;
        _page = 0;
      });
    }
  }

  Widget _saleTile(Map<String, dynamic> row, {required bool isAdmin}) {
    final date = (row['sale_date'] ?? '').toString();
    final trno = (row['old_trno'] ?? '').toString();
    final invoice = (row['invoice_reference'] ?? '').toString();
    final price = row['sale_price'];
    final buyer = _parseBuyer(row);
    final lines = (row['sale_items'] as List?)?.cast<Map>() ?? [];
    final lineSummary = lines
        .map((line) => (line['item_description'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .take(3)
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: () => _showDetails(row, isAdmin: isAdmin),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: const Icon(Icons.receipt_long_outlined,
                color: Colors.white, size: 20),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                    [
                      if (date.isNotEmpty && date.compareTo('0010') > 0)
                        date,
                      if (trno.isNotEmpty) trno,
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
              oldBadge(context),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (buyer.name.isNotEmpty)
                Row(
                  children: [
                    Flexible(
                      child: Text(buyer.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline)),
                    ),
                    const SizedBox(width: 6),
                    _buyerChip(context, buyer.kind),
                  ],
                ),
              if (invoice.isNotEmpty)
                Text('Invoice: $invoice',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (lineSummary.isNotEmpty)
                Text(
                    lines.length > 3
                        ? '$lineSummary · +${lines.length - 3} more'
                        : lineSummary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (price != null && price.toString() != '0' && price.toString() != '0.0')
                Text('Total: $price',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(Map<String, dynamic> row, {required bool isAdmin}) {
    final buyer = _parseBuyer(row);
    final lines = (row['sale_items'] as List?)?.cast<Map>() ?? [];
    final notes = (row['notes'] ?? '').toString();
    final cleanNotes = notes
        .split('\n')
        .where((l) =>
            l.trim().isNotEmpty &&
            !l.startsWith('party:') &&
            l != 'Unknown legacy customer' &&
            !l.startsWith('Unknown legacy customer ('))
        .join('\n');
    showAppSheet<void>(
      context: context,
      title: 'Sale details',
      heightFraction: 0.9,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Sale details',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                if (isAdmin)
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      showOldSaleForm(context, row: row);
                    },
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('Close'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KeyValue(
                        label: 'Date',
                        value: (row['sale_date'] ?? '').toString().compareTo('0010') > 0
                            ? (row['sale_date'] ?? '').toString()
                            : 'Unknown'),
                    if ((row['old_trno'] ?? '').toString().isNotEmpty)
                      KeyValue(
                          label: 'Trno',
                          value: (row['old_trno'] ?? '').toString()),
                    if ((row['invoice_reference'] ?? '')
                        .toString()
                        .isNotEmpty)
                      KeyValue(
                          label: 'Invoice',
                          value: (row['invoice_reference'] ?? '').toString()),
                    KeyValue(
                        label: 'Buyer',
                        value: buyer.name.isEmpty ? 'Unknown' : buyer.name),
                    if (buyer.kind.isNotEmpty)
                      KeyValue(label: 'Buyer type', value: buyer.kind),
                    if (row['sale_price'] != null)
                      KeyValue(
                          label: 'Total',
                          value: row['sale_price'].toString()),
                    if (cleanNotes.isNotEmpty)
                      KeyValue(label: 'Notes', value: cleanNotes),
                    const SizedBox(height: 12),
                    Text('Items (${lines.length})',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    if (lines.isEmpty)
                      Text('No line items recorded.',
                          style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.outline)),
                    for (final line in lines) _itemCard(context, line),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemCard(BuildContext context, Map line) {
    final scheme = Theme.of(context).colorScheme;
    final description = (line['item_description'] ?? '').toString();
    final serial = (line['item_serial'] ?? '').toString();
    final type = (line['item_type'] ?? '').toString();
    final price = line['item_price'];
    final isMain = line['is_main_item'] == 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(description.isEmpty ? '(no description)' : description,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ),
                      if (isMain) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.star, size: 14, color: scheme.primary),
                      ],
                    ],
                  ),
                  if (serial.isNotEmpty)
                    Text('Serial: $serial',
                        style:
                            TextStyle(fontSize: 12, color: scheme.outline)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _typeChip(context, type),
                if (price != null && price.toString() != '0')
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(price.toString(),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// Who bought the sale: a customers row, a party:kind:NAME tag in notes
/// (dealer/branch sales), or an unknown legacy customer.
typedef _Buyer = ({String name, String kind});

_Buyer _parseBuyer(Map<String, dynamic> row) {
  final customer = (row['customers'] as Map?)?['name']?.toString() ?? '';
  if (customer.isNotEmpty) return (name: customer, kind: 'Customer');
  final notes = (row['notes'] ?? '').toString();
  for (final line in notes.split('\n')) {
    final m = RegExp(r'^party:(dealer|branch|customer|none):(.+)$')
        .firstMatch(line.trim());
    if (m != null) {
      final kind = switch (m.group(1)) {
        'dealer' => 'Dealer',
        'branch' => 'Branch',
        'customer' => 'Customer',
        _ => 'Unknown',
      };
      return (name: m.group(2)!.trim(), kind: kind);
    }
  }
  if (notes.contains('Unknown legacy customer')) {
    return (name: 'Unknown legacy customer', kind: '');
  }
  return (name: '', kind: '');
}

Widget _buyerChip(BuildContext context, String kind) {
  if (kind.isEmpty) return const SizedBox.shrink();
  final color = switch (kind) {
    'Dealer' => const Color(0xFF7B1FA2),
    'Branch' => const Color(0xFF00796B),
    'Customer' => Theme.of(context).colorScheme.primary,
    _ => Theme.of(context).colorScheme.outline,
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(kind,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
  );
}

Widget _typeChip(BuildContext context, String type) {
  if (type.isEmpty) return const SizedBox.shrink();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(type,
        style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSecondaryContainer)),
  );
}

/// Bottom-sheet form with the date range, buyer type, item type and
/// invoice-presence filters. Pops the chosen values (display form).
class _SalesFilterSheet extends StatefulWidget {
  const _SalesFilterSheet({
    required this.dateFrom,
    required this.dateTo,
    required this.buyerType,
    required this.itemType,
    required this.invoicePresence,
  });

  final String dateFrom;
  final String dateTo;
  final String buyerType;
  final String itemType;
  final String invoicePresence;

  @override
  State<_SalesFilterSheet> createState() => _SalesFilterSheetState();
}

class _SalesFilterSheetState extends State<_SalesFilterSheet> {
  late final TextEditingController _from;
  late final TextEditingController _to;
  late String _buyerType;
  late String _itemType;
  late String _invoicePresence;

  static const _buyerTypes = ['All', 'Customer', 'Dealer', 'Branch'];
  static const _itemTypes = ['All', 'machine', 'probe', 'printer', 'part'];
  static const _invoiceOptions = ['All', 'With invoice', 'Without invoice'];

  @override
  void initState() {
    super.initState();
    _from = TextEditingController(text: widget.dateFrom);
    _to = TextEditingController(text: widget.dateTo);
    _buyerType = widget.buyerType;
    _itemType = widget.itemType;
    _invoicePresence = widget.invoicePresence;
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.pop(context, (
      dateFrom: _from.text.trim(),
      dateTo: _to.text.trim(),
      buyerType: _buyerType,
      itemType: _itemType,
      invoicePresence: _invoicePresence,
    ));
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
                child: Text('Filter old sales',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child:
                            DateField(controller: _from, label: 'From date'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: DateField(controller: _to, label: 'To date')),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Buyer',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _buyerType,
                    items: [
                      for (final v in _buyerTypes)
                        DropdownMenuItem(value: v, child: Text(v)),
                    ],
                    onChanged: (v) =>
                        setState(() => _buyerType = v ?? 'All'),
                  ),
                  const SizedBox(height: 16),
                  Text('Item type',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _itemType,
                    items: [
                      for (final v in _itemTypes)
                        DropdownMenuItem(
                            value: v,
                            child: Text(v == 'All' ? 'All' : v)),
                    ],
                    onChanged: (v) =>
                        setState(() => _itemType = v ?? 'All'),
                  ),
                  const SizedBox(height: 16),
                  Text('Invoice',
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: _invoicePresence,
                    items: [
                      for (final v in _invoiceOptions)
                        DropdownMenuItem(value: v, child: Text(v)),
                    ],
                    onChanged: (v) =>
                        setState(() => _invoicePresence = v ?? 'All'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, (
                  dateFrom: '',
                  dateTo: '',
                  buyerType: 'All',
                  itemType: 'All',
                  invoicePresence: 'All',
                )),
                child: const Text('Clear all'),
              ),
              const Spacer(),
              FilledButton(onPressed: _apply, child: const Text('Apply')),
            ],
          ),
        ],
      ),
    );
  }
}
