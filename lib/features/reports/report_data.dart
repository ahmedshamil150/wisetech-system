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

/// Movement rows for the report: the imported old-side rows never count
/// (they carry an [old_source_id] and belong to the old-data side),
/// [kind] narrows the type — 'All' means every send and return except
/// the box moves (those have their own report), 'Box moves' means only
/// them — and the movement date must sit inside the range.
List<Map<String, dynamic>> filterMovementRows(
  List<Map<String, dynamic>> rows, {
  required String kind,
  required DateTime from,
  required DateTime to,
}) {
  return [
    for (final row in rows)
      if (row['old_source_id'] == null &&
          (row['movement_type'] ?? '').toString() != 'Legacy' &&
          switch (kind) {
            'All' => !isBoxMovement(row),
            'Box moves' => isBoxMovement(row),
            _ => row['movement_type'] == kind,
          } &&
          dateInRange('${row['movement_date'] ?? ''}', from, to))
        row,
  ];
}

/// Repair jobs whose received date sits inside the range — the same
/// "when it came in" rule the stock reports use, so a month's report
/// is everything that arrived that month. Jobs without a readable
/// received date never match.
List<Map<String, dynamic>> filterRepairRows(
  List<Map<String, dynamic>> rows, {
  required DateTime from,
  required DateTime to,
}) {
  return [
    for (final row in rows)
      if (dateInRange('${row['received_at'] ?? ''}', from, to)) row,
  ];
}

/// The PDF's built-in fonts only draw Latin-1 — anything else (em
/// dashes, curly quotes, Arabic …) would print as a cross-in-a-box.
/// Turn those into characters the report can actually show.
String pdfText(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune == 0x2013 || rune == 0x2014) {
      buffer.write('-');
    } else if (rune == 0x2018 || rune == 0x2019) {
      buffer.write("'");
    } else if (rune == 0x201C || rune == 0x201D) {
      buffer.write('"');
    } else if (rune == 0x2026) {
      buffer.write('...');
    } else if (rune == 0x0A || rune == 0x09 || (rune >= 0x20 && rune <= 0xFF)) {
      buffer.writeCharCode(rune);
    } else {
      buffer.write('?');
    }
  }
  return buffer.toString();
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

/// One repair table row — the job's whole story: when it came in and
/// went out, whose it is, what it was, who handled it and the costs.
List<String> repairReportRow(Map<String, dynamic> row) {
  final items = [
    for (final item in (row['repair_items'] as List? ?? const []))
      if (item is Map)
        [
          '${item['name_model'] ?? ''}',
          if ('${item['serial_number'] ?? ''}'.isNotEmpty)
            '(${item['serial_number']})',
        ].join(' '),
  ];
  final notes = [
    '${row['repair_notes'] ?? ''}',
    '${row['return_notes'] ?? ''}',
  ].where((text) => text.trim().isNotEmpty).join(' · ');
  return [
    '${row['job_number'] ?? ''}',
    '${row['received_at'] ?? ''}',
    _joinName(row['customers']),
    items.join('; '),
    '${row['problem_description'] ?? ''}',
    '${row['status'] ?? ''}',
    '${row['returned_at'] ?? ''}',
    '${row['collected_by'] ?? ''}',
    _actorName(row['profiles']),
    row['estimated_cost'] == null ? '' : '${row['estimated_cost']}',
    row['final_cost'] == null ? '' : '${row['final_cost']}',
    notes,
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

const kRepairColumns = [
  'Job', 'Received', 'Customer', 'Items', 'Problem', 'Status',
  'Returned', 'Collected by', 'By', 'Est. cost', 'Final cost', 'Notes',
];
