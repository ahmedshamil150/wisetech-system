/// The filters the repairs list applies. Every field is off at its
/// default: state 'All', item type 'All', money 'All', no dates, no
/// flags, no query.
typedef RepairFilter = ({
  String query,
  String state, // All | In repair | Sent back | Cancelled
  String itemType, // All | machine | probe | printer | other
  String money, // All | Received | Not received
  String dateFrom, // dd-MM-yyyy, '' = off
  String dateTo, // dd-MM-yyyy, '' = off
  bool flaggedOnly,
});

const defaultRepairFilter = (
  query: '',
  state: 'All',
  itemType: 'All',
  money: 'All',
  dateFrom: '',
  dateTo: '',
  flaggedOnly: false,
);

/// How many sheet filters are on — the search box is counted separately
/// by the screen.
int repairFilterCount(RepairFilter filter) {
  var count = 0;
  if (filter.state != 'All') count++;
  if (filter.itemType != 'All') count++;
  if (filter.money != 'All') count++;
  if (filter.dateFrom.trim().isNotEmpty) count++;
  if (filter.dateTo.trim().isNotEmpty) count++;
  if (filter.flaggedOnly) count++;
  return count;
}

/// A repair date as a day — received_at is stored dd-MM-yyyy but rows
/// imported or edited elsewhere may carry an ISO date.
DateTime? repairDate(String? text) {
  final value = (text ?? '').trim();
  if (value.isEmpty) return null;
  final iso = DateTime.tryParse(value);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final parts = value.split('-');
  if (parts.length != 3) return null;
  final first = int.tryParse(parts[0]);
  final second = int.tryParse(parts[1]);
  final third = int.tryParse(parts[2]);
  if (first == null || second == null || third == null) return null;
  return parts[0].length == 4
      ? DateTime(first, second, third)
      : DateTime(third, second, first);
}

List<Map<String, dynamic>> repairJobItems(Map<String, dynamic> job) =>
    (job['repair_items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();

/// The state a job reads as in the list: with us, handed back, or
/// cancelled before it was finished.
String repairStateOf(Object? status) {
  final value = '${status ?? ''}';
  if (value == 'Returned') return 'Sent back';
  if (value == 'Cancelled') return 'Cancelled';
  return 'In repair';
}

/// The item kinds on a job, e.g. {'machine', 'probe'}.
Set<String> repairJobItemTypes(Map<String, dynamic> job) => {
      for (final item in repairJobItems(job))
        '${item['equipment_type'] ?? 'machine'}'.toLowerCase(),
    };

/// Everything a search should look through for one job.
String repairJobSearchText(Map<String, dynamic> job) {
  final customer = (job['customers'] as Map?)?['name'] ?? '';
  final parts = <String>[
    '${job['job_number'] ?? ''}',
    '$customer',
    '${job['customer_contact'] ?? ''}',
    '${job['received_at'] ?? ''}',
    '${job['returned_at'] ?? ''}',
    '${job['delivered_by'] ?? ''}',
    '${job['collected_by'] ?? ''}',
    '${job['status'] ?? ''}',
    '${job['problem_description'] ?? ''}',
    '${job['repair_notes'] ?? ''}',
    '${job['return_notes'] ?? ''}',
    '${job['accessories_received'] ?? ''}',
    '${job['condition_on_arrival'] ?? ''}',
    '${job['money_received'] ?? ''}',
    for (final item in repairJobItems(job))
      '${item['name_model'] ?? ''} ${item['serial_number'] ?? ''} '
          '${item['equipment_type'] ?? ''}',
  ];
  return parts.join(' ').toLowerCase();
}

/// The repairs a filter leaves: free-text search, state (with us or sent
/// back), the kind of item on the job, whether money came back, the
/// received-date range (inclusive) and flagged jobs. [flaggedIds] holds
/// the ids of jobs carrying a flag.
List<Map<String, dynamic>> filterRepairJobs(
  List<Map<String, dynamic>> jobs, {
  RepairFilter filter = defaultRepairFilter,
  Set<int> flaggedIds = const <int>{},
}) {
  final query = filter.query.trim().toLowerCase();
  final from =
      filter.dateFrom.trim().isEmpty ? null : repairDate(filter.dateFrom);
  final to = filter.dateTo.trim().isEmpty ? null : repairDate(filter.dateTo);

  return jobs.where((job) {
    if (filter.state != 'All' &&
        repairStateOf(job['status']) != filter.state) {
      return false;
    }

    if (filter.itemType != 'All' &&
        !repairJobItemTypes(job).contains(filter.itemType)) {
      return false;
    }

    if (filter.money != 'All') {
      final amount = double.tryParse('${job['money_received'] ?? ''}');
      final received = amount != null && amount > 0;
      if (filter.money == 'Received' && !received) return false;
      if (filter.money == 'Not received' && received) return false;
    }

    if (from != null || to != null) {
      final date = repairDate('${job['received_at'] ?? ''}');
      if (date == null) return false;
      if (from != null && date.isBefore(from)) return false;
      if (to != null && date.isAfter(to)) return false;
    }

    if (filter.flaggedOnly) {
      final id = job['id'];
      if (id is! int || !flaggedIds.contains(id)) return false;
    }

    if (query.isEmpty) return true;
    return repairJobSearchText(job).contains(query);
  }).toList();
}
