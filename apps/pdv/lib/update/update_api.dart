import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/trace_id.dart';
import '../terminal/terminal_api.dart' show ApiException;

/// Versão oferecida pela central ao terminal.
class AvailableRelease {
  const AvailableRelease({
    required this.id,
    required this.app,
    required this.platform,
    required this.version,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.signature,
    this.notes,
  });

  factory AvailableRelease.fromJson(Map<String, dynamic> json) => AvailableRelease(
    id: json['id'] as String,
    app: json['app'] as String,
    platform: json['platform'] as String,
    version: json['version'] as String,
    fileName: json['fileName'] as String,
    size: (json['size'] as num).toInt(),
    sha256: json['sha256'] as String,
    signature: json['signature'] as String,
    notes: json['notes'] as String?,
  );

  final String id;
  final String app;
  final String platform;
  final String version;
  final String fileName;
  final int size;
  final String sha256;
  final String signature;
  final String? notes;

  Map<String, Object?> toJson() => {
    'id': id,
    'app': app,
    'platform': platform,
    'version': version,
    'fileName': fileName,
    'size': size,
    'sha256': sha256,
    'signature': signature,
    'notes': notes,
  };
}

/// Conversa do PDV com a central sobre as versões.
abstract class UpdateApi {
  Future<AvailableRelease?> check({required String accessToken, required String platform, required String current});

  /// Baixa o arquivo para [target], continuando de onde parou se ele já tiver uma parte.
  Future<void> download({required String accessToken, required String releaseId, required File target});

  Future<void> report({required String accessToken, required String releaseId, required String status, String? detail});
}

class HttpUpdateApi implements UpdateApi {
  HttpUpdateApi({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Map<String, String> _headers(String accessToken) => {
    'Authorization': 'Bearer $accessToken',
    'X-Trace-Id': newTraceId(),
  };

  Never _fail(http.BaseResponse response, [String? body]) {
    String? code;
    try {
      final json = body == null ? null : jsonDecode(body);
      code = json is Map ? json['code'] as String? : null;
    } catch (_) {
      code = null;
    }
    throw ApiException(code ?? 'FA000');
  }

  @override
  Future<AvailableRelease?> check({required String accessToken, required String platform, required String current}) async {
    final uri = Uri.parse('$baseUrl/terminals/updates').replace(queryParameters: {'platform': platform, 'current': current});
    final http.Response response;
    try {
      response = await _client.get(uri, headers: _headers(accessToken)).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const ApiException('FA001');
    }
    if (response.statusCode != 200) _fail(response, response.body);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['available'] != true) return null;
    return AvailableRelease.fromJson(json['release'] as Map<String, dynamic>);
  }

  @override
  Future<void> download({required String accessToken, required String releaseId, required File target}) async {
    final already = target.existsSync() ? target.lengthSync() : 0;
    final request = http.Request('GET', Uri.parse('$baseUrl/terminals/updates/$releaseId/file'))
      ..headers.addAll(_headers(accessToken));
    if (already > 0) request.headers['Range'] = 'bytes=$already-';
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw const ApiException('FA001');
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      _fail(response, await response.stream.bytesToString());
    }
    // 206: continua a parte que já estava aqui; 200: o servidor mandou tudo de novo.
    final sink = target.openWrite(mode: response.statusCode == 206 ? FileMode.append : FileMode.write);
    try {
      await response.stream.timeout(const Duration(minutes: 2)).pipe(sink);
    } catch (_) {
      throw const ApiException('FA001');
    } finally {
      await sink.close().catchError((_) {});
    }
  }

  @override
  Future<void> report({required String accessToken, required String releaseId, required String status, String? detail}) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/terminals/updates/$releaseId/report'),
            headers: {..._headers(accessToken), 'Content-Type': 'application/json'},
            body: jsonEncode({'status': status, 'detail': detail}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const ApiException('FA001');
    }
    if (response.statusCode != 200) _fail(response, response.body);
  }
}
