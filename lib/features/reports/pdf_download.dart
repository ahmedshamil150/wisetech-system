import 'dart:typed_data';

import 'pdf_download_stub.dart'
    if (dart.library.js_interop) 'pdf_download_web.dart';

/// Hands the finished PDF to the platform — a browser download on the
/// web, the system share sheet (save to Files, Drive, mail) on a phone.
Future<void> downloadPdf(Uint8List bytes, String filename) =>
    savePdfDownload(bytes, filename);
