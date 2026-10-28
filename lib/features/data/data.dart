import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_controller.dart';

SupabaseClient get db => Supabase.instance.client;

SupabaseClient get _db => db;

// ---------------------------------------------------------------------------
// Current-data filter: the app shows BATCH-3 stock + BATCH-PARTS + the
// standing BATCH-LOCAL (machines bought from local people) + probes with
// no batch. Old imported stock lives in BATCH-OLD and stays hidden from
// the new side.
// ---------------------------------------------------------------------------

Future<Set<int>> _currentBatchIds() async {
  final rows = await _db.from('batches').select('id, code');
  return {
    for (final row in rows)
      if (row['code'] == 'BATCH-3' ||
          row['code'] == 'BATCH-PARTS' ||
          row['code'] == 'BATCH-LOCAL')
        row['id'] as int,
  };
}

/// Builds the `.or()` filter that keeps only rows in the current batches,
/// or with no batch at all.
String _currentBatchOrFilter(Set<int> batchIds) {
  final ids = batchIds.map((id) => id.toString()).join(',');
  return 'batch_id.is.null,batch_id.in.($ids)';
}

/// The id of the imported old stock batch (BATCH-OLD). It lives here so
/// both sides of the app — pickers, labels, the old stock screens —
/// read the same constant.
const kOldBatchId = 30;

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
      .neq('code', 'BATCH-OLD')
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
    this.purchasePrice,
    this.needsReview = false,
    this.reviewKind,
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

  /// What we paid for this item when it was bought locally.
  /// NULL for stock that arrived in a container.
  final double? purchasePrice;

  /// For probes and printers: the machine they travel with.
  final int? assignedMachineId;

  /// For probes: the box of leftover stock they sit in.
  final int? boxId;

  /// For probes: Convex, Linear, Phased Array... from the product record.
  final String? probeType;

  /// Flagged for a human look — e.g. a boxed probe whose serial also
  /// turns up in the old sales records.
  final bool needsReview;

  /// Why it was flagged: 'sold' (serial sold elsewhere, green dot) or
  /// 'serial' (serial not found in the old stock, red dot).
  final String? reviewKind;

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

/// Movements dated before this day belong to the old-data side of the
/// app. Only part movements are split this way — equipment movements
/// all live on the new side.
final DateTime kOldSideCutoff = DateTime(2026, 9, 14);

/// Whether this movement row is a part movement from the old side.
/// [allMovementsProvider] keeps them (item history needs them) but the
/// movement list hides them.
bool isOldSideMovement(Map<String, dynamic> row) {
  if (row['part_id'] == null) return false;
  final date = _parseDate(row['movement_date']);
  return date != null && date.isBefore(kOldSideCutoff);
}

/// Whether a movement row came in with the old-system import and sits on
/// the old side of the split. An imported row dated on/after the split
/// is a current transaction — the last sales the old system recorded —
/// and stays visible in Movements and reports.
bool isOldSideImport(Map<String, dynamic> row) {
  if (row['old_source_id'] == null) return false;
  final date = _parseDate(row['movement_date']);
  return date == null || date.isBefore(kOldSideCutoff);
}

/// Box placements and removals belong to an item's own history only —
/// the Movements screen list hides them (they are not sends).
bool isBoxMovement(Map<String, dynamic> row) {
  final type = (row['movement_type'] ?? '').toString();
  return type == 'Box' || type == 'Unbox';
}

/// "Placed in box X" / "Took out of box X" / "Sent to X" — the title a
/// movement row gets in an item's history list.
String movementTitle(Map<String, dynamic> row) {
  final to = (row['to_location'] ?? '').toString();
  final from = (row['from_location'] ?? '').toString();
  final type = (row['movement_type'] ?? '').toString();
  if (type == 'Return') return 'Returned to $to';
  if (type == 'Box') return 'Placed in box $to';
  if (type == 'Unbox') return 'Took out of box ${from.isEmpty ? '' : from}';
  if ('${row['reason'] ?? ''}'.contains('Sold')) return 'Sold to $to';
  return 'Sent to $to';
}

/// Whether a send carries the sold mark — its reason reads 'Sold',
/// which is how the imported sales read too. A label only: the items
/// keep their status.
bool movementSold(Map<String, dynamic> row) =>
    '${row['reason'] ?? ''}'.contains('Sold');

/// The sale amount written when the send was marked sold, if one was
/// typed — blank is fine, so null is a normal state.
double? soldAmountOf(Map<String, dynamic> row) =>
    (row['sale_amount'] as num?)?.toDouble();

/// A typed amount field as a number — blank or unreadable text reads as
/// null (no amount recorded).
double? parseSaleAmount(String text) {
  final cleaned = text.trim().replaceAll(',', '');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

/// Whether a send has been settled. Rows written before the paid flag
/// existed simply read as unpaid.
bool movementPaid(Map<String, dynamic> row) => row['paid'] == true;

/// Whether a send went to one of the three sale-like destinations —
/// only those can be marked as sold.
bool isSoldKind(String kind) =>
    kind == 'Dealer' || kind == 'Customer' || kind == 'Branch';

/// Whether a send left for anywhere the company sends things to.
bool isOutboundKind(String kind) =>
    isSoldKind(kind) || kind == 'Workshop';

/// The reason a send is recorded with. Undoing the sold mark writes
/// this back — it mirrors the wording create_movement uses.
String sendReason(String kind, {required bool demo}) {
  final to = switch (kind) {
    'Workshop' => 'workshop',
    'Branch' => 'lahore branch',
    'Dealer' => 'dealer',
    _ => 'customer',
  };
  final suffix =
      demo && (kind == 'Dealer' || kind == 'Customer') ? ' (demo)' : '';
  return 'Sent to $to$suffix';
}

/// Today as dd-MM-yyyy, the date format movements are stored in.
String movementToday() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(now.day)}-${two(now.month)}-${now.year}';
}

/// `machine:12` style key of the item a movement row is about — the
/// same key [itemLabelsProvider] and InventoryItem.key use. Null when
/// the row names no item.
MapEntry<String, int>? movementItemKey(Map<String, dynamic> row) {
  for (final kind in kItemKinds) {
    final id = row['${kind}_id'];
    if (id is int) return MapEntry(kind, id);
  }
  return null;
}

/// The newest movement row of every item in [rows], keyed `kind:id`.
/// Whether an item is still out, back in stock or moved on is read off
/// this — the list, the counts and the detail sheet all share it.
Map<String, Map<String, dynamic>> latestMovementByItem(
    Iterable<Map<String, dynamic>> rows) {
  final latest = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final key = movementItemKey(row);
    if (key == null) continue;
    final mapKey = '${key.key}:${key.value}';
    final id = row['id'] as int;
    final seen = latest[mapKey];
    if (seen == null || id > (seen['id'] as int)) latest[mapKey] = row;
  }
  return latest;
}

/// Where a send's member stands right now: still out with this send,
/// already back in stock, or moved on to a later movement.
enum SendRowState { out, back, movedOn }

/// The state of one send row, judged from [latest] (from
/// [latestMovementByItem]).
SendRowState sendRowState(
    Map<String, dynamic> row, Map<String, Map<String, dynamic>> latest) {
  final key = movementItemKey(row);
  if (key == null) return SendRowState.movedOn;
  final last = latest['${key.key}:${key.value}'];
  if (last == null) return SendRowState.out;
  if (last['movement_type'] == 'Return') return SendRowState.back;
  if (last['id'] == row['id']) return SendRowState.out;
  return SendRowState.movedOn;
}

/// Splits one send's rows into three: what is still out with it, what
/// already came back, and what a later movement took away (returned and
/// sent on again). The list shows the first two — the returned part
/// under 'Returned' — and the detail sheet labels each group, so a
/// single returned item leaves its send's card instead of sitting on it.
({List<Map<String, dynamic>> out,
    List<Map<String, dynamic>> back,
    List<Map<String, dynamic>> movedOn})
    partitionSendRows(List<Map<String, dynamic>> rows,
        Map<String, Map<String, dynamic>> latest) {
  final out = <Map<String, dynamic>>[];
  final back = <Map<String, dynamic>>[];
  final movedOn = <Map<String, dynamic>>[];
  for (final row in rows) {
    switch (sendRowState(row, latest)) {
      case SendRowState.back:
        back.add(row);
      case SendRowState.movedOn:
        movedOn.add(row);
      case SendRowState.out:
        out.add(row);
    }
  }
  return (out: out, back: back, movedOn: movedOn);
}

/// The green line under a card in the Returned tab: the whole send came
/// back, or — when only part of it did — how many of its items did.
/// [shown] is the number of returned rows on the card, [sendTotal] how
/// many items the send had altogether.
String returnedBannerText(int shown, int sendTotal) {
  if (shown >= sendTotal) return 'Back in inventory';
  if (shown == 1) return 'Only this item came back from this send';
  return '$shown of $sendTotal items came back from this send';
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
    purchasePrice: (row['purchase_price'] as num?)?.toDouble(),
    needsReview: row['needs_review'] == 1,
    reviewKind: row['review_kind'] as String?,
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
      'catalog_product_id, vendor_id, purchase_price, batches(code)';
  const linked = 'assigned_machine_id, ';

  final batchIds = await _currentBatchIds();
  final batchFilter = _currentBatchOrFilter(batchIds);

  final machines = await _db
      .from('machines')
      .select('$fields, machine_id, model')
      .or(batchFilter)
      .order('id', ascending: false);
  final probes = await _db
      .from('probes')
      .select(
          '$fields, $linked box_id, needs_review, review_kind, catalog_products(probe_type), internal_id, model')
      .or(batchFilter)
      .order('id', ascending: false);
  final printers = await _db
      .from('printers')
      .select('$fields, $linked internal_id, name_model')
      .or(batchFilter)
      .order('id', ascending: false);
  // Parts are not batch-filtered — they live in BATCH-PARTS.
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

/// Reads every row a select matches. PostgREST answers at most 1000
/// rows per request, and the imported old stock is several times that —
/// a plain select silently drops every item past the first page, which
/// made their movements, pickers and repairs read "Unknown item".
Future<List<Map<String, dynamic>>> _fetchAllPages(
    PostgrestTransformBuilder<PostgrestList> Function() build) async {
  const pageSize = 1000;
  final rows = <Map<String, dynamic>>[];
  for (var from = 0;; from += pageSize) {
    final page = await build().range(from, from + pageSize - 1);
    rows.addAll(page.cast<Map<String, dynamic>>());
    if (page.length < pageSize) return rows;
  }
}

/// The imported old stock as items, so the movement picker, item
/// labels, box sheet and returns cover both sides with one list. Only
/// the display fields a movement needs are loaded — thousands of rows
/// come in with the import, so the query stays light.
final oldStockItemsProvider = FutureProvider<List<InventoryItem>>((ref) async {
  final pages = await Future.wait([
    _fetchAllPages(() => _db
        .from('machines')
        .select(
            'id, machine_id, model, serial_number, status, current_location')
        .eq('batch_id', kOldBatchId)
        .order('id', ascending: false)),
    _fetchAllPages(() => _db
        .from('probes')
        .select('id, internal_id, model, serial_number, status, '
            'current_location, box_id')
        .eq('batch_id', kOldBatchId)
        .order('id', ascending: false)),
    _fetchAllPages(() => _db
        .from('printers')
        .select(
            'id, internal_id, name_model, serial_number, status, current_location')
        .eq('batch_id', kOldBatchId)
        .order('id', ascending: false)),
  ]);
  final machines = pages[0];
  final probes = pages[1];
  final printers = pages[2];
  InventoryItem oldItem(String kind, Map<String, dynamic> row,
      {required String codeField, required String nameField}) {
    return InventoryItem(
      kind: kind,
      id: row['id'] as int,
      code: '${row[codeField] ?? ''}',
      name: '${row[nameField] ?? ''}',
      serial: row['serial_number'] as String?,
      status: '${row['status'] ?? ''}',
      location: '${row['current_location'] ?? ''}',
      batch: 'BATCH-OLD',
      boxId: kind == 'probe' ? row['box_id'] as int? : null,
    );
  }

  return [
    for (final row in machines)
      oldItem('machine', row, codeField: 'machine_id', nameField: 'model'),
    for (final row in probes)
      oldItem('probe', row, codeField: 'internal_id', nameField: 'model'),
    for (final row in printers)
      oldItem('printer', row, codeField: 'internal_id', nameField: 'name_model'),
  ];
});

/// Every item a movement can touch — current stock plus the imported
/// old stock — so pickers, labels, returns and detail sheets cover both
/// sides with one list. Old rows failing to load never breaks the new
/// side: it just narrows to current stock.
final allItemsProvider = FutureProvider<List<InventoryItem>>((ref) async {
  final current = await ref.watch(inventoryProvider.future);
  List<InventoryItem> old;
  try {
    old = await ref.watch(oldStockItemsProvider.future);
  } catch (_) {
    old = const <InventoryItem>[];
  }
  return [...current, ...old];
});

/// `machine:12` -> label used by the movement list
final itemLabelsProvider = Provider<Map<String, String>>((ref) {
  final items = ref.watch(allItemsProvider).maybeWhen(
        data: (rows) => rows,
        orElse: () => const <InventoryItem>[],
      );
  return labelsForItems(items);
});

/// The `kind:id` -> "CODE  name" map the movement list and the sales
/// screen read item names from.
Map<String, String> labelsForItems(List<InventoryItem> items) {
  return {
    for (final item in items) item.key: '${item.code}  ${item.title}',
  };
}

// ---------------------------------------------------------------------------
// movements + sales
// ---------------------------------------------------------------------------

/// Every current movement. Imported Legacy history (old stock) is
/// excluded at the query level so no screen can leak it — item history,
/// return checks and group counts all read this. [movementsProvider]
/// derives from it for display.
final allMovementsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await _db
      .from('movements')
      .select(
        'id, group_ref, movement_type, movement_date, to_location, from_location, '
        'reason, notes, reference, is_demo, paid, sale_amount, created_at, actor_id, machine_id, '
        'probe_id, printer_id, part_id, dealer_id, customer_id, workshop_id, old_source_id, '
        'dealers(name), customers(name), '
        'workshops(name), profiles(display_name, username)',
      )
      .neq('movement_type', 'Legacy')
      .order('id', ascending: false);
  rows.sort((a, b) {
    final byDate = (_parseDate(b['movement_date']) ?? DateTime(0))
        .compareTo(_parseDate(a['movement_date']) ?? DateTime(0));
    return byDate != 0 ? byDate : (b['id'] as int).compareTo(a['id'] as int);
  });
  return rows;
});

/// The movement list shown on the Movements screen: current-side sends
/// and returns only. Imported old-side rows live in the old-data side;
/// box moves and the old part movements stay in item history but are
/// not listed here.
final movementsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref.watch(allMovementsProvider.future);
  return [
    for (final row in rows)
      if (!isOldSideImport(row) && !isOldSideMovement(row) && !isBoxMovement(row))
        row
  ];
});

/// Puts an item back into stock from wherever it is: status and location
/// are restored and a 'Return' movement records when it came back.
/// [date] is dd-MM-yyyy (defaults to today) and [notes] is free text —
/// both let a partial return say when and why items came back.
Future<int> returnToInventory(InventoryItem item,
    {String? date, String? notes}) async {
  return await _db.rpc('return_to_inventory', params: {
    'p_item_type': item.kind,
    'p_item_id': item.id,
    if (date != null && date.isNotEmpty) 'p_date': date,
    if (notes != null && notes.isNotEmpty) 'p_notes': notes,
  }) as int;
}

/// Erases a whole send: its movement rows (and the Return rows that
/// belong to them) disappear, every item takes its status and location
/// from the history that is left, and a customer/dealer added with this
/// send goes too when nothing else uses it. Only the sender or an admin
/// may (enforced by the RPC).
Future<void> deleteMovement(int movementId) async {
  await _db.rpc('delete_movement', params: {'p_movement_id': movementId});
}

/// Erases a single movement row — the rest of the send keeps its rows
/// and the item takes its status from the history that is left, so an
/// accidental move falls out of the record. Only the sender or an admin
/// may (enforced by the RPC).
Future<void> deleteMovementRow(int movementId) async {
  await _db.rpc('delete_movement_row', params: {'p_movement_id': movementId});
}

/// Rewrites the date of a whole send — every row passed in takes the
/// same [date] (dd-MM-yyyy). Only admins may (enforced by RLS).
Future<void> setMovementDate(Iterable<int> movementIds, String date) async {
  await _db
      .from('movements')
      .update({'movement_date': date})
      .inFilter('id', movementIds.toList());
}

/// Marks a whole send paid or unpaid — every row of its group takes the
/// same flag, so the send reads as one settlement. Only admins may
/// (enforced by RLS).
Future<void> setSendPaid(List<Map<String, dynamic>> rows, bool paid) async {
  await _updateSend(rows, {'paid': paid});
}

/// Flips the sold mark on a whole send: on, the reason reads 'Sold' and
/// the item's history shows "Sold to X" — with [amount] as the sale
/// amount when one was given; off, the original wording goes back and
/// the amount is cleared. A label only — the items keep their status.
/// Only admins may (enforced by RLS).
Future<void> setSendSold(List<Map<String, dynamic>> rows, bool sold,
    {double? amount}) async {
  final first = rows.first;
  final kind = '${first['movement_type'] ?? ''}';
  await _updateSend(rows, {
    'reason':
        sold ? 'Sold' : sendReason(kind, demo: first['is_demo'] == true),
    'sale_amount': sold ? amount : null,
  });
}

/// Rewrites the notes of a whole send — every row of its group takes
/// the same text, the way the new-movement form writes one note for
/// the whole send. Only admins may (enforced by RLS).
Future<void> setMovementNotes(
    List<Map<String, dynamic>> rows, String notes) async {
  await _updateSend(rows, {'notes': notes.isEmpty ? null : notes});
}

/// One update for the whole send: by group when the rows share one
/// (Return rows carry their own group, box rows have none, so neither
/// is ever caught here), row by row for the ungrouped legacy rows.
Future<void> _updateSend(
    List<Map<String, dynamic>> rows, Map<String, Object?> values) async {
  final group = '${rows.first['group_ref'] ?? ''}';
  if (group.isNotEmpty) {
    await _db.from('movements').update(values).eq('group_ref', group);
    return;
  }
  for (final row in rows) {
    await _db.from('movements').update(values).eq('id', row['id'] as int);
  }
}

// ---------------------------------------------------------------------------
// Flags: one colored dot (with an optional note) per flagged thing — an
// inventory item, a single movement row, a whole send or a repair job.
// Only admins write them (RLS); everybody sees them.
// ---------------------------------------------------------------------------

final flagsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await _db
      .from('flags')
      .select(
          'id, item_kind, item_id, movement_id, repair_id, group_ref, '
          'color, note, created_by, created_at')
      .order('id', ascending: false);
  return rows;
});

/// The reusable flag library: a description + color, defined once in
/// Records and reused anywhere a flag can be applied. Applying copies
/// both onto the flag row, so deleting an entry never removes flags
/// already in use.
final flagDefsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final rows = await _db
      .from('flag_defs')
      .select('id, name, color, created_by, created_at')
      .order('id', ascending: false);
  return rows;
});

/// Creates or updates one library flag. Admins only (enforced by RLS).
Future<void> saveFlagDef(
    {int? id, required String name, required String color}) async {
  if (id == null) {
    await _db.from('flag_defs').insert({'name': name, 'color': color});
  } else {
    await _db
        .from('flag_defs')
        .update({'name': name, 'color': color})
        .eq('id', id);
  }
}

/// Removes a library flag — flags already applied keep their copy.
Future<void> deleteFlagDef(int id) async {
  await _db.from('flag_defs').delete().eq('id', id);
}

String flagItemKey(String kind, int id) => 'item:$kind:$id';

String flagRowKey(int movementId) => 'row:$movementId';

String flagRepairKey(int repairId) => 'repair:$repairId';

/// The value a whole send's flag stores in flags.group_ref — the send's
/// own group_ref, or `row:` plus the row's id when it travelled without
/// one.
String sendGroupValue(Map<String, dynamic> movementRow) {
  final group = (movementRow['group_ref'] ?? '').toString();
  return group.isEmpty ? 'row:${movementRow['id']}' : group;
}

/// Lookup key of a whole send's flag.
String flagSendKey(Map<String, dynamic> movementRow) =>
    'send:${sendGroupValue(movementRow)}';

String? flagKeyOf(Map<String, dynamic> flag) {
  if (flag['item_id'] != null) {
    return flagItemKey('${flag['item_kind']}', flag['item_id'] as int);
  }
  if (flag['movement_id'] != null) {
    final group = (flag['group_ref'] ?? '').toString();
    return group.isEmpty
        ? flagRowKey(flag['movement_id'] as int)
        : 'send:$group';
  }
  if (flag['repair_id'] != null) {
    return flagRepairKey(flag['repair_id'] as int);
  }
  return null;
}

/// Every flag of each target — rows arrive newest first, so each list
/// is newest first. One item / movement / repair can carry several
/// flags at once.
Map<String, List<Map<String, dynamic>>> flagIndex(
    List<Map<String, dynamic>> flags) {
  final byKey = <String, List<Map<String, dynamic>>>{};
  for (final flag in flags) {
    final key = flagKeyOf(flag);
    if (key != null) (byKey[key] ??= []).add(flag);
  }
  return byKey;
}

/// How a group of flags on one target reads aloud — the joined notes,
/// or 'Flagged' when none carries one.
String flagLabel(List<Map<String, dynamic>> flags) {
  final notes = [
    for (final flag in flags)
      if ('${flag['note'] ?? ''}'.trim().isNotEmpty) '${flag['note']}'.trim(),
  ];
  return notes.isEmpty ? 'Flagged' : notes.join(', ');
}

/// One flag's reading: its note, or 'Flagged' when none is written.
String flagNoteText(Map<String, dynamic> flag) {
  final note = '${flag['note'] ?? ''}'.trim();
  return note.isEmpty ? 'Flagged' : note;
}

/// Adds a flag to [target] — flags already on it stay put, so one thing
/// can carry several. [target] holds item_kind+item_id, or movement_id
/// (plus group_ref when the whole send is flagged), or repair_id.
Future<void> setFlag(Map<String, dynamic> target,
    {required String color, String? note}) async {
  await _db.from('flags').insert({
    ...target,
    'color': color,
    if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
  });
}

/// Removes one flag by its id — the target's other flags stay.
Future<void> deleteFlag(int id) async {
  await _db.from('flags').delete().eq('id', id);
}

/// Deletes a customer/dealer together with the sends that point at it —
/// admin only, blocked while sales or repairs still use the record.
Future<void> deleteParty(String table, int id) async {
  await _db.rpc('delete_party', params: {'p_table': table, 'p_id': id});
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
/// The sales recorded against a customer (via customer_id).
final customerSalesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, name) async {
  // Look the customer up by name so the sheet can be opened from the people
  // list (which is keyed by name, not id).
  final party = await _db
      .from('customers')
      .select('id')
      .ilike('name', name)
      .limit(1);
  if (party.isEmpty) return const <Map<String, dynamic>>[];
  final rows = await _db
      .from('sales')
      .select(
        'id, sale_date, invoice_reference, sale_price, notes, old_source_id, old_trno, '
        'sale_items(item_description, item_serial, item_price, item_type, '
        'machines(machine_id, model), '
        'probes(internal_id, model), printers(internal_id, name_model), '
        'parts(internal_id, name_model))',
      )
      .eq('customer_id', party.first['id'] as int);
  return _sortSales(rows);
});

/// The sales whose party tag names this dealer (imported legacy rows have no
/// customer_id, only a `party:dealer:NAME` line in notes).
final dealerSalesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, name) async {
  final rows = await _db
      .from('sales')
      .select(
        'id, sale_date, invoice_reference, sale_price, notes, old_source_id, old_trno, '
        'sale_items(item_description, item_serial, item_price, item_type, '
        'machines(machine_id, model), '
        'probes(internal_id, model), printers(internal_id, name_model), '
        'parts(internal_id, name_model))',
      )
      .like('notes', 'party:dealer:${name.toUpperCase()}%');
  return _sortSales(rows);
});

/// sale_date is dd-MM-yyyy text, so a server-side order() would sort
/// lexicographically ("06-10-2026" before "01-01-2026"); newest first
/// is done here on the parsed date instead.
List<Map<String, dynamic>> _sortSales(List<Map<String, dynamic>> rows) {
  rows.sort((a, b) {
    final byDate = (_parseDate(b['sale_date']) ?? DateTime(0))
        .compareTo(_parseDate(a['sale_date']) ?? DateTime(0));
    return byDate != 0 ? byDate : (b['id'] as int).compareTo(a['id'] as int);
  });
  return rows;
}

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
      ref.refresh(allMovementsProvider.future),
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
        'delivered_by, accessories_received, condition_on_arrival, '
        'estimated_cost, final_cost, money_received, money_received_by, '
        'created_at, customer_id, customers(name), '
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

/// Marks a repair as fixed and handed back — with the money that came
/// over the counter at that moment and whoever took it.
Future<void> repairSentBack({
  required int id,
  required String returnedAt,
  String? collectedBy,
  String? notes,
  double? moneyReceived,
  String? receivedBy,
}) async {
  await _db
      .from('repair_jobs')
      .update({
        'status': 'Returned',
        'returned_at': returnedAt,
        if (collectedBy != null && collectedBy.isNotEmpty)
          'collected_by': collectedBy,
        if (notes != null && notes.isNotEmpty) 'repair_notes': notes,
        'money_received': ?moneyReceived,
        if (receivedBy != null && receivedBy.isNotEmpty)
          'money_received_by': receivedBy,
      })
      .eq('id', id);
}

/// The payment line of a returned repair — "5000 — received by Ahmed",
/// or '' when the return carried no money record.
String repairMoneyText(Map<String, dynamic> job) {
  final raw = job['money_received'];
  final amount = raw == null ? null : double.tryParse('$raw');
  if (amount == null || amount == 0) return '';
  final shown = amount == amount.roundToDouble()
      ? amount.toInt().toString()
      : '$amount';
  final by = (job['money_received_by'] ?? '').toString().trim();
  return by.isEmpty ? shown : '$shown — received by $by';
}

/// Edits a repair job and reconciles its item list: lines carrying an id
/// are updated in place, new lines are inserted, lines left out of the
/// list are deleted. Only this job's own rows are touched.
Future<void> updateRepair({
  required int id,
  required String customerName,
  String? contact,
  required String receivedAt,
  String? problem,
  String? deliveredBy,
  String? accessories,
  String? condition,
  double? estimatedCost,
  double? finalCost,
  String? repairNotes,
  required String status,
  String? returnedAt,
  String? collectedBy,
  String? returnNotes,
  double? moneyReceived,
  String? receivedBy,
  required List<Map<String, dynamic>> items,
}) async {
  // a renamed sender moves the job to that customer (created if new)
  final customerId = await resolveReferenceId(
      table: 'customers',
      name: customerName,
      payload: {'customer_type': 'Customer'});

  String? nullable(String text) => text.trim().isEmpty ? null : text.trim();

  await _db.from('repair_jobs').update({
    'customer_id': customerId,
    'customer_contact': nullable(contact ?? ''),
    'received_at': receivedAt,
    'problem_description': problem?.trim() ?? '',
    'delivered_by': nullable(deliveredBy ?? ''),
    'accessories_received': nullable(accessories ?? ''),
    'condition_on_arrival': nullable(condition ?? ''),
    'estimated_cost': estimatedCost,
    'final_cost': finalCost,
    'repair_notes': nullable(repairNotes ?? ''),
    'status': status,
    // the return details belong to a returned job only
    if (status == 'Returned') ...{
      'returned_at': nullable(returnedAt ?? ''),
      'collected_by': nullable(collectedBy ?? ''),
      'return_notes': nullable(returnNotes ?? ''),
      'money_received': moneyReceived,
      'money_received_by': nullable(receivedBy ?? ''),
    },
  }).eq('id', id);

  final keep = <int>{};
  for (final item in items) {
    final serial = '${item['serial'] ?? ''}'.trim();
    final row = {
      'equipment_type': '${item['type'] ?? 'machine'}',
      'name_model': '${item['model'] ?? ''}',
      'serial_number': serial.isEmpty ? null : serial,
      'quantity': 1,
    };
    final itemId = item['id'];
    if (itemId is int) {
      await _db.from('repair_items').update(row).eq('id', itemId);
      keep.add(itemId);
    } else {
      final inserted = await _db
          .from('repair_items')
          .insert({...row, 'repair_job_id': id})
          .select('id')
          .single();
      keep.add(inserted['id'] as int);
    }
  }
  final existing =
      await _db.from('repair_items').select('id').eq('repair_job_id', id);
  for (final row in existing) {
    final itemId = row['id'] as int;
    if (!keep.contains(itemId)) {
      await _db.from('repair_items').delete().eq('id', itemId);
    }
  }
}

/// Removes a repair job and its items — only this job's own rows.
Future<void> deleteRepair(int id) async {
  await _db.from('repair_items').delete().eq('repair_job_id', id);
  await _db.from('repair_jobs').delete().eq('id', id);
}

/// Puts a leftover probe into a box: it comes off its machine, becomes
/// Available, the box becomes its location, and a 'Box' movement is
/// written so the probe's history shows when it went in.
Future<void> putProbeInBox(InventoryItem probe, Map<String, dynamic> box) async {
  final boxName = (box['name'] ?? '').toString();
  final from = probe.location;
  await _db.from('probes').update({
    'box_id': box['id'],
    'assigned_machine_id': null,
    'status': 'Available',
    'current_location': boxName,
  }).eq('id', probe.id);
  await _db.from('movements').insert({
    'movement_type': 'Box',
    'movement_date': movementToday(),
    'probe_id': probe.id,
    'from_location': from,
    'to_location': boxName,
    'actor_id': _db.auth.currentUser?.id,
  });
}

/// Takes the probe back out of the box; it stays in stock at the company
/// and an 'Unbox' movement records the removal.
Future<void> takeProbeOutOfBox(InventoryItem probe) async {
  final from = probe.location;
  final to = defaultLocationFor('Available');
  await _db.from('probes').update({
    'box_id': null,
    'current_location': to,
  }).eq('id', probe.id);
  await _db.from('movements').insert({
    'movement_type': 'Unbox',
    'movement_date': movementToday(),
    'probe_id': probe.id,
    'from_location': from,
    'to_location': to,
    'actor_id': _db.auth.currentUser?.id,
  });
}

/// Probes that may be added to [box]. Any probe type fits any box — the
/// box's probe_type is just a label — and a probe that currently sits
/// With Machine is included so it can be taken off its machine and boxed
/// by searching its serial. Sold / Archived / With Customer probes and
/// probes already in a box are excluded.
List<InventoryItem> boxAddCandidates(
    List<InventoryItem> items, Map<String, dynamic> box) {
  return items.where((item) {
    if (item.kind != 'probe') return false;
    if (item.status == 'Sold' ||
        item.status == 'Archived' ||
        item.status == 'With Customer') {
      return false;
    }
    if (item.boxId != null) return false;
    return true;
  }).toList();
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
    ? const [
        'In Stock',
        'With Workshop',
        'With Branch',
        'With Dealer',
        'With Customer',
        'Sold',
        'Archived',
      ]
    : const [
        'Available',
        'With Machine',
        'With Workshop',
        'With Branch',
        'With Dealer',
        'With Customer',
        'Sold',
        'Archived',
      ];

String defaultStatus(String kind) =>
    kind == 'machine' ? 'In Stock' : 'Available';

String defaultLocationFor(String status) => switch (status) {
      'With Workshop' => 'Workshop',
      'With Branch' => 'Lahore branch',
      'With Dealer' => 'Dealer',
      'With Customer' => 'Customer',
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
