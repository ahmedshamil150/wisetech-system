import '../data/data.dart';
import '../sales/sales_screen.dart';

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

/// A date as the shop writes it, whatever shape it was stored in.
String reportDateText(String? raw) {
  final date = reportDate(raw);
  if (date == null) return (raw ?? '').trim();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}-${two(date.month)}-${date.year}';
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

/// The movement types that make up "all movements": dealer, branch and
/// customer sends. Workshop sends have their own report; returns and
/// box moves are item history, not sends.
const kMovementSendTypes = ['Dealer', 'Branch', 'Customer'];

/// Movement rows for the report, exactly the sends the Movements screen
/// lists: the imported old-side rows never count (they carry an
/// [old_source_id] and belong to the old-data side), Legacy rows never
/// count, returns and box moves are not sends — [kind] narrows the type,
/// where 'All' means every send and 'Box moves' the box history only —
/// and the movement date must sit inside the range.
List<Map<String, dynamic>> filterMovementRows(
  List<Map<String, dynamic>> rows, {
  required String kind,
  required DateTime from,
  required DateTime to,
}) {
  return [
    for (final row in rows)
      if (!isOldSideImport(row) &&
          !isOldSideMovement(row) &&
          _movementReportMatch(row, kind) &&
          dateInRange('${row['movement_date'] ?? ''}', from, to))
        row,
  ];
}

bool _movementReportMatch(Map<String, dynamic> row, String kind) {
  final type = (row['movement_type'] ?? '').toString();
  if (type == 'Legacy') return false;
  if (kind == 'Returns') return type == 'Return';
  if (type == 'Return') return false;
  final box = isBoxMovement(row);
  if (kind == 'Box moves') return box;
  if (box) return false;
  if (kind == 'All') return kMovementSendTypes.contains(type);
  return type == kind;
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

/// One send per report row: rows recorded together share their group,
/// and a row with no group (old imports) is a send of its own. Order
/// follows the rows given.
List<List<Map<String, dynamic>>> reportSendGroups(
    List<Map<String, dynamic>> rows) {
  final order = <String>[];
  final byKey = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    final key = movementSendKey(row);
    if (!byKey.containsKey(key)) order.add(key);
    byKey.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(row);
  }
  return [for (final key in order) byKey[key]!];
}

/// An amount with thousands separators; whole amounts lose the '.0'.
String reportMoney(double? amount) {
  if (amount == null) return '';
  final whole = amount == amount.roundToDouble();
  final text = whole ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2);
  final negative = text.startsWith('-');
  final digits = negative ? text.substring(1) : text;
  final dot = digits.indexOf('.');
  final intPart = dot < 0 ? digits : digits.substring(0, dot);
  final rest = dot < 0 ? '' : digits.substring(dot);
  final buffer = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write(',');
    buffer.write(intPart[i]);
  }
  return '${negative ? '-' : ''}$buffer$rest';
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

/// The report's label for an item: its name first, with the serial in
/// brackets — how the shop reads equipment on the phone. Old imported
/// items count too: a report names every item it can.
String reportItemLabel(InventoryItem item) =>
    (item.serial == null || item.serial!.isEmpty)
        ? item.name
        : '${item.name} (${item.serial})';

/// `kind:id` -> [reportItemLabel] for every item a report can name —
/// current stock and the imported old stock alike.
Map<String, String> reportItemLabels(Iterable<InventoryItem> items) =>
    {for (final item in items) item.key: reportItemLabel(item)};

int _movementRank(Map<String, dynamic> row) {
  if (row['machine_id'] != null) return 0;
  if (row['printer_id'] != null) return 1;
  if (row['probe_id'] != null) return 2;
  if (row['part_id'] != null) return 3;
  return 4;
}

/// One movement table row per send — the unit the app writes and reads
/// in. The items are written name-first with their serial, in the order
/// the app lists them (machine first), and the party only fills the
/// destination when the location itself is blank.
List<String> movementReportRow(
  List<Map<String, dynamic>> sendRows, {
  required Map<String, String> labels,
}) {
  final rows = [...sendRows]
    ..sort((a, b) {
      final byRank = _movementRank(a).compareTo(_movementRank(b));
      return byRank != 0
          ? byRank
          : (a['id'] as int).compareTo(b['id'] as int);
    });
  final first = rows.first;
  final type = (first['movement_type'] ?? '').toString();
  final items = <String>[];
  for (final row in rows) {
    final key = movementItemKey(row);
    final label = key == null ? null : labels['${key.key}:${key.value}'];
    items.add(label == null || label.isEmpty ? 'Unknown item' : label);
  }
  final party = switch (type) {
    'Dealer' => _joinName(first['dealers']),
    'Customer' => _joinName(first['customers']),
    'Workshop' => _joinName(first['workshops']),
    _ => '',
  };
  final to = '${first['to_location'] ?? ''}'.trim();
  // the sold mark, its amount and the seller sit on the row that was
  // marked sold — not always the send's first row
  Map<String, dynamic>? soldRow;
  for (final row in rows) {
    if (movementSold(row)) {
      soldRow = row;
      break;
    }
  }
  final notes = rows
      .map((row) => '${row['notes'] ?? ''}'.trim())
      .firstWhere((note) => note.isNotEmpty, orElse: () => '');
  return [
    reportDateText('${first['movement_date'] ?? ''}'),
    type,
    items.join('; '),
    to.isEmpty ? party : to,
    soldRow == null ? '' : 'Sold',
    soldRow == null ? '' : reportMoney(soldAmountOf(soldRow)),
    isOutboundKind(type) ? (rows.any(movementPaid) ? 'Paid' : 'Unpaid') : '',
    _actorName(first['profiles']),
    notes,
  ];
}

/// The notes of a recorded sale without the import's own party tags —
/// they describe the buyer, and the Buyer column already says it.
String saleReportNotes(Map<String, dynamic> row) {
  final kept = <String>[];
  for (final line in '${row['notes'] ?? ''}'.split('\n')) {
    final text = line.trim();
    if (text.isEmpty) continue;
    if (text.startsWith('party:')) continue;
    if (text.contains('Unknown legacy customer')) continue;
    kept.add(text);
  }
  return kept.join(' · ');
}

/// The item a recorded sale line points at, as `kind:id`.
String? _saleLineKey(Map line) {
  for (final kind in const ['machine', 'probe', 'printer', 'part']) {
    final id = line['${kind}_id'];
    if (id is int) return '$kind:$id';
  }
  return null;
}

/// What was sold on a recorded sale, written name-first with its serial:
/// the linked item's name when the line points at stock, otherwise the
/// imported description followed by the serial the old system stored.
String _saleItemsText(Map<String, dynamic> row, Map<String, String> labels) {
  final lines = (row['sale_items'] as List?)?.cast<Map>() ?? const [];
  final parts = <String>[];
  for (final line in lines) {
    final key = _saleLineKey(line);
    final label = key == null ? null : labels[key];
    if (label != null && label.isNotEmpty) {
      parts.add(label);
      continue;
    }
    final description = '${line['item_description'] ?? ''}'.trim();
    if (description.isEmpty) continue;
    final serial = '${line['item_serial'] ?? ''}'.trim();
    parts.add(serial.isEmpty ? description : '$description ($serial)');
  }
  return parts.join(' · ');
}

/// One sales table row: a recorded sale (imported or not) or a send
/// marked Sold, with the amount it actually carries — old imported
/// sales only have line prices, and an empty amount means nothing was
/// recorded.
List<String> salesReportRow(
  SaleEntry entry, {
  Map<String, String> labels = const {},
}) {
  final invoice = [
    '${entry.row['invoice_reference'] ?? ''}'.trim(),
    '${entry.row['old_trno'] ?? ''}'.trim(),
  ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
  final note = entry.source == 'sale' ? saleReportNotes(entry.row) : '';
  final items = entry.source == 'sale'
      ? _saleItemsText(entry.row, labels)
      : entry.summary;
  return [
    reportDateText(entry.date),
    entry.buyer,
    items,
    reportMoney(entry.total),
    entry.soldBy,
    entry.source == 'sale' ? 'Paid' : (entry.paid ? 'Paid' : 'Unpaid'),
    invoice,
    note,
  ];
}

/// One repair table row — the job's whole story: when it came in and
/// went out, whose it is, what it was (name with its serial), the
/// problem, the status, the charge and the notes.
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
    row['final_cost'] == null ? '' : '${row['final_cost']}',
    notes,
  ];
}

/// One returned-item row: when it came back, what came back (name and
/// serial), where it came back from and to, who recorded it and why.
/// Each Return row is one item, so nothing is grouped here.
List<String> returnedReportRow(
  Map<String, dynamic> row, {
  required Map<String, String> labels,
}) {
  final key = movementItemKey(row);
  final label = key == null ? null : labels['${key.key}:${key.value}'];
  return [
    reportDateText('${row['movement_date'] ?? ''}'),
    label == null || label.isEmpty ? 'Unknown item' : label,
    '${row['from_location'] ?? ''}',
    '${row['to_location'] ?? ''}',
    _actorName(row['profiles']),
    '${row['notes'] ?? ''}'.trim(),
  ];
}

const kReturnColumns = [
  'Date', 'Item', 'From', 'To', 'By', 'Notes',
];

const kStockColumnsAll = [
  'Type', 'Code', 'Name', 'Serial', 'Status', 'Location', 'Acquired',
  'Batch', 'Vendor', 'Price', 'Box', 'Probe type', 'Machine',
];

const kStockColumnsSingle = [
  'Code', 'Name', 'Serial', 'Status', 'Location', 'Acquired', 'Batch',
  'Vendor', 'Price',
];

const kMovementColumns = [
  'Date', 'Type', 'Item(s)', 'To', 'Sold', 'Amount', 'Paid', 'By', 'Notes',
];

const kSalesColumns = [
  'Date', 'Buyer', 'Items', 'Amount', 'Sold by', 'Paid', 'Invoice', 'Notes',
];

const kBoxColumns = [
  'Name', 'Probe type', 'Probes inside', 'Serials inside', 'Notes',
];

const kRepairColumns = [
  'Job', 'Received', 'Customer', 'Items', 'Problem', 'Status', 'Returned',
  'Final cost', 'Notes',
];
