import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/error_display.dart';
import '../core/local_logger.dart';
import '../core/secret_store.dart';
import '../sync/sync_service.dart';
import 'terminal_api.dart';
import 'terminal_identity.dart';

enum TerminalPhase {
  /// Preparando chaves e consultando a situação.
  loading,

  /// Mostrando o código para digitar na retaguarda.
  showingCode,

  /// Código aceito; aguardando o admin aprovar.
  awaitingApproval,

  /// Aprovado. As vendas só são liberadas depois da carga inicial (veja [SyncService]).
  ready,

  blocked,
  revoked,
}

const _requestIdKey = 'terminal_pairing_request_id';
const _terminalIdKey = 'terminal_id';
const _lastStatusKey = 'terminal_last_status';
const _terminalNumberKey = 'terminal_number';

const _pairingMessagePrefix = 'farmaerp-terminal-pairing:';
const _challengeMessagePrefix = 'farmaerp-terminal-auth:';

/// Renova o token antes do vencimento, para o sinal de vida não falhar por pouco.
const _tokenRenewalMargin = Duration(minutes: 1);

class TerminalController extends ChangeNotifier {
  TerminalController({
    required this.api,
    required this.store,
    required this.platform,
    required this.deviceName,
    required this.appVersion,
    this.sync,
    this.logger,
    this.pollInterval = const Duration(seconds: 3),
    this.heartbeatInterval = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TerminalApi api;
  final SecretStore store;
  final String platform;
  final String deviceName;
  final String appVersion;

  /// Descida para o banco local. Roda depois de cada sinal de vida aceito.
  final SyncService? sync;
  final LocalLogger? logger;
  final Duration pollInterval;
  final Duration heartbeatInterval;
  final DateTime Function() _clock;

  TerminalPhase _phase = TerminalPhase.loading;
  TerminalPhase get phase => _phase;

  String? _code;

  /// Código formatado para leitura, como `K7M2-XQ9P`.
  String? get displayCode => _code == null
      ? null
      : '${_code!.substring(0, 4)}-${_code!.substring(4)}';

  int? _terminalNumber;

  /// Número do terminal na filial, usado no código das vendas. Fica guardado para uso offline.
  int? get terminalNumber => _terminalNumber;

  bool _online = true;
  bool get online => _online;

  ErrorDisplay? _notice;

  /// Último problema a mostrar ao operador.
  ErrorDisplay? get notice => _notice;

  TerminalIdentity? _identity;
  String? _requestId;
  String? _terminalId;
  AccessToken? _token;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  Future<void> start() async {
    await _guarded(_restore);
    _schedule();
  }

  /// Avança uma etapa: consulta o pareamento ou envia o sinal de vida.
  Future<void> tick() => _guarded(_step);

  /// Depois de uma revogação: nova chave e novo código.
  Future<void> startNewPairing() async {
    await TerminalIdentity.erase(store);
    await store.delete(_requestIdKey);
    await store.delete(_terminalIdKey);
    await store.delete(_lastStatusKey);
    await store.delete(_terminalNumberKey);
    _terminalNumber = null;
    _identity = null;
    _requestId = null;
    _terminalId = null;
    _token = null;
    _code = null;
    _notice = null;
    _setPhase(TerminalPhase.loading);
    await start();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _phase == TerminalPhase.revoked) return;
    final isPaired =
        _phase == TerminalPhase.ready || _phase == TerminalPhase.blocked;
    _timer = Timer(isPaired ? heartbeatInterval : pollInterval, () async {
      await tick();
      _schedule();
    });
  }

  // Uma etapa de cada vez: a anterior pode demorar com a rede ruim.
  Future<void> _guarded(Future<void> Function() action) async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      await action();
    } catch (error, stack) {
      logger?.error(
        'Erro inesperado no terminal',
        errorCode: 'FA000',
        error: error,
        stackTrace: stack,
      );
      _notice = ErrorDisplay.fromCode('FA000');
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _restore() async {
    _identity = await TerminalIdentity.loadOrCreate(store);
    _requestId = await store.read(_requestIdKey);
    _terminalId = await store.read(_terminalIdKey);
    _terminalNumber = int.tryParse(await store.read(_terminalNumberKey) ?? '');

    if (_terminalId == null) {
      await _step();
      return;
    }

    // A última situação conhecida vale até haver contato com a central.
    switch (await store.read(_lastStatusKey)) {
      case 'revoked':
        _setPhase(TerminalPhase.revoked);
        return;
      case 'blocked':
        _setPhase(TerminalPhase.blocked);
      case 'pending':
        _setPhase(TerminalPhase.awaitingApproval);
      default:
        _setPhase(TerminalPhase.ready);
    }
    await _step();
  }

  Future<void> _step() async {
    try {
      if (_terminalId == null && _requestId == null) {
        await _createRequest();
      } else if (_phase == TerminalPhase.ready ||
          _phase == TerminalPhase.blocked) {
        await _sendHeartbeat();
      } else {
        await _pollPairing();
      }
      _online = true;
      _notice = null;
    } on ApiException catch (error) {
      await _handleApiError(error);
    }
  }

  Future<void> _createRequest() async {
    final identity = _identity!;
    final signature = await identity.sign(
      '$_pairingMessagePrefix${identity.publicKey}',
    );
    final request = await api.createPairing(
      publicKey: identity.publicKey,
      signature: signature,
      platform: platform,
      deviceName: deviceName,
      appVersion: appVersion,
      keyStorage: store.kind,
    );
    _requestId = request.requestId;
    _code = request.code;
    await store.write(_requestIdKey, request.requestId);
    _setPhase(TerminalPhase.showingCode);
  }

  Future<void> _pollPairing() async {
    final status = await api.pairingStatus(
      requestId: _requestId!,
      publicKey: _identity!.publicKey,
    );

    if (status.status == 'expired') {
      await _renewRequest();
      return;
    }
    if (status.status == 'waiting') {
      // Ao reabrir o app, o código precisa ser buscado de novo.
      if (_code == null) {
        await _createRequest();
      }
      return;
    }

    final terminalId = status.terminalId!;
    if (_terminalId != terminalId) {
      _terminalId = terminalId;
      await store.write(_terminalIdKey, terminalId);
      logger?.info('Código aceito', fields: {'terminal_id': terminalId});
    }
    _code = null;

    switch (status.terminalStatus) {
      case 'active':
        await _rememberStatus('active');
        _setPhase(TerminalPhase.ready);
        await _sendHeartbeat();
      case 'blocked':
        await _rememberStatus('blocked');
        _setPhase(TerminalPhase.blocked);
      case 'revoked':
        await _rememberStatus('revoked');
        _setPhase(TerminalPhase.revoked);
      default:
        await _rememberStatus('pending');
        _setPhase(TerminalPhase.awaitingApproval);
    }
  }

  Future<void> _renewRequest() async {
    await store.delete(_requestIdKey);
    _requestId = null;
    _code = null;
    await _createRequest();
  }

  Future<void> _sendHeartbeat() async {
    final token = await _validToken();
    final number = await api.heartbeat(
      accessToken: token.value,
      appVersion: appVersion,
      lastSyncAt: sync?.lastPullAt,
    );
    if (number != null && number != _terminalNumber) {
      _terminalNumber = number;
      await store.write(_terminalNumberKey, number.toString());
    }
    if (_phase != TerminalPhase.ready) {
      logger?.info('Terminal liberado');
    }
    await _rememberStatus('active');
    _setPhase(TerminalPhase.ready);
    await sync?.pull(token.value);
  }

  Future<AccessToken> _validToken() async {
    final current = _token;
    if (current != null &&
        current.expiresAt.isAfter(_clock().add(_tokenRenewalMargin))) {
      return current;
    }
    final challenge = await api.challenge(_terminalId!);
    final signature = await _identity!.sign(
      '$_challengeMessagePrefix$challenge',
    );
    return _token = await api.token(challenge: challenge, signature: signature);
  }

  Future<void> _handleApiError(ApiException error) async {
    switch (error.code) {
      case 'FA001' || 'FA009' || 'FA000' || 'FA008':
        // Sem conexão, o PDV continua na situação atual.
        _online = false;
        if (_phase == TerminalPhase.loading ||
            _phase == TerminalPhase.showingCode) {
          _notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
        }
      case 'FA304':
        _online = true;
        _token = null;
        _notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
        await _rememberStatus('blocked');
        _setPhase(TerminalPhase.blocked);
      case 'FA305':
        _online = true;
        _token = null;
        _notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
        await _rememberStatus('revoked');
        _setPhase(TerminalPhase.revoked);
      case 'FA307':
        _online = true;
        await _rememberStatus('pending');
        _setPhase(TerminalPhase.awaitingApproval);
      case 'FA306':
        await _handleIdentityRejected(error);
      case 'FA301':
        // A solicitação não existe mais: pede um código novo.
        await _renewRequest();
      default:
        _online = true;
        _notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
    }
  }

  // Token recusado pode ser só vencimento. Se a assinatura nova também falhar,
  // o terminal não é mais reconhecido e precisa de um novo cadastro.
  Future<void> _handleIdentityRejected(ApiException error) async {
    if (_token != null) {
      _token = null;
      return;
    }
    _notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
    await _rememberStatus('revoked');
    _setPhase(TerminalPhase.revoked);
  }

  Future<void> _rememberStatus(String status) =>
      store.write(_lastStatusKey, status);

  void _setPhase(TerminalPhase phase) {
    _phase = phase;
    if (!_disposed) notifyListeners();
  }
}
