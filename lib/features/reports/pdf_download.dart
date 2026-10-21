import 'dart:typed_data';

import 'pdf_download_stub.dart'
    if (dart.library.js_interop) 'pdf_download_web.dart';

/// Hands the finished PDF to the platform as a download — the browser
/// on web, unsupported anywhere else for now.
void downloadPdf(Uint8List bytes, String filename) =>
    savePdfDownload(bytes, filename);
