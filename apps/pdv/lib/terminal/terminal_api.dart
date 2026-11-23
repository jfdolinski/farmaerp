import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/local_logger.dart';
import '../core/trace_id.dart';
import '../local/local_database.dart';

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
    DateTime? lastSyncAt,
    int? outboxPending,
  });

  /// Sobe um pacote da outbox, em ordem.
  Future<List<PushResult>> push({
    required String accessToken,
    required List<OutboxItem> items,
  });

  /// Um pacote da descida. Sem cursor, a carga inteira.
  Future<PullPage> pull({
    required String accessToken,
    String? cursor,
    String? until,
    String? after,
  });
}

class HttpTerminalApi implements TerminalApi {
  HttpTerminalApi({
    required this.baseUrl,
    http.Client? client,
    this.logger,
    this.timeout = const Duration(seconds: 10),
    this.pullTimeout = const Duration(seconds: 60),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final LocalLogger? logger;
  final Duration timeout;

  /// O pacote da descida é maior e pode levar mais tempo em rede lenta.
  final Duration pullTimeout;
  final http.Client _client;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body, {
    String? accessToken,
    Duration? requestTimeout,
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
          .timeout(requestTimeout ?? timeout);
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
    DateTime? lastSyncAt,
    int? outboxPending,
  }) async {
    final json = await _post('/terminals/heartbeat', {
      'appVersion': appVersion,
      'lastSyncAt': ?lastSyncAt?.toUtc().toIso8601String(),
      'outboxPending': ?outboxPending,
    }, accessToken: accessToken);
    return json['terminalNumber'] as int?;
  }

  @override
  Future<List<PushResult>> push({
    required String accessToken,
    required List<OutboxItem> items,
  }) async {
    final json = await _post(
      '/terminals/sync/push',
      {'items': [for (final item in items) item.toJson()]},
      accessToken: accessToken,
      requestTimeout: pullTimeout,
    );
    return (json['results'] as List)
        .cast<Map<String, dynamic>>()
        .map(PushResult.fromJson)
        .toList();
  }

  @override
  Future<PullPage> pull({
    required String accessToken,
    String? cursor,
    String? until,
    String? after,
  }) async {
    final json = await _post(
      '/terminals/sync/pull',
      {'cursor': cursor, 'until': until, 'after': after},
      accessToken: accessToken,
      requestTimeout: pullTimeout,
    );
    return PullPage.fromJson(json);
  }
}
