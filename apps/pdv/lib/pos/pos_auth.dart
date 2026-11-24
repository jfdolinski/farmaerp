import 'package:uuid/uuid.dart';

import '../core/local_logger.dart';
import '../local/local_database.dart';
import 'pin.dart';

/// Erro do caixa com código do catálogo: a tela mostra a mensagem, o log fica com o código.
class PosException implements Exception {
  const PosException(this.code);

  final String code;

  @override
  String toString() => 'PosException($code)';
}

/// Quantos PINs errados seguidos bloqueiam a pessoa neste terminal, e por quanto tempo.
const maxPinFailures = 5;
const pinLockDuration = Duration(minutes: 5);

/// Formas de se identificar no PDV. A câmera e a digital se encaixam aqui quando chegarem.
enum AuthMethod {
  pin('pin', 'PIN'),
  face('face', 'Câmera'),
  fingerprint('fingerprint', 'Digital');

  const AuthMethod(this.code, this.label);

  final String code;
  final String label;
}

/// Para que a pessoa se identificou: entrar no caixa, liberar algo de outra pessoa ou atender
/// como vendedor. Vai junto no registro que sobe para a central.
enum AuthPurpose { login, approval, seller }

/// Forma de entrar configurada na retaguarda: qualquer uma, só PIN, só câmera ou só digital.
Set<AuthMethod> allowedMethods(String mode) => switch (mode) {
  'any' => AuthMethod.values.toSet(),
  'face' => {AuthMethod.face},
  'fingerprint' => {AuthMethod.fingerprint},
  _ => {AuthMethod.pin},
};

/// Serviço único de autenticação do PDV: toda entrada e toda liberação passam por aqui, com a
/// forma de entrar de cada pessoa, o bloqueio por tentativas e o registro que sobe pela outbox.
/// Confere tudo neste terminal, sem internet.
class PosAuth {
  PosAuth({
    required this.database,
    this.logger,
    DateTime Function()? clock,
    this.available = const {AuthMethod.pin},
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  /// Formas que este terminal tem como usar agora (câmera e leitor ligados e funcionando). Muda
  /// quando a câmera abre ou falha.
  Set<AuthMethod> available;

  /// Formas que a pessoa pode usar neste terminal agora.
  Set<AuthMethod> usableBy(LocalUser user) => allowedMethods(user.authMode).intersection(available);

  /// Na entrada por código, a pessoa não pode usar o PIN (só câmera ou só digital): o gerente
  /// libera. Vale também quando a câmera ou o leitor falham.
  bool needsRelease(LocalUser user) => !allowedMethods(user.authMode).contains(AuthMethod.pin);

  /// Pessoa pelo código digitado (sem conferir nada ainda).
  LocalUser? userByCodeText(String codeText) {
    final code = int.tryParse(codeText.trim());
    return code == null ? null : database.userByCode(code);
  }

  /// Confere o PIN de quem entra, libera ou atende. Quem não entra com PIN recebe FA820.
  Future<LocalUser> verify(
    String codeText,
    String pin, {
    String? permission,
    AuthPurpose purpose = AuthPurpose.approval,
  }) async {
    final user = userByCodeText(codeText);
    // Código desconhecido e PIN errado dão a mesma mensagem: não revela quem existe.
    if (user == null) throw const PosException('FA966');
    if (!allowedMethods(user.authMode).contains(AuthMethod.pin)) throw const PosException('FA820');
    if (user.pinHash == null) throw const PosException('FA968');

    final now = _clock();
    final attempts = database.pinAttempts(user.id);
    if (attempts.lockedUntil != null && attempts.lockedUntil!.isAfter(now)) {
      throw const PosException('FA967');
    }
    if (!await verifyPin(pin, user.pinHash!)) {
      final failures = attempts.failures + 1;
      final locked = failures >= maxPinFailures;
      database.recordPinAttempt(
        user.id,
        failures: locked ? 0 : failures,
        lockedUntil: locked ? now.add(pinLockDuration) : null,
      );
      _record(user, locked ? 'locked' : 'failure', purpose, AuthMethod.pin.code, now: now);
      // O log guarda o código do usuário, nunca o PIN digitado.
      logger?.warn('PIN incorreto no PDV', fields: {'user_code': user.code, 'locked': locked, 'error_code': locked ? 'FA967' : 'FA966'});
      throw PosException(locked ? 'FA967' : 'FA966');
    }
    database.recordPinAttempt(user.id, failures: 0);
    if (permission != null && !user.can(permission)) throw const PosException('FA969');
    _record(user, 'success', purpose, AuthMethod.pin.code, now: now);
    return user;
  }

  /// Entrada liberada pelo gerente para quem não consegue usar a forma dele (câmera ou leitor
  /// com defeito, ou ainda sem cadastro). Quem libera confere o próprio PIN, precisa de "Liberar
  /// a entrada no PDV" e não pode ser a mesma pessoa. Fica registrado com os dois.
  Future<LocalUser> release(
    String codeText,
    String managerCode,
    String managerPin, {
    String? permission,
    AuthPurpose purpose = AuthPurpose.login,
  }) async {
    final user = userByCodeText(codeText);
    if (user == null) throw const PosException('FA966');
    if (permission != null && !user.can(permission)) throw const PosException('FA969');
    final manager = await verify(managerCode, managerPin);
    if (manager.id == user.id || !manager.can('users.release_login')) throw const PosException('FA821');
    _record(user, 'success', purpose, 'manager_release', authorizedBy: manager.id, now: _clock());
    logger?.info('Entrada liberada pelo gerente', fields: {'user_code': user.code, 'manager_code': manager.code});
    return user;
  }

  /// Pessoa reconhecida pela câmera (com prova de vida). Quem não entra pela câmera recebe FA824.
  LocalUser acceptFace(LocalUser user, {String? permission, AuthPurpose purpose = AuthPurpose.login}) {
    if (!allowedMethods(user.authMode).contains(AuthMethod.face)) throw const PosException('FA824');
    if (permission != null && !user.can(permission)) throw const PosException('FA969');
    _record(user, 'success', purpose, AuthMethod.face.code, now: _clock());
    logger?.info('Entrada pela câmera', fields: {'user_code': user.code});
    return user;
  }

  /// Registro da autenticação para a central (sem PIN, sem dados pessoais além do id).
  void _record(LocalUser user, String event, AuthPurpose purpose, String method, {String? authorizedBy, required DateTime now}) {
    database.enqueue('auth_event', {
      'id': const Uuid().v7(),
      'user_id': user.id,
      'event': event,
      'purpose': purpose.name,
      'method': method,
      'authorized_by': authorizedBy,
      'occurred_at': now.toUtc().toIso8601String(),
    }, now: now);
  }
}
