import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/data.dart';

SupabaseClient get _db => Supabase.instance.client;

const _machineCols =
    'id, machine_id, model, serial_number, status, current_location, notes, '
    'acquisition_date, purchase_price, vendor_id, condition, batch_id';

/// Everything the shop keeps in the basement: the machine cards plus the
/// probes, printers and parts that travel with them, shaped like the
/// Branch and Workshop lists so the Basement page can use the same tiles,
/// details sheet, flags and edit form.
///
/// A row belongs here when its location says Basement, or when it is a
/// kit member whose machine is in the basement. The `Basement` audit flag
/// is also honoured, so a PDF-audited row still shows even before its
/// location text is normalised.
final basementItemsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final flags = await ref.watch(flagsProvider.future);
  final flaggedIds = <int>{
    for (final flag in flags)
      if (flag['item_kind'] == 'machine' &&
          '${flag['note'] ?? ''}'.trim().toUpperCase() == 'BASEMENT' &&
          flag['item_id'] is int)
        flag['item_id'] as int,
  };
  final filter = flaggedIds.isEmpty
      ? 'current_location.ilike.%basement%'
      : 'current_location.ilike.%basement%,id.in.(${flaggedIds.join(',')})';
  final machineRows = await fetchAllPages(
    () => _db
        .from('machines')
        .select(_machineCols)
        .or(filter)
        .order('id', ascending: false),
  );
  final seenMachines = <int>{};
  final machines = <Map<String, dynamic>>[];
  for (final row in machineRows) {
    if (seenMachines.add(row['id'] as int)) {
      machines.add({...row, 'kind': 'machine'});
    }
  }
  final machineIds = [for (final row in machines) row['id'] as int];

  Future<List<Map<String, dynamic>>> kit(
    String table,
    String kind,
    String nameColumn,
  ) async {
    const cols =
        'id, internal_id, serial_number, status, current_location, notes, '
        'acquisition_date, purchase_price, vendor_id, condition, '
        'assigned_machine_id';
    final byLocation = await fetchAllPages(
      () => _db
          .from(table)
          .select('$cols, $nameColumn')
          .ilike('current_location', '%basement%')
          .order('id', ascending: false),
    );
    final byMachine = machineIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await fetchAllPages(
            () => _db
                .from(table)
                .select('$cols, $nameColumn')
                .inFilter('assigned_machine_id', machineIds)
                .order('id', ascending: false),
          );
    final seen = <int>{};
    return [
      for (final row in [...byLocation, ...byMachine])
        if (seen.add(row['id'] as int)) {...row, 'kind': kind},
    ];
  }

  return [
    ...machines,
    ...await kit('probes', 'probe', 'model'),
    ...await kit('printers', 'printer', 'name_model'),
    ...await kit('parts', 'part', 'name_model'),
  ];
});
