import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Uploads images directly to Cloudflare R2 using AWS Signature v4 signing.
/// No backend required — the Flutter app signs and sends each PUT request.
class R2Service {
  static String get _accountId => const String.fromEnvironment('R2_ACCOUNT_ID', defaultValue: '');
  static String get _bucketName => const String.fromEnvironment('R2_BUCKET_NAME', defaultValue: '');
  static String get _accessKeyId => const String.fromEnvironment('R2_ACCESS_KEY_ID', defaultValue: '');
  static String get _secretAccessKey => const String.fromEnvironment('R2_SECRET_ACCESS_KEY', defaultValue: '');
  static String get _endpoint => const String.fromEnvironment('R2_ENDPOINT', defaultValue: '');

  static bool get isConfigured =>
      _accountId.isNotEmpty &&
      _bucketName.isNotEmpty &&
      _accessKeyId.isNotEmpty &&
      _secretAccessKey.isNotEmpty &&
      _endpoint.isNotEmpty;

  /// Upload [bytes] to R2 at [key] with [contentType]. Returns the public URL.
  static Future<String> uploadBytes({
    required String key,
    required Uint8List bytes,
    required String contentType,
  }) async {
    if (!isConfigured) {
      throw Exception('Cloudflare R2 is not configured. Add R2 credentials to .env');
    }

    final uri = Uri.parse('$_endpoint/$_bucketName/$key');
    final date = _nowIso8601();
    final dateShort = date.substring(0, 8);
    final region = 'auto';
    final service = 's3';

    final headers = <String, String>{
      'host': uri.host,
      'x-amz-content-sha256': _sha256Hex(bytes),
      'x-amz-date': date,
      'content-type': contentType,
      'content-length': bytes.length.toString(),
    };

    final canonicalRequest = _canonicalRequest(
      method: 'PUT',
      path: '/$_bucketName/$key',
      headers: headers,
      payloadHash: headers['x-amz-content-sha256']!,
    );

    final stringToSign = _stringToSign(
      date: date,
      dateShort: dateShort,
      region: region,
      service: service,
      canonicalRequest: canonicalRequest,
    );

    final signingKey = _signingKey(
      secretKey: _secretAccessKey,
      dateShort: dateShort,
      region: region,
      service: service,
    );

    final signature = _hex(_sign(signingKey, utf8.encode(stringToSign)));

    final signedHeaders = headers.keys.map((k) => k.toLowerCase()).join(';');
    final authorization =
        'AWS4-HMAC-SHA256 Credential=$_accessKeyId/$dateShort/$region/$service/aws4_request, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';

    headers['authorization'] = authorization;

    final response = await http.put(
      uri,
      headers: headers,
      body: bytes,
    ).timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(
        'R2 upload failed: ${response.statusCode} ${response.body}',
      );
    }

    return '$_endpoint/$_bucketName/$key';
  }

  // ---------- AWS Signature v4 helpers (all static) ----------

  static String _nowIso8601() {
    final now = DateTime.now().toUtc();
    return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}T'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}Z';
  }

  static String _sha256Hex(Uint8List data) => _hex(sha256.convert(data).bytes);

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _sign(Uint8List key, List<int> data) =>
      Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

  static String _canonicalRequest({
    required String method,
    required String path,
    required Map<String, String> headers,
    required String payloadHash,
  }) {
    final sorted = Map<String, String>.fromEntries(
      headers.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final canonicalHeaders = sorted.entries
        .map((e) => '${e.key}:${e.value}')
        .join('\n');
    final signedHeaders = sorted.keys.map((k) => k.toLowerCase()).join(';');
    return '''
$method
$path

$canonicalHeaders

$signedHeaders
$payloadHash
'''.trimRight();
  }

  static String _stringToSign({
    required String date,
    required String dateShort,
    required String region,
    required String service,
    required String canonicalRequest,
  }) =>
      'AWS4-HMAC-SHA256\n$date\n$dateShort/$region/$service/aws4_request\n'
      '${_sha256Hex(utf8.encode(canonicalRequest))}';

  static Uint8List _signingKey({
    required String secretKey,
    required String dateShort,
    required String region,
    required String service,
  }) {
    final kDate = _sign(
      utf8.encode('AWS4$secretKey'), utf8.encode(dateShort),
    );
    final kRegion = _sign(kDate, utf8.encode(region));
    final kService = _sign(kRegion, utf8.encode(service));
    return _sign(kService, utf8.encode('aws4_request'));
  }
}
