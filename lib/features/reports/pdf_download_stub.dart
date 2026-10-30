import 'dart:typed_data';

import 'package:printing/printing.dart';

/// Phone and desktop: open the system share sheet with the PDF, so it
/// can be saved to Files, Drive or sent on. (The web build uses the
/// browser download instead.)
Future<void> savePdfDownload(Uint8List bytes, String filename) =>
    Printing.sharePdf(bytes: bytes, filename: filename);
