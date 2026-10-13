import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final data = ref.watch(oldSalesProvider((page: _page, search: _query)));
    return Column(
      children: [
        oldSearchField(context,
            hint: 'Search old sales',
            onChanged: (value) => setState(() {
                  _query = value.trim();
                  _page = 0;
                })),
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
              emptyMessage: 'No old sales match this search.',
              rowBuilder: (row) => _saleTile(row, isAdmin: isAdmin),
            ),
          ),
        ),
      ],
    );
  }

  Widget _saleTile(Map<String, dynamic> row, {required bool isAdmin}) {
    final date = (row['sale_date'] ?? '').toString();
    final trno = (row['old_trno'] ?? '').toString();
    final invoice = (row['invoice_reference'] ?? '').toString();
    final price = row['sale_price'];
    final notes = (row['notes'] ?? '').toString();
    final customer = (row['customers'] as Map?)?['name']?.toString() ?? '';
    final lines = (row['sale_items'] as List?)?.cast<Map>() ?? [];
    final lineSummary = lines
        .map((line) => (line['item_description'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppCard(
        onTap: isAdmin ? () => showOldSaleForm(context, row: row) : null,
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
                    [if (date.isNotEmpty) date, if (trno.isNotEmpty) trno]
                        .join(' · '),
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
              if (customer.isNotEmpty)
                Text(customer,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (invoice.isNotEmpty)
                Text('Invoice: $invoice',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (lineSummary.isNotEmpty)
                Text(lineSummary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
              if (price != null)
                Text('Total: $price',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              if (notes.isNotEmpty &&
                  notes != 'Imported legacy line (no invoice).')
                Text(notes,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}
