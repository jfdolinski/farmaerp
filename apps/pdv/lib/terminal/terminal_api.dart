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

  /// Busca de cliente com internet: lista com o documento mascarado.
  Future<List<CustomerSummary>> searchCustomers({
    required String accessToken,
    required String query,
  });

  /// Cliente escolhido, inteiro. A partir daqui a descida o mantém atualizado.
  Future<PullItem> customer({
    required String accessToken,
    required String id,
  });

  /// Histórico de compras do cliente na rede (com internet).
  Future<Map<String, dynamic>> customerHistory({required String accessToken, required String id});

  /// Cadastro do cliente na tela de vendas (com internet). Devolve o cliente como na escolha.
  Future<PullItem> createCustomer({required String accessToken, required Map<String, Object?> data});

  /// Estoque do produto em cada filial do grupo (com internet).
  Future<List<Map<String, dynamic>>> networkStock({
    required String accessToken,
    required String productId,
  });

  /// Venda da loja para devolver, pelo código do comprovante (com internet).
  Future<Map<String, dynamic>> saleForReturn({required String accessToken, required String code});

  /// Documento de devolução em dinheiro, para a sangria (com internet).
  Future<Map<String, dynamic>> returnDocument({required String accessToken, required String code});

  /// Crédito de devolução com saldo, para pagar uma compra (com internet).
  Future<Map<String, dynamic>> returnCredit({required String accessToken, required String code});

  /// Cashback do cliente: saldo, consentimento e parâmetros (com internet).
  Future<Map<String, dynamic>> cashback({required String accessToken, required String customerId});

  /// Reserva o uso do cashback (a venda confirma). Devolve o id da reserva e o saldo que sobra.
  Future<Map<String, dynamic>> cashbackReserve({
    required String accessToken,
    required String customerId,
    required double amount,
    required double saleTotal,
  });

  /// Libera a reserva quando a venda não acontece.
  Future<void> cashbackRelease({required String accessToken, required String reservationId});

  /// Orçamentos abertos e válidos da loja (com internet).
  Future<List<Map<String, dynamic>>> openQuotes({required String accessToken});

  /// Orçamento pela plaquinha ou pelo código do cupom (com internet).
  Future<Map<String, dynamic>> quote({required String accessToken, required String key});

  /// Registra a chave de criptografia do caixa (NFC-e), assinada pela chave do terminal.
  Future<void> registerFiscalKey({required String accessToken, required String publicKey, required String signature});

  /// Certificado e CSC da NFC-e, cifrados para a chave do caixa.
  Future<Map<String, dynamic>> nfceCredentials({required String accessToken});

  /// Pede à central o cancelamento da NFC-e (e da venda), liberado por um supervisor (com internet).
  Future<Map<String, dynamic>> cancelNfce({
    required String accessToken,
    required String documentId,
    required String reason,
    required String supervisorId,
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
    final json = await _request(
      path,
      body: body,
      accessToken: accessToken,
      requestTimeout: requestTimeout,
    );
    if (json is Map<String, dynamic>) return json;
    throw const ApiException('FA000');
  }

  /// POST com corpo, ou GET sem corpo. Devolve o JSON da resposta, objeto ou lista.
  Future<Object?> _request(
    String path, {
    Map<String, Object?>? body,
    String? accessToken,
    Duration? requestTimeout,
  }) async {
    final traceId = newTraceId();
    final headers = {
      'Content-Type': 'application/json',
      'X-Trace-Id': traceId,
      'Authorization': ?(accessToken == null ? null : 'Bearer $accessToken'),
    };
    final uri = Uri.parse('$baseUrl$path');
    http.Response response;
    try {
      response = await (body == null
              ? _client.get(uri, headers: headers)
              : _client.post(uri, headers: headers, body: jsonEncode(body)))
          .timeout(requestTimeout ?? timeout);
    } catch (error) {
      logger?.warn(
        'Falha de conexão com a API',
        traceId: traceId,
        fields: {'route': path, 'err': error.toString()},
      );
      throw ApiException('FA001', traceId: traceId);
    }

    Object? json;
    try {
      json = jsonDecode(response.body);
    } catch (_) {
      json = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300 && json != null) {
      return json;
    }
    final code = (json is Map ? json['code'] as String? : null) ?? 'FA000';
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
  Future<List<CustomerSummary>> searchCustomers({
    required String accessToken,
    required String query,
  }) async {
    // POST: o CPF da busca não vai na URL.
    final json = await _request(
      '/terminals/customers/search',
      body: {'query': query},
      accessToken: accessToken,
    );
    if (json is! List) throw const ApiException('FA000');
    return json.cast<Map<String, dynamic>>().map(CustomerSummary.fromJson).toList();
  }

  @override
  Future<PullItem> customer({
    required String accessToken,
    required String id,
  }) async {
    final json = await _request(
      '/terminals/customers/${Uri.encodeComponent(id)}',
      accessToken: accessToken,
    );
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return PullItem(
      type: 'customer',
      id: json['id'] as String,
      data: json['data'] as Map<String, dynamic>?,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> networkStock({
    required String accessToken,
    required String productId,
  }) async {
    final json = await _request('/terminals/stock/${Uri.encodeComponent(productId)}', accessToken: accessToken);
    if (json is! List) throw const ApiException('FA000');
    return json.cast<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>> saleForReturn({required String accessToken, required String code}) async {
    final json = await _request('/terminals/sales/${Uri.encodeComponent(code)}', accessToken: accessToken);
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
  }

  @override
  Future<Map<String, dynamic>> returnDocument({required String accessToken, required String code}) async {
    final json = await _request('/terminals/returns/${Uri.encodeComponent(code)}', accessToken: accessToken);
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
  }

  @override
  Future<Map<String, dynamic>> returnCredit({required String accessToken, required String code}) async {
    final json = await _request('/terminals/return-credits/${Uri.encodeComponent(code)}', accessToken: accessToken);
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
  }

  @override
  Future<Map<String, dynamic>> cashback({required String accessToken, required String customerId}) async {
    final json = await _request('/terminals/cashback/${Uri.encodeComponent(customerId)}', accessToken: accessToken);
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
  }

  @override
  Future<Map<String, dynamic>> cashbackReserve({
    required String accessToken,
    required String customerId,
    required double amount,
    required double saleTotal,
  }) async {
    final json = await _request(
      '/terminals/cashback/reserve',
      accessToken: accessToken,
      body: {'customerId': customerId, 'amount': amount, 'saleTotal': saleTotal},
    );
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
  }

  @override
  Future<void> cashbackRelease({required String accessToken, required String reservationId}) async {
    await _request('/terminals/cashback/release', accessToken: accessToken, body: {'reservationId': reservationId});
  }

  @override
  Future<List<Map<String, dynamic>>> openQuotes({required String accessToken}) async {
    final json = await _request('/terminals/quotes', accessToken: accessToken);
    if (json is! List) throw const ApiException('FA000');
    return json.cast<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>> quote({required String accessToken, required String key}) async {
    final json = await _request('/terminals/quotes/${Uri.encodeComponent(key)}', accessToken: accessToken);
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
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

  @override
  Future<void> registerFiscalKey({required String accessToken, required String publicKey, required String signature}) async {
    await _post('/terminals/nfce/key', {'publicKey': publicKey, 'signature': signature}, accessToken: accessToken);
  }

  @override
  Future<Map<String, dynamic>> nfceCredentials({required String accessToken}) =>
      _post('/terminals/nfce/credentials', const {}, accessToken: accessToken);

  /// A central fala com a Sefaz (até 30 s por chamada): o tempo de espera é maior que o normal.
  @override
  Future<Map<String, dynamic>> cancelNfce({
    required String accessToken,
    required String documentId,
    required String reason,
    required String supervisorId,
  }) =>
      _post(
        '/terminals/fiscal-documents/${Uri.encodeComponent(documentId)}/cancel',
        {'reason': reason, 'supervisorId': supervisorId},
        accessToken: accessToken,
        requestTimeout: const Duration(seconds: 120),
      );

  @override
  Future<PullItem> createCustomer({required String accessToken, required Map<String, Object?> data}) async {
    final json = await _post('/terminals/customers', data, accessToken: accessToken);
    return PullItem(type: 'customer', id: json['id'] as String, data: json['data'] as Map<String, dynamic>?);
  }

  @override
  Future<Map<String, dynamic>> customerHistory({required String accessToken, required String id}) async {
    final json = await _request('/terminals/customers/${Uri.encodeComponent(id)}/history', accessToken: accessToken);
    if (json is! Map<String, dynamic>) throw const ApiException('FA000');
    return json;
  }
}
