import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_controller.dart';

SupabaseClient get db => Supabase.instance.client;

SupabaseClient get _db => db;

String errorMessage(Object error) {
  if (error is PostgrestException) {
    if (error.code == '23505') return 'That record already exists.';
    final message = error.message;
    if (message.isNotEmpty) return message;
    return error.details?.toString() ?? 'The request failed.';
  }
  return error.toString();
}

// ---------------------------------------------------------------------------
// reference data (Records page + suggestions while entering an item)
// ---------------------------------------------------------------------------

final brandsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db.from('brands').select('id, name, notes').order('name');
});

final productsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db
      .from('catalog_products')
      .select('id, name_model, category, probe_type, brand_id, brands(name)')
      .order('name_model');
});

final customersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db
      .from('customers')
      .select('id, name, phone, city, address, customer_type, notes')
      .order('name');
});

final dealersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db
      .from('dealers')
      .select('id, name, phone, city, address, notes')
      .order('name');
});

final vendorsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db.from('vendors').select('id, name, phone, city, address').order('name');
});

final workshopsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db.from('workshops').select('id, name, city, phone').order('name');
});

final batchesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db
      .from('batches')
      .select(
          'id, code, letter, arrival_date, vendor_id, notes, vendors(name)')
      .order('id');
});

/// Boxes the leftover probes are kept in. Each box holds one probe type.
final probeBoxesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return await _db
      .from('probe_boxes')
      .select('id, name, probe_type, notes')
      .order('id');
});

/// The batch new items are entered into (set when a batch is created).
/// Vendor and date of every item come from it, so the add form stays short.
final currentBatchProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final batches = await ref.watch(batchesProvider.future);
  final setting = await _db
      .from('app_settings')
      .select('value')
      .eq('key', 'current_batch_id')
      .limit(1);
  if (setting.isEmpty) return null;
  final id = int.tryParse('${setting.first['value']}');
  if (id == null) return null;
  for (final batch in batches) {
    if (batch['id'] == id) return batch;
  }
  return null;
});

Future<void> setCurrentBatch(int batchId) async {
  await _db.from('app_settings').upsert(
        {'key': 'current_batch_id', 'value': batchId.toString()},
        onConflict: 'key',
      );
}

// ---------------------------------------------------------------------------
// inventory
// ---------------------------------------------------------------------------

class InventoryItem {
  const InventoryItem({
    required this.kind,
    required this.id,
    required this.code,
    required this.name,
    this.serial,
    required this.status,
    required this.location,
    this.date,
    this.batch,
    this.createdAt,
    this.productId,
    this.vendorId,
    this.assignedMachineId,
    this.boxId,
    this.probeType,
  });

  final String kind; // machine | probe | printer | part
  final int id;
  final String code;
  final String name;
  final String? serial;
  final String status;
  final String location;
  final String? date;
  final String? batch;
  final DateTime? createdAt;
  final int? productId;
  final int? vendorId;

  /// For probes and printers: the machine they travel with.
  final int? assignedMachineId;

  /// For probes: the box of leftover stock they sit in.
  final int? boxId;

  /// For probes: Convex, Linear, Phased Array... from the product record.
  final String? probeType;

  String get key => '$kind:$id';

  String get title => (serial == null || serial!.isEmpty) ? name : '$name · $serial';

  String get kindLabel => switch (kind) {
        'machine' => 'Machine',
        'probe' => 'Probe',
        'printer' => 'Printer',
        _ => 'Part',
      };

  bool get isSold => status == 'Sold';
}

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed;
  final parts = raw.split('-');
  if (parts.length == 3) {
    return DateTime.tryParse(
        '${parts[2]}-${parts[1].padLeft(2, '0')}-${parts[0].padLeft(2, '0')}');
  }
  return null;
}

InventoryItem _item(String kind, Map<String, dynamic> row,
    {required String codeField, required String nameField}) {
  final batch = row['batches'];
  return InventoryItem(
    kind: kind,
    id: row['id'] as int,
    code: (row[codeField] ?? '') as String,
    name: (row[nameField] ?? '') as String,
    serial: row['serial_number'] as String?,
    status: (row['status'] ?? '') as String,
    location: (row['current_location'] ?? '') as String,
    date: row['acquisition_date'] as String?,
    batch: batch is Map<String, dynamic> ? batch['code'] as String? : null,
    createdAt: _parseDate(row['created_at']),
    productId: row['catalog_product_id'] as int?,
    vendorId: row['vendor_id'] as int?,
    assignedMachineId: row['assigned_machine_id'] as int?,
    boxId: row['box_id'] as int?,
    probeType: ((row['catalog_products'] as Map?)?['probe_type'])?.toString(),
  );
}

/// Probes and printers that travel with the given machine.
List<InventoryItem> attachedItems(
    List<InventoryItem> items, InventoryItem machine) {
  return items
      .where((item) =>
          item.assignedMachineId == machine.id &&
          (item.kind == 'probe' || item.kind == 'printer'))
      .toList();
}

/// The kit that leaves when a machine is sent: the machine itself plus its
/// probes and printer.
List<InventoryItem> kitFor(List<InventoryItem> items, InventoryItem machine) {
  return [machine, ...attachedItems(items, machine)];
}

/// Everything this item travels with: for a machine its probes and printer,
/// for a probe or printer the machine and the rest of that kit.
List<InventoryItem> linkedItems(List<InventoryItem> items, InventoryItem item) {
  if (item.kind == 'machine') return attachedItems(items, item);
  final machineId = item.assignedMachineId;
  if (machineId == null) return const [];
  final machines = items
      .where((other) => other.kind == 'machine' && other.id == machineId)
      .toList();
  if (machines.isEmpty) return const [];
  return [
    machines.first,
    ...attachedItems(items, machines.first)
        .where((other) => other.key != item.key),
  ];
}

final inventoryProvider = FutureProvider<List<InventoryItem>>((ref) async {
  const fields =
      'id, serial_number, status, current_location, acquisition_date, created_at, '
      'catalog_product_id, vendor_id, batches(code)';
  const linked = 'assigned_machine_id, ';

  final machines = await _db
      .from('machines')
      .select('$fields, machine_id, model')
      .order('id', ascending: false);
  final probes = await _db
      .from('probes')
      .select(
          '$fields, $linked box_id, catalog_products(probe_type), internal_id, model')
      .order('id', ascending: false);
  final printers = await _db
      .from('printers')
      .select('$fields, $linked internal_id, name_model')
      .order('id', ascending: false);
  final parts = await _db
      .from('parts')
      .select('$fields, $linked internal_id, name_model')
      .order('id', ascending: false);

  final items = <InventoryItem>[
    for (final row in machines)
      _item('machine', row, codeField: 'machine_id', nameField: 'model'),
    for (final row in probes)
      _item('probe', row, codeField: 'internal_id', nameField: 'model'),
    for (final row in printers)
      _item('printer', row, codeField: 'internal_id', nameField: 'name_model'),
    for (final row in parts)
      _item('part', row, codeField: 'internal_id', nameField: 'name_model'),
  ];
  items.sort((a, b) {
    final byDate = (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0));
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });
  return items;
});

/// `machine:12` -> label used by the movement list
final itemLabelsProvider = Provider<Map<String, String>>((ref) {
  final items = ref.watch(inventoryProvider).maybeWhen(
        data: (rows) => rows,
        orElse: () => const <InventoryItem>[],
      );
  return {
    for (final item in items)
      item.key: '${item.code}  ${item.title}',
  };
});

// ---------------------------------------------------------------------------
// movements + sales
// ---------------------------------------------------------------------------

final movementsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await _db
      .from('movements')
      .select(
        'id, group_ref, movement_type, movement_date, to_location, from_location, '
        'reason, notes, reference, is_demo, created_at, actor_id, machine_id, '
        'probe_id, printer_id, part_id, dealers(name), customers(name), '
        'workshops(name), profiles(display_name, username)',
      )
      .order('id', ascending: false);
  rows.sort((a, b) {
    final byDate = (_parseDate(b['movement_date']) ?? DateTime(0))
        .compareTo(_parseDate(a['movement_date']) ?? DateTime(0));
    return byDate != 0 ? byDate : (b['id'] as int).compareTo(a['id'] as int);
  });
  return rows;
});

/// Puts an item back into stock from wherever it is: status and location
/// are restored and a 'Return' movement records when it came back.
Future<int> returnToInventory(InventoryItem item) async {
  return await _db.rpc('return_to_inventory', params: {
    'p_item_type': item.kind,
    'p_item_id': item.id,
  }) as int;
}

/// True when a dealer/customer send was recorded without its name —
/// the name can be added later (see 0010_optional_movement_party.sql).
bool movementPartyMissing(Map<String, dynamic> row) {
  final kind = row['movement_type'];
  if (kind == 'Dealer') return row['dealers'] == null;
  if (kind == 'Customer') return row['customers'] == null;
  return false;
}

/// Fills in the dealer/customer name of a movement that was recorded
/// without one — only the sender or an admin may (enforced by the RPC).
Future<void> setMovementParty(
  int movementId, {
  int? dealerId,
  int? customerId,
}) async {
  await _db.rpc('set_movement_party', params: {
    'p_movement_id': movementId,
    'p_dealer_id': ?dealerId,
    'p_customer_id': ?customerId,
  });
}

/// Customers and dealers added recently, newest first — admins see this
/// on the dashboard ("who added which name"). Rows without a created_by
/// are from the legacy import and are left out.
final recentPartiesProvider = FutureProvider<List<Map<String, dynamic>>>(
    (ref) async {
  if (!ref.watch(isAdminProvider)) return const <Map<String, dynamic>>[];
  Future<List<Map<String, dynamic>>> fetch(String table, String kind) async {
    final rows = await _db.from(table).select(
        'id, name, created_at, created_by, '
        'profiles:created_by(display_name, username)');
    return [
      for (final row in rows)
        if (row['created_by'] != null)
          <String, dynamic>{
            'name': row['name'],
            'at': row['created_at'],
            'kind': kind,
            'by': ((row['profiles'] as Map?)?['display_name'] ??
                    (row['profiles'] as Map?)?['username'] ??
                    'Someone')
                .toString(),
          },
    ];
  }

  final rows = [
    ...await fetch('customers', 'customer'),
    ...await fetch('dealers', 'dealer'),
  ]..sort((a, b) =>
      (b['at'] ?? '').toString().compareTo((a['at'] ?? '').toString()));
  return rows.take(8).toList();
});

/// Refetches everything the app shows — used by pull-to-refresh so one
/// member sees what another just did without restarting the app.
Future<void> refreshAll(WidgetRef ref) async {
  await Future.wait<void>([
    for (final future in <Future<Object?>>[
      ref.refresh(inventoryProvider.future),
      ref.refresh(movementsProvider.future),
      ref.refresh(productsProvider.future),
      ref.refresh(brandsProvider.future),
      ref.refresh(customersProvider.future),
      ref.refresh(dealersProvider.future),
      ref.refresh(vendorsProvider.future),
      ref.refresh(workshopsProvider.future),
      ref.refresh(batchesProvider.future),
      ref.refresh(probeBoxesProvider.future),
      ref.refresh(repairsProvider.future),
      ref.refresh(recentPartiesProvider.future),
      ref.refresh(profileProvider.future),
    ])
      future.then((_) {}).catchError((_) {}),
  ]);
}

/// Repairs: every member can view and update them (see 0005_repairs.sql).
final repairsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await _db
      .from('repair_jobs')
      .select(
        'id, job_number, received_at, problem_description, repair_notes, '
        'return_notes, status, returned_at, collected_by, customer_contact, '
        'created_at, customers(name), '
        'repair_items(id, equipment_type, name_model, serial_number, quantity), '
        'profiles:actor_id(display_name, username)',
      )
      .order('id', ascending: false);
  return rows;
});

/// Number of repairs that are still with us.
final openRepairsCountProvider = Provider<int>((ref) {
  final jobs = ref.watch(repairsProvider).maybeWhen(
        data: (rows) => rows,
        orElse: () => const <Map<String, dynamic>>[],
      );
  return jobs.where((row) => repairIsOpen('${row['status']}')).length;
});

bool repairIsOpen(String status) => status != 'Returned' && status != 'Cancelled';

/// Adds a repair: the customer (created if new), the job and its items.
Future<int> createRepair({
  required String customerName,
  String? contact,
  required String receivedAt,
  String? problem,
  required List<Map<String, dynamic>> items,
}) async {
  final id = await _db.rpc('create_repair', params: {
    'p_customer_name': customerName,
    if (contact != null && contact.isNotEmpty) 'p_contact': contact,
    'p_received_at': receivedAt,
    if (problem != null && problem.isNotEmpty) 'p_problem': problem,
    'p_items': items,
  });
  return id as int;
}

/// Marks a repair as fixed and handed back.
Future<void> repairSentBack({
  required int id,
  required String returnedAt,
  String? collectedBy,
  String? notes,
}) async {
  await _db
      .from('repair_jobs')
      .update({
        'status': 'Returned',
        'returned_at': returnedAt,
        if (collectedBy != null && collectedBy.isNotEmpty)
          'collected_by': collectedBy,
        if (notes != null && notes.isNotEmpty) 'repair_notes': notes,
      })
      .eq('id', id);
}

/// Puts a leftover probe into a box: it comes off its machine, becomes
/// Available and the box becomes its location.
Future<void> putProbeInBox(InventoryItem probe, Map<String, dynamic> box) async {
  await _db.from('probes').update({
    'box_id': box['id'],
    'assigned_machine_id': null,
    'status': 'Available',
    'current_location': box['name'],
  }).eq('id', probe.id);
}

/// Takes the probe back out of the box; it stays in stock at the company.
Future<void> takeProbeOutOfBox(InventoryItem probe) async {
  await _db.from('probes').update({
    'box_id': null,
    'current_location': defaultLocationFor('Available'),
  }).eq('id', probe.id);
}

/// Deletes an empty box; probes still in it go back to company stock.
Future<void> deleteProbeBox(Map<String, dynamic> box) async {
  await _db
      .from('probes')
      .update({
        'box_id': null,
        'current_location': defaultLocationFor('Available'),
      })
      .eq('box_id', box['id'] as int);
  await _db.from('probe_boxes').delete().eq('id', box['id'] as int);
}

// ---------------------------------------------------------------------------
// helpers used by the forms
// ---------------------------------------------------------------------------

const kItemKinds = ['machine', 'probe', 'printer', 'part'];

String itemKindLabel(String kind) => switch (kind) {
      'machine' => 'Machine',
      'probe' => 'Probe',
      'printer' => 'Printer',
      'other' => 'Other',
      _ => 'Part',
    };

/// Status options offered for a given item kind (mirrors the CHECK constraints).
List<String> statusOptions(String kind) => kind == 'machine'
    ? const ['In Stock', 'With Workshop', 'With Dealer', 'Sold', 'Archived']
    : const [
        'Available',
        'With Machine',
        'With Workshop',
        'With Dealer',
        'Sold',
        'Archived',
      ];

String defaultStatus(String kind) =>
    kind == 'machine' ? 'In Stock' : 'Available';

String defaultLocationFor(String status) => switch (status) {
      'With Workshop' => 'Workshop',
      'With Dealer' => 'Dealer',
      'Sold' => 'Customer',
      _ => 'Company',
    };

/// Suggested id for an item entered from the app.
///
/// A machine is numbered `<n><batch letter>` — 1T, 2T ... for the 14-09-2026
/// batch, 1U, 2U ... for the next one. A probe or printer that belongs to a
/// machine simply takes that machine's id.
Future<String> suggestedId(String kind, {String? letter}) async {
  if (kind == 'machine') {
    if (letter == null || letter.isEmpty) {
      throw Exception('Pick a batch first — a machine id needs its letter.');
    }
    final code =
        await _db.rpc('next_machine_code', params: {'p_letter': letter});
    return code as String;
  }
  final code = await _db.rpc('next_internal_id', params: {'kind': kind});
  return code as String;
}

/// Letter the next batch will get (T is taken, so the next one is U).
Future<String> suggestedBatchLetter() async {
  final code = await _db.rpc('next_batch_letter');
  return code as String;
}

/// Finds an existing record or (admin only) creates it, then returns its id.
Future<int> resolveReferenceId({
  required String table,
  required String name,
  Map<String, dynamic>? payload,
}) async {
  final nameColumn = table == 'catalog_products' ? 'name_model' : 'name';
  Future<int> find() async {
    final rows = await _db
        .from(table)
        .select('id')
        .eq(nameColumn, name)
        .order('id')
        .limit(1);
    return rows.first['id'] as int;
  }

  try {
    final rows = await _db
        .from(table)
        .select('id')
        .eq(nameColumn, name)
        .order('id')
        .limit(1);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    final inserted = await _db
        .from(table)
        .insert({...?payload, nameColumn: name})
        .select('id')
        .single();
    return inserted['id'] as int;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return find();
    rethrow;
  }
}
