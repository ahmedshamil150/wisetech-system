import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient get _db => Supabase.instance.client;

/// The id of the imported old stock batch (BATCH-OLD).
const kOldBatchId = 30;

/// Rows for one page plus the total matching count, so the list can show
/// "50 of 2449" and page through thousands of imported rows.
typedef OldPage = ({List<Map<String, dynamic>> rows, int total});

/// One page of the 50 rows shown at a time in every old-data table.
typedef OldArgs = ({int page, String search, String status});

/// Runs [build] as a paged select: applies the filters, orders newest
/// first, takes one page of 50, and fetches the total count in parallel.
Future<OldPage> _paged(
  PostgrestFilterBuilder<PostgrestList> Function() build, {
  required int page,
  required Future<int> Function() countSource,
  String orderBy = 'id',
}) async {
  final results = await Future.wait<dynamic>([
    build().order(orderBy, ascending: false).range(page * 50, page * 50 + 49),
    countSource(),
  ]);
  final rows = (results[0] as PostgrestList).cast<Map<String, dynamic>>();
  final total = results[1] as int;
  return (rows: rows, total: total);
}

// ---------------------------------------------------------------------------
// Old stock: BATCH-OLD machines, probes and printers. Parts are shared
// between the two sides and are listed in both.
// ---------------------------------------------------------------------------

final oldMachinesProvider =
    FutureProvider.family<OldPage, OldArgs>((ref, args) {
  return _paged(
    () {
      PostgrestFilterBuilder<PostgrestList> query = _db.from('machines')
          .select(
              'id, machine_id, model, serial_number, status, current_location, notes, acquisition_date')
          .eq('batch_id', kOldBatchId);
      if (args.status != 'All') {
        query = query.eq('status', args.status);
      }
      if (args.search.isNotEmpty) {
        final t = args.search;
        query = query
            .or('machine_id.ilike.%$t%,model.ilike.%$t%,serial_number.ilike.%$t%');
      }
      return query;
    },
    page: args.page,
    countSource: () async {
      final res = await _db
          .from('machines')
          .select('id')
          .eq('batch_id', kOldBatchId)
          .count(CountOption.exact);
      return res.count;
    },
  );
});

final oldProbesProvider =
    FutureProvider.family<OldPage, OldArgs>((ref, args) {
  return _paged(
    () {
      PostgrestFilterBuilder<PostgrestList> query = _db.from('probes')
          .select(
              'id, internal_id, model, serial_number, status, current_location, notes')
          .eq('batch_id', kOldBatchId);
      if (args.status != 'All') {
        query = query.eq('status', args.status);
      }
      if (args.search.isNotEmpty) {
        final t = args.search;
        query = query
            .or('internal_id.ilike.%$t%,model.ilike.%$t%,serial_number.ilike.%$t%');
      }
      return query;
    },
    page: args.page,
    countSource: () async {
      final res = await _db
          .from('probes')
          .select('id')
          .eq('batch_id', kOldBatchId)
          .count(CountOption.exact);
      return res.count;
    },
  );
});

final oldPrintersProvider =
    FutureProvider.family<OldPage, OldArgs>((ref, args) {
  return _paged(
    () {
      PostgrestFilterBuilder<PostgrestList> query = _db.from('printers')
          .select(
              'id, internal_id, name_model, serial_number, status, current_location, notes')
          .eq('batch_id', kOldBatchId);
      if (args.status != 'All') {
        query = query.eq('status', args.status);
      }
      if (args.search.isNotEmpty) {
        final t = args.search;
        query = query
            .or('internal_id.ilike.%$t%,name_model.ilike.%$t%,serial_number.ilike.%$t%');
      }
      return query;
    },
    page: args.page,
    countSource: () async {
      final res = await _db
          .from('printers')
          .select('id')
          .eq('batch_id', kOldBatchId)
          .count(CountOption.exact);
      return res.count;
    },
  );
});

// ---------------------------------------------------------------------------
// Old movements: the imported Legacy rows.
// ---------------------------------------------------------------------------

typedef OldMovementsArgs = ({int page, String search});

final oldMovementsProvider =
    FutureProvider.family<OldPage, OldMovementsArgs>((ref, args) {
  return _paged(
    () {
      PostgrestFilterBuilder<PostgrestList> query = _db.from('movements').select(
          'id, movement_type, movement_date, from_location, to_location, reason, notes, '
          'machine_id, probe_id, printer_id, part_id, old_source_id, '
          'machines(machine_id, model), probes(internal_id, model), '
          'printers(internal_id, name_model), parts(internal_id, name_model)');
      query = query.eq('movement_type', 'Legacy');
      if (args.search.isNotEmpty) {
        final t = args.search;
        query = query
            .or('from_location.ilike.%$t%,to_location.ilike.%$t%,notes.ilike.%$t%');
      }
      return query;
    },
    page: args.page,
    countSource: () async {
      final res = await _db
          .from('movements')
          .select('id')
          .eq('movement_type', 'Legacy')
          .count(CountOption.exact);
      return res.count;
    },
  );
});

// ---------------------------------------------------------------------------
// Old sales: every imported sale with its line items.
//
// PostgREST can't mix embedded columns (customers.name, sale_items.*) into
// one or() tree, so free-text search runs two cheap id lookups first
// (matching sale_items and customers) and folds the results into the main
// query as id.in./customer_id.in. filters.
// ---------------------------------------------------------------------------

typedef OldSalesArgs = ({
  int page,
  String search,
  String dateFrom, // dd-MM-yyyy display, or ''
  String dateTo, // dd-MM-yyyy display, or ''
  String buyerType, // All | Customer | Dealer | Branch
  String itemType, // All | machine | probe | printer | part
  String invoicePresence, // All | With invoice | Without invoice
});

/// `dd-MM-yyyy` → `yyyy-MM-dd` for the database.
String oldDisplayToIso(String display) {
  final parts = display.split('-');
  if (parts.length != 3) return display;
  return '${parts[2]}-${parts[1]}-${parts[0]}';
}

/// Builds the shared where-clause for both the page query and its count.
PostgrestFilterBuilder<PostgrestList> _salesQuery(
  OldSalesArgs args, {
  required String select,
  List<int> itemSaleIds = const [],
  List<int> customerIds = const [],
}) {
  PostgrestFilterBuilder<PostgrestList> query = _db.from('sales').select(select);
  if (args.dateFrom.isNotEmpty) {
    query = query.gte('sale_date', oldDisplayToIso(args.dateFrom));
  }
  if (args.dateTo.isNotEmpty) {
    query = query.lte('sale_date', oldDisplayToIso(args.dateTo));
  }
  switch (args.buyerType) {
    case 'Customer':
      query = query.not('customer_id', 'is', null);
    case 'Dealer':
      query = query.like('notes', 'party:dealer:%');
    case 'Branch':
      query = query.like('notes', 'party:branch:%');
  }
  if (args.itemType != 'All') {
    // sale_items must be in select for this embedded filter to parse.
    query = query.eq('sale_items.item_type', args.itemType);
  }
  switch (args.invoicePresence) {
    case 'With invoice':
      query = query.not('old_trno', 'is', null);
    case 'Without invoice':
      query = query.filter('old_trno', 'is', null);
  }
  final t = args.search.trim();
  if (t.isNotEmpty) {
    final parts = <String>[
      'old_trno.ilike.%$t%',
      'notes.ilike.%$t%',
      'invoice_reference.ilike.%$t%',
      if (itemSaleIds.isNotEmpty) 'id.in.(${itemSaleIds.join(',')})',
      if (customerIds.isNotEmpty) 'customer_id.in.(${customerIds.join(',')})',
    ];
    query = query.or(parts.join(','));
  }
  return query;
}

final oldSalesProvider =
    FutureProvider.family<OldPage, OldSalesArgs>((ref, args) async {
  final t = args.search.trim();
  var itemSaleIds = <int>[];
  var customerIds = <int>[];
  if (t.isNotEmpty) {
    final lookups = await Future.wait<dynamic>([
      _db
          .from('sale_items')
          .select('sale_id')
          .or('item_description.ilike.%$t%,item_serial.ilike.%$t%')
          .limit(1000),
      _db.from('customers').select('id').ilike('name', '%$t%').limit(500),
    ]);
    itemSaleIds = ((lookups[0] as PostgrestList)
            .map((r) => r['sale_id'] as int)
            .toSet()
            .toList());
    customerIds = ((lookups[1] as PostgrestList)
            .map((r) => r['id'] as int)
            .toSet()
            .toList());
  }
  return _paged(
    () => _salesQuery(
      args,
      select: 'id, sale_date, invoice_reference, sale_price, notes, old_trno, '
          'old_source_id, customer_id, customers(name), '
          'sale_items(item_description, item_serial, item_price, item_type, '
          'is_main_item)',
      itemSaleIds: itemSaleIds,
      customerIds: customerIds,
    ),
    page: args.page,
    orderBy: 'sale_date',
    countSource: () async {
      final res = await _salesQuery(
        args,
        select: 'id${args.itemType != 'All' ? ', sale_items(id)' : ''}',
        itemSaleIds: itemSaleIds,
        customerIds: customerIds,
      ).count(CountOption.exact);
      return res.count;
    },
  );
});
