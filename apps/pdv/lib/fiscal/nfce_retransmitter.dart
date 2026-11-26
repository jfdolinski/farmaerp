import '../core/local_logger.dart';
import '../local/local_database.dart';
import 'nfce_credentials.dart';
import 'sefaz.dart';

/// Situação das notas em contingência, para a barra do caixa: [warning] passou da metade do prazo
/// da filial; [overdue] passou do prazo.
class NfceContingencyAlert {
  const NfceContingencyAlert({required this.count, required this.oldestHours, required this.warning, required this.overdue});

  final int count;
  final int oldestHours;
  final bool warning;
  final bool overdue;

  String get text => overdue
      ? 'NFC-e em contingência há $oldestHours h: prazo vencido. Verifique a internet do caixa.'
      : 'NFC-e em contingência: $count (a mais antiga há $oldestHours h)';
}

/// Prazo da contingência da filial (padrão 24 horas).
Duration contingencyLimitOf(LocalDatabase database) =>
    Duration(hours: (((database.fiscal?['nfce'] as Map?)?['contingency_hours'] as num?) ?? 24).toInt());

/// Alerta das notas em contingência. Null quando não há nenhuma.
NfceContingencyAlert? nfceContingencyAlert(LocalDatabase database, DateTime now, {required Duration limit}) {
  final pending = database.nfceContingency();
  final oldest = pending.oldest;
  if (pending.count == 0 || oldest == null) return null;
  final age = now.difference(oldest);
  return NfceContingencyAlert(
    count: pending.count,
    oldestHours: age.inHours,
    warning: age * 2 >= limit,
    overdue: age >= limit,
  );
}

/// Transmite as notas em contingência (e as que ficaram pendentes sem resposta) quando a Sefaz
/// volta a responder. Roda depois de cada sincronização; uma rodada por vez.
class NfceRetransmitter {
  NfceRetransmitter({
    required this.database,
    required this.credentials,
    required this.sefaz,
    required this.terminalId,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalDatabase database;
  final NfceCredentialService credentials;
  final SefazClient sefaz;
  final String? Function() terminalId;
  final LocalLogger? logger;
  final DateTime Function() _clock;
  bool _running = false;

  /// Devolve quantas notas tiveram resposta da Sefaz nesta rodada.
  Future<int> tick() async {
    if (_running) return 0;
    final waiting = database.nfceToTransmit();
    final terminal = terminalId();
    final uf = (database.fiscal?['branch'] as Map?)?['state'] as String?;
    if (waiting.isEmpty || terminal == null || uf == null) return 0;
    _running = true;
    var answered = 0;
    try {
      final NfceCredentials? opened;
      try {
        opened = await credentials.credentials(terminalId: terminal);
      } on NfceCredentialException {
        return 0;
      }
      if (opened == null) return 0;
      for (final nfce in waiting) {
        final signed = nfce.xml;
        final result = await sefaz.authorize(signedNfe: signed, uf: uf, environment: nfce.environment, credentials: opened);
        final now = _clock();
        switch (result) {
          case SefazAuthorized():
            database.updateNfce(
              nfce.copyWith(
                status: 'authorized',
                protocol: result.protocol,
                statusCode: result.statusCode,
                reason: result.reason,
                xml: result.procXml,
                authorizedAt: result.authorizedAt,
              ),
              now: now,
            );
            answered += 1;
            logger?.info('NFC-e transmitida e autorizada', fields: {'number': nfce.number, 'emission_type': nfce.emissionType});
          case SefazRejected():
            database.updateNfce(nfce.copyWith(status: 'rejected', statusCode: result.statusCode, reason: result.reason), now: now);
            answered += 1;
            logger?.warn('NFC-e transmitida e recusada', fields: {'number': nfce.number, 'status_code': result.statusCode});
          case SefazUnavailable():
            // A Sefaz continua sem responder: para a rodada e tenta na próxima.
            database.countNfceAttempt(nfce.id, now: now);
            return answered;
        }
      }
      return answered;
    } finally {
      _running = false;
    }
  }
}
