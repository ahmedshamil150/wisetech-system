import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Hands the PDF to the browser as a download via a temporary anchor.
/// The object URL is released a moment later — revoking it in the same
/// tick can cancel the download in some browsers.
Future<void> savePdfDownload(Uint8List bytes, String filename) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  (web.document.body ?? web.document.documentElement!).appendChild(anchor);
  anchor.click();
  anchor.remove();
  Timer(const Duration(seconds: 5), () => web.URL.revokeObjectURL(url));
}
