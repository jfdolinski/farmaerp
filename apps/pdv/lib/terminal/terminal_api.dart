import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/local_logger.dart';
import '../core/trace_id.dart';

/// Erro da API, já com código do catálogo. Sem conexão, o código é FA001.
class ApiException implements Exception {
  const ApiException(this.code, {this.traceId});

  final String code;
  final String? traceId;

  @override
  String toString() => 'ApiException($code, $traceId)';
}

class PairingRequest {
  const PairingRequest({required this.requestId, required this.code});

  final String requestId;
  final String code;
}

class PairingStatus {
  const PairingStatus({
    required this.status,
    this.terminalId,
    this.terminalStatus,
  });

  final String status;
  final String? terminalId;
  final String? terminalStatus;
}

class AccessToken {
  const AccessToken({required this.value, required this.expiresAt});

  final String value;
  final DateTime expiresAt;
}

abstract class TerminalApi {
  Future<PairingRequest> createPairing({
    required String publicKey,
    required String signature,
    required String platform,
    required String deviceName,
    required String appVersion,
    required String keyStorage,
  });

  Future<PairingStatus> pairingStatus({
    required String requestId,
    required String publicKey,
  });

  Future<String> challenge(String terminalId);

  Future<AccessToken> token({
    required String challenge,
    required String signature,
  });

  /// Retorna o número do terminal, usado no código das vendas.
  Future<int?> heartbeat({
    required String accessToken,
    required String appVersion,
  });
}

class HttpTerminalApi implements TerminalApi {
  HttpTerminalApi({
    required this.baseUrl,
    http.Client? client,
    this.logger,
    this.timeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final LocalLogger? logger;
  final Duration timeout;
  final http.Client _client;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body, {
    String? accessToken,
  }) async {
    final traceId = newTraceId();
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: {
              'Content-Type': 'application/json',
              'X-Trace-Id': traceId,
              'Authorization': ?(accessToken == null
                  ? null
                  : 'Bearer $accessToken'),
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (error) {
      logger?.warn(
        'Falha de conexão com a API',
        traceId: traceId,
        fields: {'route': path, 'err': error.toString()},
      );
      throw ApiException('FA001', traceId: traceId);
    }

    Map<String, dynamic>? json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      json = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300 && json != null) {
      return json;
    }
    final code = json?['code'] as String? ?? 'FA000';
    logger?.warn(
      'A API recusou a operação',
      traceId: traceId,
      fields: {'route': path, 'status': response.statusCode, 'error_code': code},
    );
    throw ApiException(code, traceId: traceId);
  }

  @override
  Future<PairingRequest> createPairing({
    required String publicKey,
    required String signature,
    required String platform,
    required String deviceName,
    required String appVersion,
    required String keyStorage,
  }) async {
    final json = await _post('/terminals/pairing/requests', {
      'publicKey': publicKey,
      'signature': signature,
      'platform': platform,
      'deviceName': deviceName,
      'appVersion': appVersion,
      'keyStorage': keyStorage,
    });
    return PairingRequest(
      requestId: json['requestId'] as String,
      code: json['code'] as String,
    );
  }

  @override
  Future<PairingStatus> pairingStatus({
    required String requestId,
    required String publicKey,
  }) async {
    final json = await _post('/terminals/pairing/status', {
      'requestId': requestId,
      'publicKey': publicKey,
    });
    return PairingStatus(
      status: json['status'] as String,
      terminalId: json['terminalId'] as String?,
      terminalStatus: json['terminalStatus'] as String?,
    );
  }

  @override
  Future<String> challenge(String terminalId) async {
    final json = await _post('/terminals/auth/challenge', {
      'terminalId': terminalId,
    });
    return json['challenge'] as String;
  }

  @override
  Future<AccessToken> token({
    required String challenge,
    required String signature,
  }) async {
    final json = await _post('/terminals/auth/token', {
      'challenge': challenge,
      'signature': signature,
    });
    return AccessToken(
      value: json['accessToken'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  @override
  Future<int?> heartbeat({
    required String accessToken,
    required String appVersion,
  }) async {
    final json = await _post('/terminals/heartbeat', {
      'appVersion': appVersion,
    }, accessToken: accessToken);
    return json['terminalNumber'] as int?;
  }
}
