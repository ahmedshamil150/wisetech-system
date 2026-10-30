import 'package:flutter_test/flutter_test.dart';

import 'package:ultrasound_inventory/features/reports/report_data.dart';
import 'package:ultrasound_inventory/features/reports/report_pdf.dart';

List<List<String>> _rows(int count, List<String> columns) {
  return [
    for (var i = 0; i < count; i++)
      [for (final column in columns) '$column $i'],
  ];
}

void main() {
  test('a whole-stock report builds past the library 20-page default',
      () async {
    // ~1,000 rows is well over 20 landscape pages — this used to throw
    // TooManyPagesException and the download never happened.
    final bytes = await buildReportPdf(
      title: 'Stock report - all stock',
      subtitle: 'From 01-01-2000 to 31-12-2030',
      columns: kStockColumnsAll,
      data: _rows(1000, kStockColumnsAll),
      generatedBy: 'Tester',
    );
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('a row taller than a page is clipped instead of looping', () async {
    final rows = _rows(3, kMovementColumns);
    rows[1][kMovementColumns.indexOf('Notes')] =
        List.filled(400, 'very long imported note line').join('\n');
    final bytes = await buildReportPdf(
      title: 'Movements report - all movements',
      subtitle: 'From 01-01-2000 to 31-12-2030',
      columns: kMovementColumns,
      data: rows,
      generatedBy: 'Tester',
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
