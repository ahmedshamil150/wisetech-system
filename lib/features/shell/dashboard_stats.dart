import '../data/data.dart';
import '../reports/report_data.dart';
import '../sales/sales_screen.dart';

/// The window the dashboard counts: `from`/`to` null means all time.
typedef DashPeriod = ({DateTime? from, DateTime? to, String label});

const DashPeriod dashAllTime = (from: null, to: null, label: 'All time');

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String dashMonthLabel(int year, int month) => '${_months[month - 1]} $year';

/// A calendar month — the running month stops at today, a past month
/// runs to its last day.
DashPeriod dashMonthPeriod(int year, int month, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final first = DateTime(year, month, 1);
  final current = year == today.year && month == today.month;
  final last = current
      ? DateTime(today.year, today.month, today.day)
      : DateTime(year, month + 1, 0);
  return (from: first, to: last, label: dashMonthLabel(year, month));
}

DashPeriod dashThisMonth([DateTime? now]) {
  final today = now ?? DateTime.now();
  return dashMonthPeriod(today.year, today.month, now: today);
}

DashPeriod dashLastMonth([DateTime? now]) {
  final today = now ?? DateTime.now();
  final month = DateTime(today.year, today.month - 1, 1);
  return dashMonthPeriod(month.year, month.month, now: today);
}

DashPeriod dashThisYear([DateTime? now]) {
  final today = now ?? DateTime.now();
  return (
    from: DateTime(today.year, 1, 1),
    to: DateTime(today.year, today.month, today.day),
    label: '${today.year}',
  );
}

String _day(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}-${two(date.month)}-${date.year}';
}

/// A typed From/To pair (dd-MM-yyyy) — null when either end is not a
/// readable date or the range runs backwards.
DashPeriod? dashCustomPeriod(String from, String to) {
  final start = reportDate(from);
  final end = reportDate(to);
  if (start == null || end == null || end.isBefore(start)) return null;
  return (
    from: start,
    to: end,
    label: '${_day(start)} – ${_day(end)}',
  );
}

/// Whether a stored date sits inside [period]. All time counts every
/// row, dated or not; a real window drops rows without a readable date.
bool dashInPeriod(String? raw, DashPeriod period) {
  if (period.from == null && period.to == null) return true;
  final date = reportDate(raw);
  if (date == null) return false;
  if (period.from != null && date.isBefore(period.from!)) return false;
  if (period.to != null && date.isAfter(period.to!)) return false;
  return true;
}

/// `machine:12`-style key of the item a sale line names, if any.
String? saleLineItemKey(Map line) {
  for (final kind in kItemKinds) {
    final id = line['${kind}_id'];
    if (id is int) return '$kind:$id';
  }
  return null;
}

/// The batch code an item sits in, read off [batchByItem] (built from
/// the full item list). '' when the item is unknown.
String itemBatchOf(
    Map<String, dynamic> row, Map<String, String> batchByItem) {
  final key = movementItemKey(row);
  if (key == null) return '';
  return batchByItem['${key.key}:${key.value}'] ?? '';
}

/// A sale belongs to [batch] only when every item it names is in that
/// batch — a mixed-batch sale can't be split by amount, so it stays in
/// the all-batches numbers alone. Sends without items never match.
bool dashEntryMatchesBatch(
    SaleEntry entry, String batch, Map<String, String> batchByItem) {
  if (batch.isEmpty) return true;
  if (entry.source == 'send') {
    if (entry.rows.isEmpty) return false;
    return entry.rows.every((row) => itemBatchOf(row, batchByItem) == batch);
  }
  final lines = (entry.row['sale_items'] as List?)?.cast<Map>() ?? const [];
  var linked = 0;
  for (final line in lines) {
    final key = saleLineItemKey(line);
    if (key == null) continue;
    linked++;
    if (batchByItem[key] != batch) return false;
  }
  return linked > 0;
}

/// The numbers the dashboard shows for one period and (optionally) one
/// batch. Pure — every list it needs is passed in.
typedef DashStats = ({
  int salesCount,
  double salesAmount,
  int sendCount,
  int itemCount,
  Map<String, int> sendsByKind,
  int returnedItems,
  int returnedBack,
  int repairsReceived,
  int repairsBack,
  double repairsMoney,
});

const _sendKinds = {'Workshop', 'Branch', 'Dealer', 'Customer'};

DashStats computeDashStats({
  required List<Map<String, dynamic>> movementRows,
  required List<SaleEntry> saleEntries,
  required List<Map<String, dynamic>> repairRows,
  required Map<String, String> batchByItem,
  required DashPeriod period,
  String batch = '',
  bool includeRepairs = true,
}) {
  bool inBatch(Map<String, dynamic> row) =>
      batch.isEmpty || itemBatchOf(row, batchByItem) == batch;

  final latest = latestMovementByItem(movementRows);
  final sendGroups = <String, Set<String>>{};
  var itemCount = 0;
  var returned = 0;
  var returnedBack = 0;

  for (final row in movementRows) {
    final type = '${row['movement_type'] ?? ''}';
    if (type == 'Legacy' || type == 'Box' || type == 'Unbox') continue;
    if (!inBatch(row)) continue;
    if (!dashInPeriod('${row['movement_date'] ?? ''}', period)) continue;

    if (type == 'Return') {
      returned++;
      // an item that came back and was sent out again is no longer in
      // stock — only the item whose latest movement is this return counts
      final key = movementItemKey(row);
      final last = key == null ? null : latest['${key.key}:${key.value}'];
      if (last != null && last['id'] == row['id']) returnedBack++;
      continue;
    }
    if (!_sendKinds.contains(type)) continue;
    itemCount++;
    final group = '${row['group_ref'] ?? ''}';
    final key = group.isNotEmpty ? 'g:$group' : 'r:${row['id']}';
    (sendGroups[type] ??= <String>{}).add(key);
  }

  final sendsByKind = {
    for (final entry in sendGroups.entries) entry.key: entry.value.length,
  };
  final sendCount =
      sendGroups.values.fold<int>(0, (sum, groups) => sum + groups.length);

  var salesCount = 0;
  var salesAmount = 0.0;
  for (final entry in saleEntries) {
    if (!dashInPeriod(entry.date, period)) continue;
    if (!dashEntryMatchesBatch(entry, batch, batchByItem)) continue;
    salesCount++;
    salesAmount += entry.total ?? 0;
  }

  var repairsReceived = 0;
  var repairsBack = 0;
  var repairsMoney = 0.0;
  if (includeRepairs) {
    for (final job in repairRows) {
      if (dashInPeriod('${job['received_at'] ?? ''}', period)) {
        repairsReceived++;
      }
      if (dashInPeriod('${job['returned_at'] ?? ''}', period)) {
        repairsBack++;
        repairsMoney += (job['money_received'] as num?)?.toDouble() ?? 0;
      }
    }
  }

  return (
    salesCount: salesCount,
    salesAmount: salesAmount,
    sendCount: sendCount,
    itemCount: itemCount,
    sendsByKind: sendsByKind,
    returnedItems: returned,
    returnedBack: returnedBack,
    repairsReceived: repairsReceived,
    repairsBack: repairsBack,
    repairsMoney: repairsMoney,
  );
}
