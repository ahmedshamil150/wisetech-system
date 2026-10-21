import 'dart:js_interop';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:web/web.dart' as web;

import 'report_data.dart';

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
}) async {
  final doc = pw.Document();
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${two(now.day)}-${two(now.month)}-${now.year} ${two(now.hour)}:${two(now.minute)}';
  final safeColumns = [for (final c in columns) pdfText(c)];
  final safeData = [
    for (final row in data) [for (final cell in row) pdfText(cell)],
  ];
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
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

/// Hands the finished PDF to the browser as a download — this app only
/// ships on the web.
void downloadPdf(Uint8List bytes, String filename) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
