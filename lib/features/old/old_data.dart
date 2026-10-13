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
}) async {
  final results = await Future.wait<dynamic>([
    build().order('id', ascending: false).range(page * 50, page * 50 + 49),
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
// ---------------------------------------------------------------------------

typedef OldSalesArgs = ({int page, String search});

final oldSalesProvider =
    FutureProvider.family<OldPage, OldSalesArgs>((ref, args) {
  return _paged(
    () {
      PostgrestFilterBuilder<PostgrestList> query = _db.from('sales').select(
          'id, sale_date, invoice_reference, sale_price, notes, old_trno, old_source_id, '
          'customer_id, customers(name), '
          'sale_items(item_description, item_serial, item_price, item_type)');
      if (args.search.isNotEmpty) {
        final t = args.search;
        query = query
            .or('old_trno.ilike.%$t%,notes.ilike.%$t%,invoice_reference.ilike.%$t%');
      }
      return query;
    },
    page: args.page,
    countSource: () async {
      final res =
          await _db.from('sales').select('id').count(CountOption.exact);
      return res.count;
    },
  );
});
