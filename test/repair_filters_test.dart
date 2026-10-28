import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/repairs/repair_filters.dart';

Map<String, dynamic> _job(
  int id, {
  String status = 'Received',
  String receivedAt = '10-01-2026',
  String? returnedAt,
  Object? money,
  List<String> itemTypes = const ['machine'],
  String customer = 'Ali',
  String? jobNumber,
}) =>
    {
      'id': id,
      'job_number': jobNumber ?? 'JOB-$id',
      'status': status,
      'received_at': receivedAt,
      'returned_at': returnedAt,
      'money_received': money,
      'customers': {'name': customer},
      'repair_items': [
        for (var i = 0; i < itemTypes.length; i++)
          {
            'equipment_type': itemTypes[i],
            'name_model': 'Model $i',
            'serial_number': 'SN$i',
          },
      ],
    };

RepairFilter _filter({
  String query = '',
  String state = 'All',
  String itemType = 'All',
  String money = 'All',
  String dateFrom = '',
  String dateTo = '',
  bool flaggedOnly = false,
}) =>
    (
      query: query,
      state: state,
      itemType: itemType,
      money: money,
      dateFrom: dateFrom,
      dateTo: dateTo,
      flaggedOnly: flaggedOnly,
    );

void main() {
  final jobs = [
    _job(1, status: 'Received', customer: 'Ali', jobNumber: 'JOB-1'),
    _job(2, status: 'In repair', customer: 'Bilal', jobNumber: 'JOB-2'),
    _job(3,
        status: 'Returned',
        customer: 'Chand',
        jobNumber: 'JOB-3',
        returnedAt: '20-01-2026',
        money: 5000),
    _job(4, status: 'Cancelled', customer: 'Danish', jobNumber: 'JOB-4'),
  ];

  test('state keeps only the chosen side of the job', () {
    expect(
      filterRepairJobs(jobs, filter: _filter(state: 'In repair'))
          .map((job) => job['id']),
      [1, 2],
    );
    expect(
      filterRepairJobs(jobs, filter: _filter(state: 'Sent back'))
          .map((job) => job['id']),
      [3],
    );
    expect(
      filterRepairJobs(jobs, filter: _filter(state: 'Cancelled'))
          .map((job) => job['id']),
      [4],
    );
    expect(filterRepairJobs(jobs, filter: _filter()).length, 4);
  });

  test('item type filters on any item of the job', () {
    final rows = [
      _job(10, itemTypes: ['machine', 'probe']),
      _job(11, itemTypes: ['printer']),
      _job(12, itemTypes: ['other']),
    ];
    expect(
      filterRepairJobs(rows, filter: _filter(itemType: 'probe'))
          .map((job) => job['id']),
      [10],
    );
    expect(
      filterRepairJobs(rows, filter: _filter(itemType: 'printer'))
          .map((job) => job['id']),
      [11],
    );
    expect(
      filterRepairJobs(rows, filter: _filter(itemType: 'machine'))
          .map((job) => job['id']),
      [10],
    );
  });

  test('money splits received from nothing recorded', () {
    expect(
      filterRepairJobs(jobs, filter: _filter(money: 'Received'))
          .map((job) => job['id']),
      [3],
    );
    expect(
      filterRepairJobs(jobs, filter: _filter(money: 'Not received'))
          .map((job) => job['id']),
      [1, 2, 4],
    );
  });

  test('received-date range is inclusive and drops undated jobs', () {
    final rows = [
      _job(20, receivedAt: '09-01-2026'),
      _job(21, receivedAt: '10-01-2026'),
      _job(22, receivedAt: '31-01-2026'),
      _job(23, receivedAt: '01-02-2026'),
      _job(24, receivedAt: ''),
    ];
    expect(
      filterRepairJobs(rows,
              filter: _filter(dateFrom: '10-01-2026', dateTo: '31-01-2026'))
          .map((job) => job['id']),
      [21, 22],
    );
    expect(
      filterRepairJobs(rows, filter: _filter(dateTo: '09-01-2026'))
          .map((job) => job['id']),
      [20],
    );
  });

  test('search reads the customer, job number, model and serial', () {
    expect(
      filterRepairJobs(jobs, filter: _filter(query: 'bilal'))
          .map((job) => job['id']),
      [2],
    );
    expect(
      filterRepairJobs(jobs, filter: _filter(query: 'job-3'))
          .map((job) => job['id']),
      [3],
    );
    expect(
      filterRepairJobs(jobs, filter: _filter(query: 'sn0')).length,
      4,
    );
  });

  test('flagged only keeps jobs whose ids carry a flag', () {
    expect(
      filterRepairJobs(jobs,
              filter: _filter(flaggedOnly: true), flaggedIds: {2, 4})
          .map((job) => job['id']),
      [2, 4],
    );
  });

  test('filters combine', () {
    final rows = [
      _job(30, customer: 'Ali', receivedAt: '10-01-2026', money: 100),
      _job(31, customer: 'Ali', receivedAt: '10-01-2026'),
      _job(32, customer: 'Bilal', receivedAt: '10-01-2026', money: 100),
    ];
    expect(
      filterRepairJobs(rows,
              filter: _filter(
                query: 'ali',
                money: 'Received',
                dateFrom: '01-01-2026',
                dateTo: '31-01-2026',
              ))
          .map((job) => job['id']),
      [30],
    );
  });

  test('repairFilterCount counts the sheet filters only', () {
    expect(repairFilterCount(defaultRepairFilter), 0);
    expect(
      repairFilterCount(_filter(
        query: 'ignored by the count',
        state: 'In repair',
        itemType: 'probe',
        money: 'Received',
        dateFrom: '01-01-2026',
        dateTo: '31-01-2026',
        flaggedOnly: true,
      )),
      6,
    );
  });

  test('repairDate reads dd-MM-yyyy and ISO', () {
    expect(repairDate('05-03-2026'), DateTime(2026, 3, 5));
    expect(repairDate('2026-03-05'), DateTime(2026, 3, 5));
    expect(repairDate(''), isNull);
    expect(repairDate(null), isNull);
    expect(repairDate('not a date'), isNull);
  });
}
