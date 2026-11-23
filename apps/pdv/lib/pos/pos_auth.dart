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

/// Entrada no PDV por código e PIN, conferida aqui mesmo (funciona sem internet).
class PosAuth {
  PosAuth({required this.database, this.logger, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  /// Confere o PIN de quem pode vender (operador) ou de quem libera (supervisor).
  Future<LocalUser> verify(String codeText, String pin, {String? permission}) async {
    final code = int.tryParse(codeText.trim());
    final user = code == null ? null : database.userByCode(code);
    // Código desconhecido e PIN errado dão a mesma mensagem: não revela quem existe.
    if (user == null) throw const PosException('FA966');
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
      // O log guarda o código do usuário, nunca o PIN digitado.
      logger?.warn('PIN incorreto no PDV', fields: {'user_code': user.code, 'locked': locked, 'error_code': locked ? 'FA967' : 'FA966'});
      throw PosException(locked ? 'FA967' : 'FA966');
    }
    database.recordPinAttempt(user.id, failures: 0);
    if (permission != null && !user.can(permission)) throw const PosException('FA969');
    return user;
  }
}
