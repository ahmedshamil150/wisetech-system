import 'dart:typed_data';

/// Only compiled off the web — reports currently ship on the web app.
void savePdfDownload(Uint8List bytes, String filename) =>
    throw UnsupportedError('PDF downloads only work in the web app.');
