import '../data/data.dart';

/// Parses a stored date — `dd-MM-yyyy` (the shop's format) or ISO —
/// into a date-only [DateTime], or null for empty or junk.
DateTime? reportDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.trim();
  final iso = DateTime.tryParse(text);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final parts = text.split('-');
  if (parts.length != 3) return null;
  final day = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final year = int.tryParse(parts[2]);
  if (day == null || month == null || year == null) return null;
  return DateTime(year, month, day);
}

/// Whether a stored date sits inside [from]..[to], both ends included.
/// Rows without a readable date never match.
bool dateInRange(String? raw, DateTime from, DateTime to) {
  final date = reportDate(raw);
  if (date == null) return false;
  return !date.isBefore(from) && !date.isAfter(to);
}

/// Stock inside the acquired-date range — current stock only: sold
/// items stay out (parts aside, they move after a sale), items without
/// a date stay out. [kind] narrows further to 'Machines' or 'Probes';
/// 'All stock' keeps every kind.
List<InventoryItem> filterStockItems(
  List<InventoryItem> items, {
  required String kind,
  required DateTime from,
  required DateTime to,
}) {
  return [
    for (final item in items)
      if (!(item.isSold && item.kind != 'part') &&
          (kind == 'All stock' ||
              (kind == 'Machines' && item.kind == 'machine') ||
              (kind == 'Probes' && item.kind == 'probe')) &&
          dateInRange(item.date, from, to))
        item,
  ];
}

/// Movement rows for the report: the imported legacy rows never count,
/// [kind] ('All', 'Workshop', 'Dealer' or 'Customer') narrows the type,
/// and the movement date must sit inside the range.
List<Map<String, dynamic>> filterMovementRows(
  List<Map<String, dynamic>> rows, {
  required String kind,
  required DateTime from,
  required DateTime to,
}) {
  return [
    for (final row in rows)
      if ((row['movement_type'] ?? '').toString() != 'Legacy' &&
          (kind == 'All' || row['movement_type'] == kind) &&
          dateInRange('${row['movement_date'] ?? ''}', from, to))
        row,
  ];
}

String _joinName(Object? join) =>
    join is Map ? '${join['name'] ?? ''}' : '';

String _actorName(Object? join) => join is Map
    ? '${join['display_name'] ?? join['username'] ?? ''}'
    : '';

/// One stock table row: the shared columns first, then (for 'All
/// stock') the kind, box, probe type and assigned machine.
List<String> stockReportRow(
  InventoryItem item, {
  required bool single,
  required Map<int, String> vendors,
  required Map<int, String> boxes,
  required Map<String, String> labels,
}) {
  final shared = [
    item.code,
    item.title,
    item.serial ?? '',
    item.status,
    item.location,
    item.date ?? '',
    item.batch ?? '',
    vendors[item.vendorId] ?? '',
    item.purchasePrice == null ? '' : '${item.purchasePrice}',
  ];
  if (single) return shared;
  return [
    item.kindLabel,
    ...shared,
    item.boxId == null ? '' : (boxes[item.boxId] ?? 'Box #${item.boxId}'),
    item.probeType ?? '',
    item.assignedMachineId == null
        ? ''
        : (labels['machine:${item.assignedMachineId}'] ?? ''),
  ];
}

/// One box table row: the box itself plus the probes sitting in it
/// right now — how many, and their serials.
List<String> boxReportRow(
  Map<String, dynamic> box, {
  required List<InventoryItem> items,
}) {
  final inside = [
    for (final item in items)
      if (item.kind == 'probe' && item.boxId == box['id'] && !item.isSold)
        item,
  ];
  return [
    '${box['name'] ?? ''}',
    '${box['probe_type'] ?? ''}',
    '${inside.length}',
    inside.map((probe) => probe.serial ?? probe.code).join(', '),
    '${box['notes'] ?? ''}',
  ];
}

/// One movement table row — every field the movement carries, with the
/// party (dealer / customer / workshop), the person who recorded it and
/// the item labels filled in from their joins.
List<String> movementReportRow(
  Map<String, dynamic> row, {
  required Map<String, String> labels,
}) {
  final type = (row['movement_type'] ?? '').toString();
  final items = [
    for (final field in ['machine', 'probe', 'printer', 'part'])
      if (row['${field}_id'] != null)
        labels['$field:${row['${field}_id']}'] ?? '$field #${row['${field}_id']}',
  ];
  final party = switch (type) {
    'Dealer' => _joinName(row['dealers']),
    'Customer' => _joinName(row['customers']),
    'Workshop' => _joinName(row['workshops']),
    _ => '',
  };
  return [
    '${row['movement_date'] ?? ''}',
    type,
    items.join('; '),
    '${row['from_location'] ?? ''}',
    '${row['to_location'] ?? ''}',
    party,
    _actorName(row['profiles']),
    '${row['reason'] ?? ''}',
    '${row['reference'] ?? ''}',
    '${row['notes'] ?? ''}',
    row['is_demo'] == true ? 'Yes' : '',
  ];
}

const kStockColumnsAll = [
  'Type', 'Code', 'Name', 'Serial', 'Status', 'Location', 'Acquired',
  'Batch', 'Vendor', 'Price', 'Box', 'Probe type', 'Machine',
];

const kStockColumnsSingle = [
  'Code', 'Name', 'Serial', 'Status', 'Location', 'Acquired', 'Batch',
  'Vendor', 'Price',
];

const kMovementColumns = [
  'Date', 'Type', 'Item(s)', 'From', 'To', 'Party', 'By', 'Reason',
  'Reference', 'Notes', 'Demo',
];

const kBoxColumns = [
  'Name', 'Probe type', 'Probes inside', 'Serials inside', 'Notes',
];
