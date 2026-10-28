import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout.dart';
import '../auth/auth_controller.dart';
import '../common/widgets.dart';
import '../data/data.dart';
import '../old/old_record_forms.dart';
import '../old/old_table.dart';

/// Every recorded sale with its lines — the imported history plus the
/// ones recorded since — in one fetch. The screen filters it in memory;
/// nothing is ever written here.
final allSalesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await db
      .from('sales')
      .select(
          'id, sale_date, invoice_reference, sale_price, notes, old_trno, '
          'old_source_id, customer_id, customers(name), '
          'sale_items(item_description, item_serial, item_price, item_type, '
          'is_main_item, machine_id, probe_id, printer_id, part_id)')
      .order('sale_date', ascending: false);
  return rows;
});

// ---------------------------------------------------------------------------
// The merged list: recorded sales + sends marked Sold, newest first
// ---------------------------------------------------------------------------

/// One row of the Sales screen: a sale from the `sales` table or a send
/// marked Sold ([rows] then holds every movement row of that send).
typedef SaleEntry = ({
  String source, // 'sale' | 'send'
  String date,
  String buyer,
  String buyerKind, // Customer | Dealer | Branch (best effort)
  String summary,
  double? total,
  String soldBy, // who sold it, typed when a send is marked Sold
  bool paid,
  bool imported, // came in with the old-system import
  Map<String, dynamic> row,
  List<Map<String, dynamic>> rows,
});

/// A sortable date for a sale or movement row — import rows carry all
/// sorts of date shapes. Sales read yyyy-MM-dd, movements dd-MM-yyyy,
/// and anything unreadable sorts last (null).
DateTime? saleEntryDate(String text) {
  final t = text.trim();
  if (t.length < 8) return null;
  final iso = DateTime.tryParse(t);
  if (iso != null) return iso;
  final parts = t.split('-');
  if (parts.length != 3) return null;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  final c = int.tryParse(parts[2]);
  if (a == null || b == null || c == null) return null;
  // four-digit first part = yyyy-MM-dd; anything else = dd-MM-yyyy
  if (parts[0].length == 4) return DateTime(a, b, c);
  return DateTime(c, b, a);
}

/// An amount as it reads on a card — whole numbers without the .0 tail.
String saleAmountText(double? amount) {
  if (amount == null) return '';
  return amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : '$amount';
}

/// The merged Sales list: every recorded sale plus every send marked
/// Sold (one entry per send), newest first. Pure read of the rows it is
/// given — old sales keep their rows, sold sends keep their movements.
/// Sends that came in with the old-system import are skipped: those
/// transactions are already rows in `sales`, so listing the movement
/// too would show the same sale twice.
List<SaleEntry> mergeSaleEntries({
  required List<Map<String, dynamic>> salesRows,
  required List<Map<String, dynamic>> movementRows,
  required Map<String, String> labels,
}) {
  final entries = <SaleEntry>[];

  for (final row in salesRows) {
    final buyer = oldSaleBuyer(row);
    final lines = (row['sale_items'] as List?)?.cast<Map>() ?? [];
    final summary = lines
        .map((line) => (line['item_description'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final price = row['sale_price'];
    entries.add((
      source: 'sale',
      date: (row['sale_date'] ?? '').toString(),
      buyer: buyer.name,
      buyerKind: buyer.kind,
      summary: summary,
      total: price is num ? price.toDouble() : null,
      soldBy: '',
      paid: true,
      imported: row['old_source_id'] != null,
      row: row,
      rows: const [],
    ));
  }

  // sends marked Sold — one entry per send, exactly like the movement
  // cards group rows that travelled together
  final groups = <String, List<Map<String, dynamic>>>{};
  final order = <String>[];
  for (final row in movementRows) {
    if (row['old_source_id'] != null) continue;
    if (!movementSold(row)) continue;
    final group = (row['group_ref'] ?? '').toString();
    final key = group.isEmpty ? 'row-${row['id']}' : group;
    if (!groups.containsKey(key)) order.add(key);
    groups.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(row);
  }
  for (final key in order) {
    final rows = groups[key]!;
    final first = rows.first;
    final party = (first['customers'] as Map?) ??
        (first['dealers'] as Map?) ??
        (first['workshops'] as Map?);
    final parts = <String>[];
    for (final row in rows) {
      final itemKey = movementItemKey(row);
      if (itemKey == null) continue;
      final label = labels['${itemKey.key}:${itemKey.value}'];
      if (label != null && label.isNotEmpty) parts.add(label);
    }
    entries.add((
      source: 'send',
      date: '${first['movement_date'] ?? ''}',
      buyer: '${party?['name'] ?? first['to_location'] ?? ''}',
      buyerKind: '${first['movement_type'] ?? ''}',
      summary: parts.join(' · '),
      total: soldAmountOf(first),
      soldBy: movementSoldBy(first),
      paid: rows.any(movementPaid),
      imported: false,
      row: first,
      rows: rows,
    ));
  }

  entries.sort((a, b) {
    final da = saleEntryDate(a.date) ?? DateTime(0);
    final db = saleEntryDate(b.date) ?? DateTime(0);
    return db.compareTo(da);
  });
  return entries;
}

/// The kinds of item an entry covers: sale lines carry an item_type,
/// sends carry one item id per row.
Set<String> saleEntryItemTypes(SaleEntry entry) {
  if (entry.source == 'sale') {
    final lines = (entry.row['sale_items'] as List?)?.cast<Map>() ?? const [];
    return {
      for (final line in lines) '${line['item_type'] ?? ''}'.toLowerCase()
    };
  }
  return {
    for (final row in entry.rows)
      if (row['machine_id'] != null)
        'machine'
      else if (row['probe_id'] != null)
        'probe'
      else if (row['printer_id'] != null)
        'printer'
      else if (row['part_id'] != null)
        'part',
  };
}

/// Applies the Sales filters: free-text search, source (recorded sales
/// or sold sends), buyer type, item type and an inclusive date range
/// (dates typed as dd-MM-yyyy). Every filter defaults to off.
List<SaleEntry> filterSaleEntries(
  List<SaleEntry> entries, {
  String query = '',
  String source = 'All',
  String buyerType = 'All',
  String itemType = 'All',
  String dateFrom = '',
  String dateTo = '',
}) {
  final q = query.trim().toLowerCase();
  final from = dateFrom.trim().isEmpty ? null : saleEntryDate(dateFrom);
  final to = dateTo.trim().isEmpty ? null : saleEntryDate(dateTo);
  return entries.where((entry) {
    if (source == 'Sales' && entry.source != 'sale') return false;
    if (source == 'From sends' && entry.source != 'send') return false;
    if (buyerType != 'All' && entry.buyerKind != buyerType) return false;
    if (itemType != 'All' && !saleEntryItemTypes(entry).contains(itemType)) {
      return false;
    }
    if (from != null || to != null) {
      final date = saleEntryDate(entry.date);
      if (date == null) return false;
      if (from != null && date.isBefore(from)) return false;
      if (to != null && date.isAfter(to)) return false;
    }
    if (q.isEmpty) return true;
    final invoice = (entry.row['invoice_reference'] ?? '').toString();
    final trno = (entry.row['old_trno'] ?? '').toString();
    final notes = (entry.row['notes'] ?? '').toString();
    final haystack =
        '${entry.date} ${entry.buyer} ${entry.summary} ${entry.soldBy} '
                '$invoice $trno $notes ${entry.total ?? ''}'
            .toLowerCase();
    return haystack.contains(q);
  }).toList();
}

/// Who bought the sale: a customers row, a party:kind:NAME tag in notes
/// (dealer/branch sales), or an unknown legacy customer.
typedef OldSaleBuyer = ({String name, String kind});

OldSaleBuyer oldSaleBuyer(Map<String, dynamic> row) {
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
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
  );
}

// ---------------------------------------------------------------------------
// the screen
// ---------------------------------------------------------------------------

/// The one Sales screen for both sides of the app: the imported sale
/// history, the sales recorded since, and every send marked Sold —
/// newest first, one entry per send. Nothing here touches stock: a sale
/// is deleted by removing its own rows, a sold send by clearing the
/// sold mark (the send itself stays put).
class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key});

  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  String _query = '';
  // Filters, all in display form ('' / 'All' = off).
  String _source = 'All'; // All | Sales | From sends
  String _buyerType = 'All';
  String _itemType = 'All';
  String _dateFrom = '';
  String _dateTo = '';

  int get _activeFilterCount {
    var n = 0;
    if (_source != 'All') n++;
    if (_buyerType != 'All') n++;
    if (_itemType != 'All') n++;
    if (_dateFrom.isNotEmpty) n++;
    if (_dateTo.isNotEmpty) n++;
    return n;
  }

  bool get _hasFilters => _query.isNotEmpty || _activeFilterCount > 0;

  void _clearFilters() {
    setState(() {
      _source = 'All';
      _buyerType = 'All';
      _itemType = 'All';
      _dateFrom = '';
      _dateTo = '';
    });
  }

  List<SaleEntry> _applyFilters(List<SaleEntry> entries) {
    return filterSaleEntries(
      entries,
      query: _query,
      source: _source,
      buyerType: _buyerType,
      itemType: _itemType,
      dateFrom: _dateFrom,
      dateTo: _dateTo,
    );
  }

  Future<void> _openFilters() async {
    final result = await showAppSheet<
        ({
          String source,
          String buyerType,
          String itemType,
          String dateFrom,
          String dateTo,
        })>(
      context: context,
      title: 'Filter sales',
      heightFraction: 0.8,
      builder: (sheetContext) => _SalesFilterSheet(
        source: _source,
        buyerType: _buyerType,
        itemType: _itemType,
        dateFrom: _dateFrom,
        dateTo: _dateTo,
      ),
    );
    if (result == null) return;
    setState(() {
      _source = result.source;
      _buyerType = result.buyerType;
      _itemType = result.itemType;
      _dateFrom = result.dateFrom;
      _dateTo = result.dateTo;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final scheme = Theme.of(context).colorScheme;
    final sales = ref.watch(allSalesProvider);
    final movements = ref.watch(allMovementsProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final labels = ref.watch(itemLabelsProvider);
    return Column(
      children: [
        SearchField(
            hint: 'Search sales by buyer, item, serial or invoice',
            onChanged: (value) => setState(() => _query = value.trim())),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Row(
            children: [
              if (isPhoneLayout(context))
                IconButton(
                  tooltip: 'Filters',
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: _activeFilterCount > 0,
                    label: Text('$_activeFilterCount'),
                    child: const Icon(Icons.filter_list, size: 22),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: _activeFilterCount > 0,
                    label: Text('$_activeFilterCount'),
                    child: const Icon(Icons.filter_list, size: 20),
                  ),
                  label: const Text('Filters'),
                ),
              if (_activeFilterCount > 0)
                IconButton(
                  tooltip: 'Clear filters',
                  icon: Icon(Icons.close,
                      size: 20, color: Theme.of(context).colorScheme.error),
                  onPressed: _clearFilters,
                ),
              const Spacer(),
            ],
          ),
        ),
        Expanded(
          child: sales.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
                icon: Icons.error_outline, message: errorMessage(error)),
            data: (saleRows) {
              final entries = mergeSaleEntries(
                  salesRows: saleRows,
                  movementRows: movements,
                  labels: labels);
              final filtered = _applyFilters(entries);
              if (filtered.isEmpty) {
                return EmptyState(
                    icon: Icons.receipt_long_outlined,
                    message: _hasFilters
                        ? 'Nothing matches these filters.'
                        : 'No sales recorded yet.');
              }
              return AppRefresh(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length + 1,
                  itemBuilder: (context, index) {
                    if (index == filtered.length) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Center(
                          child: Text(
                              '${filtered.length} sale${filtered.length == 1 ? '' : 's'}',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      );
                    }
                    return _tile(context, filtered[index], isAdmin: isAdmin);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, SaleEntry entry, {required bool isAdmin}) {
    final scheme = Theme.of(context).colorScheme;
    final isSend = entry.source == 'send';
    final rawDate = entry.date;
    final hasDate = rawDate.isNotEmpty && rawDate.compareTo('0010') > 0;
    final total = entry.total;
    final showTotal = total != null && total != 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: () => _showDetails(context, entry, isAdmin: isAdmin),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: isSend
                ? scheme.primaryContainer
                : scheme.secondaryContainer,
            child: Icon(
                isSend
                    ? Icons.sell_outlined
                    : Icons.receipt_long_outlined,
                size: 20,
                color: isSend
                    ? scheme.onPrimaryContainer
                    : scheme.onSecondaryContainer),
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                    [
                      if (hasDate) rawDate,
                      if (isSend) 'Sold',
                      if (!isSend &&
                          (entry.row['old_trno'] ?? '').toString().isNotEmpty)
                        entry.row['old_trno'].toString(),
                      if (!isSend &&
                          (entry.row['invoice_reference'] ?? '')
                              .toString()
                              .isNotEmpty)
                        'Invoice ${entry.row['invoice_reference']}',
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
              if (entry.imported) oldBadge(context),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.buyer.isNotEmpty)
                Row(
                  children: [
                    Flexible(
                      child: Text(entry.buyer,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.outline)),
                    ),
                    const SizedBox(width: 6),
                    _buyerChip(context, entry.buyerKind),
                  ],
                ),
              if (entry.summary.isNotEmpty)
                Text(entry.summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (isSend && entry.soldBy.isNotEmpty)
                Text('Sold by ${entry.soldBy}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              Row(
                children: [
                  if (showTotal)
                    Text('Total: ${saleAmountText(total)}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  if (isSend) ...[
                    if (showTotal) const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: (entry.paid
                                ? context.colors.success
                                : scheme.outline)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(entry.paid ? 'Paid' : 'Unpaid',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: entry.paid
                                  ? context.colors.success
                                  : scheme.outline)),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // details + actions
  // -----------------------------------------------------------------------

  void _showDetails(BuildContext context, SaleEntry entry,
      {required bool isAdmin}) {
    showAppSheet<void>(
      context: context,
      title: 'Sale details',
      heightFraction: 0.9,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: entry.source == 'send'
            ? _sendDetails(context, sheetContext, entry, isAdmin: isAdmin)
            : _saleDetails(context, sheetContext, entry, isAdmin: isAdmin),
      ),
    );
  }

  /// A recorded sale: its own fields and lines, plus Edit (imported
  /// sales) and Delete for admins.
  Widget _saleDetails(BuildContext context, BuildContext sheetContext,
      SaleEntry entry, {required bool isAdmin}) {
    final row = entry.row;
    final notes = (row['notes'] ?? '').toString();
    final cleanNotes = notes
        .split('\n')
        .where((l) =>
            l.trim().isNotEmpty &&
            !l.startsWith('party:') &&
            l != 'Unknown legacy customer' &&
            !l.startsWith('Unknown legacy customer ('))
        .join('\n');
    final lines = (row['sale_items'] as List?)?.cast<Map>() ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Sale details',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            if (isAdmin) ...[
              TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final deleted =
                      await confirmDeleteOldSale(context, ref, row);
                  if (!deleted || !sheetContext.mounted) return;
                  Navigator.pop(sheetContext);
                  ref.invalidate(allSalesProvider);
                  messenger
                      .showSnackBar(const SnackBar(content: Text('Sale deleted.')));
                },
                icon: Icon(Icons.delete_outline,
                    size: 18, color: Theme.of(context).colorScheme.error),
                label: Text('Delete',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              if (entry.imported)
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    showOldSaleForm(context, row: row);
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
            ],
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
                    value: (row['sale_date'] ?? '').toString().compareTo(
                                '0010') >
                            0
                        ? (row['sale_date'] ?? '').toString()
                        : 'Unknown'),
                if ((row['old_trno'] ?? '').toString().isNotEmpty)
                  KeyValue(
                      label: 'Trno', value: (row['old_trno'] ?? '').toString()),
                if ((row['invoice_reference'] ?? '').toString().isNotEmpty)
                  KeyValue(
                      label: 'Invoice',
                      value: (row['invoice_reference'] ?? '').toString()),
                KeyValue(
                    label: 'Buyer',
                    value: entry.buyer.isEmpty ? 'Unknown' : entry.buyer),
                if (entry.buyerKind.isNotEmpty)
                  KeyValue(label: 'Buyer type', value: entry.buyerKind),
                if (row['sale_price'] != null)
                  KeyValue(
                      label: 'Total', value: row['sale_price'].toString()),
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
    );
  }

  /// A send marked Sold: the send's own facts, its items by label, and —
  /// for admins — the way back (clear the sold mark, keep the send).
  Widget _sendDetails(BuildContext context, BuildContext sheetContext,
      SaleEntry entry, {required bool isAdmin}) {
    final first = entry.row;
    final notes = (first['notes'] ?? '').toString();
    final actor = first['profiles'];
    final actorName = actor is Map
        ? '${actor['display_name'] ?? actor['username'] ?? ''}'
        : '';
    final rows = entry.rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Sold send',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            if (isAdmin)
              TextButton.icon(
                onPressed: () => _unmarkSold(context, sheetContext, entry),
                icon: Icon(Icons.remove_shopping_cart_outlined,
                    size: 18, color: Theme.of(context).colorScheme.error),
                label: Text('Not sold anymore',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
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
                KeyValue(label: 'Date', value: entry.date),
                KeyValue(
                    label: 'Buyer',
                    value: entry.buyer.isEmpty ? 'Unknown' : entry.buyer),
                KeyValue(label: 'Sent to', value: entry.buyerKind),
                KeyValue(
                    label: 'Amount',
                    value: saleAmountText(entry.total).isEmpty
                        ? 'Not recorded'
                        : saleAmountText(entry.total)),
                KeyValue(
                    label: 'Sold by',
                    value: entry.soldBy.isEmpty
                        ? 'Not recorded'
                        : entry.soldBy),
                KeyValue(label: 'Settled', value: entry.paid ? 'Paid' : 'Unpaid'),
                if (actorName.isNotEmpty)
                  KeyValue(label: 'Recorded by', value: actorName),
                if (notes.isNotEmpty) KeyValue(label: 'Notes', value: notes),
                const SizedBox(height: 12),
                Text('Items (${rows.length})',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final row in rows) _sendItemCard(context, row),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _itemCard(BuildContext context, Map line) {
    final scheme = Theme.of(context).colorScheme;
    final description = (line['item_description'] ?? '').toString();
    final serial = (line['item_serial'] ?? '').toString();
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
                          child: Text(
                              description.isEmpty
                                  ? '(no description)'
                                  : description,
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
                          style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ],
                ),
              ),
              if (price != null && price.toString() != '0')
                Text(price.toString(),
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sendItemCard(BuildContext context, Map<String, dynamic> row) {
    final labels = ref.read(itemLabelsProvider);
    final itemKey = movementItemKey(row);
    final label = itemKey == null
        ? 'Unknown item'
        : labels['${itemKey.key}:${itemKey.value}'] ?? 'Unknown item';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(label,
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  /// The way back from a sold send: clear the sold mark and the amount.
  /// The send itself, its rows and the items' history all stay — it can
  /// be marked sold again at any time.
  Future<void> _unmarkSold(BuildContext context, BuildContext sheetContext,
      SaleEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Not a sale anymore?'),
        content: const Text(
            'The send stays in Movements with all its items and history — '
            'only the sold mark and the amount are removed. You can mark '
            'it sold again later.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove sold mark'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await setSendSold(entry.rows, false);
      ref.invalidate(allMovementsProvider);
      ref.invalidate(oldStockItemsProvider);
      if (!sheetContext.mounted) return;
      Navigator.pop(sheetContext);
      showSnack(context, 'The send is no longer marked sold.');
    } catch (error) {
      if (!context.mounted) return;
      showSnack(context, errorMessage(error), error: true);
    }
  }
}

/// The Sales filter sheet: source, buyer, item type and an inclusive
/// date range. Every option defaults to off.
class _SalesFilterSheet extends StatefulWidget {
  const _SalesFilterSheet({
    required this.source,
    required this.buyerType,
    required this.itemType,
    required this.dateFrom,
    required this.dateTo,
  });

  final String source;
  final String buyerType;
  final String itemType;
  final String dateFrom;
  final String dateTo;

  @override
  State<_SalesFilterSheet> createState() => _SalesFilterSheetState();
}

class _SalesFilterSheetState extends State<_SalesFilterSheet> {
  late final TextEditingController _from;
  late final TextEditingController _to;
  late String _source;
  late String _buyerType;
  late String _itemType;

  static const _sources = ['All', 'Sales', 'From sends'];
  static const _buyerTypes = ['All', 'Customer', 'Dealer', 'Branch'];
  static const _itemTypes = {
    'All': 'All',
    'machine': 'Machines',
    'probe': 'Probes',
    'printer': 'Printers',
    'part': 'Parts',
    'other': 'Other',
  };

  @override
  void initState() {
    super.initState();
    _from = TextEditingController(text: widget.dateFrom);
    _to = TextEditingController(text: widget.dateTo);
    _source = widget.source;
    _buyerType = widget.buyerType;
    _itemType = widget.itemType;
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.pop(context, (
      source: _source,
      buyerType: _buyerType,
      itemType: _itemType,
      dateFrom: _from.text.trim(),
      dateTo: _to.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // the sheet does not lift for the keyboard — pad it so Apply stays
    // above it while a date is being typed in
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
                child: Text('Filter sales',
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
                      Expanded(
                        child: DateField(controller: _to, label: 'To date'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _source,
                    decoration: const InputDecoration(labelText: 'Show'),
                    items: [
                      for (final value in _sources)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (value) =>
                        setState(() => _source = value ?? 'All'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _buyerType,
                    decoration: const InputDecoration(labelText: 'Buyer'),
                    items: [
                      for (final value in _buyerTypes)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (value) =>
                        setState(() => _buyerType = value ?? 'All'),
                  ),
                  const SizedBox(height: 12),
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
