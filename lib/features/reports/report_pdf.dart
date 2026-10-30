import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'report_data.dart';

/// A table cell that can never outgrow a page. Imported notes can run
/// to hundreds of lines; a row taller than one page cannot be split,
/// which is what made the layout give up.
String _cellText(String cell) {
  final text = pdfText(cell).replaceAll('\r', '');
  final lines = text.split('\n');
  var clipped = text;
  if (lines.length > 12) {
    clipped = '${lines.take(12).join('\n')}\n...';
  }
  if (clipped.length > 400) clipped = '${clipped.substring(0, 400)}...';
  return clipped;
}

/// Builds the landscape A4 report: the shop's header, the report's
/// title and range, the table (striped, with its header repeated on
/// every page) and a page-number footer. Every piece of text goes
/// through [pdfText] so the built-in fonts can draw it.
Future<Uint8List> buildReportPdf({
  required String title,
  required String subtitle,
  required List<String> columns,
  required List<List<String>> data,
  required String generatedBy,
  List<String> summary = const [],
}) async {
  final doc = pw.Document();
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${two(now.day)}-${two(now.month)}-${now.year} ${two(now.hour)}:${two(now.minute)}';
  final safeColumns = [for (final c in columns) pdfText(c)];
  final safeSummary = [for (final line in summary) pdfText(line)];
  final safeData = [
    for (final row in data) [for (final cell in row) _cellText(cell)],
  ];
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      // The library's 20-page default aborts on a whole-stock report.
      // A cell is capped below, so no single row can outgrow a page and
      // loop; this is just a generous ceiling for real data.
      maxPages: 10000,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 10),
          decoration: const pw.BoxDecoration(
              border:
                  pw.Border(bottom: pw.BorderSide(width: 0.8, color: PdfColors.grey600))),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('WiseTech - Ultrasound Inventory',
                        style: pw.TextStyle(
                            fontSize: 9, color: PdfColors.grey600)),
                    pw.SizedBox(height: 2),
                    pw.Text(pdfText(title),
                        style: pw.TextStyle(
                            fontSize: 16, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 2),
                    pw.Text(pdfText(subtitle),
                        style: pw.TextStyle(
                            fontSize: 9.5, color: PdfColors.grey700)),
                  ],
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('Generated $stamp',
                      style:
                          pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                  pw.Text('by ${pdfText(generatedBy)}',
                      style:
                          pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                  pw.SizedBox(height: 2),
                  pw.Text('${safeData.length} row${safeData.length == 1 ? '' : 's'}',
                      style: pw.TextStyle(
                          fontSize: 9, fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 10),
        if (safeSummary.isNotEmpty) ...[
          pw.Container(
            width: double.infinity,
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: const pw.BoxDecoration(color: PdfColors.grey100),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                for (final line in safeSummary)
                  pw.Text(line,
                      style: pw.TextStyle(
                          fontSize: 9, color: PdfColors.grey800)),
              ],
            ),
          ),
          pw.SizedBox(height: 8),
        ],
        if (safeData.isEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 24),
            child: pw.Text('No rows to report for this selection.',
                style: pw.TextStyle(fontSize: 11, color: PdfColors.grey600)),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: safeColumns,
            data: safeData,
            headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 8,
                color: PdfColors.white),
            headerDecoration:
                const pw.BoxDecoration(color: PdfColors.grey800),
            headerAlignment: pw.Alignment.centerLeft,
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            headerPadding:
                const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
            oddRowDecoration:
                const pw.BoxDecoration(color: PdfColors.grey100),
            columnWidths: {
              for (var i = 0; i < safeColumns.length; i++)
                i: const pw.FlexColumnWidth(),
            },
          ),
      ],
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('WiseTech - Ultrasound Inventory',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
          pw.Text('Page ${context.pageNumber} of ${context.pagesCount}',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
        ],
      ),
    ),
  );
  return doc.save();
}
