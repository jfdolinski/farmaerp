import 'package:flutter/foundation.dart';

import '../core/local_logger.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';

/// Descida da central para o banco local. Um pacote por vez, cada um numa transação.
class SyncService extends ChangeNotifier {
  SyncService({
    required this.api,
    required this.database,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final TerminalApi api;
  final LocalDatabase database;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  bool _running = false;
  bool get running => _running;

  /// A venda só é liberada depois da primeira carga completa.
  bool get initialLoadDone => database.syncState.initialLoadDone;

  DateTime? get lastPullAt => database.syncState.lastPullAt;

  /// Progresso da janela em andamento (recebidos de um total), para a tela.
  int get received => database.syncState.windowReceived;
  int? get total => database.syncState.windowTotal;

  /// Itens da outbox esperando envio.
  int get outboxPending => database.outboxPending;

  /// Chamado quando a cópia local foi refeita por ser de outro terminal (ex.: tirar o operador da tela).
  VoidCallback? onLocalReset;

  /// Aviso para a tela de carga quando a cópia local foi refeita (null se não foi).
  String? resetNotice;

  /// Sobe a outbox e depois desce o que mudou. Erros da API sobem para quem chamou. Com [terminalId],
  /// antes de tudo liga a cópia local a ele (cópia de outro terminal é refeita, ver
  /// [LocalDatabase.bindTerminal]).
  Future<void> run(String accessToken, {String? terminalId}) async {
    if (terminalId != null) bindTerminal(terminalId);
    await push(accessToken);
    await pull(accessToken);
  }

  /// Liga a cópia local ao terminal pareado. Se ela era de outro terminal, foi limpa: a carga
  /// inteira recomeça, o operador sai e a tela de carga avisa.
  void bindTerminal(String terminalId) {
    final previous = database.dataTerminalId;
    final result = database.bindTerminal(terminalId, now: _clock());
    if (result.binding != TerminalBinding.reset) return;
    // Aviso, sem dados pessoais: só os terminais e a contagem do que foi arquivado.
    logger?.warn(
      'Cópia local de outro terminal: arquivada e refeita',
      fields: {'previous_terminal_id': previous, 'terminal_id': terminalId, 'archived': result.archived},
    );
    resetNotice = result.archived > 0
        ? 'Este caixa foi pareado de novo. Os dados do pareamento anterior foram guardados à parte '
              '(${result.archived} itens não enviados ou notas fiscais) e a cópia da loja está sendo baixada de novo.'
        : 'Este caixa foi pareado de novo. A cópia da loja está sendo baixada de novo.';
    onLocalReset?.call();
    notifyListeners();
  }

  bool _pushing = false;

  /// Sobe a outbox em ordem, pacote por pacote, até esvaziar.
  Future<void> push(String accessToken) async {
    if (_pushing) return;
    _pushing = true;
    try {
      // Limite por rodada: o resto vai na próxima, sem segurar o sinal de vida.
      for (var round = 0; round < 50; round += 1) {
        final batch = database.nextOutboxBatch();
        if (batch.isEmpty) return;
        final results = await api.push(accessToken: accessToken, items: batch);
        database.markSent(batch, results, now: _clock());
        final conflicts = results.where((result) => result.outcome == 'conflict').length;
        if (conflicts > 0) {
          // Info, e não aviso: o aviso entraria na própria outbox.
          logger?.info('Itens recusados pela central viraram conflito', fields: {'count': conflicts});
        }
        notifyListeners();
        if (results.length < batch.length) return;
      }
    } finally {
      _pushing = false;
    }
  }

  /// Traz tudo o que mudou desde o último cursor. Erros da API sobem para quem chamou.
  Future<void> pull(String accessToken) async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      await _pullWindow(accessToken);
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _pullWindow(String accessToken) async {
    var state = database.syncState;
    if (state.cursor == null && state.windowUntil == null) {
      database.startFullLoad();
      state = database.syncState;
      logger?.info('Carga inicial iniciada', fields: {'generation': state.generation});
    }
    while (true) {
      final page = await api.pull(
        accessToken: accessToken,
        cursor: state.cursor,
        until: state.windowUntil,
        after: state.windowAfter,
      );
      // Formato novo na central: a cópia local é refeita por inteiro.
      if (state.cursor != null && state.format != null && page.format != state.format) {
        logger?.info(
          'Formato da descida mudou; refazendo a carga',
          fields: {'from': state.format, 'to': page.format},
        );
        database.startFullLoad();
        state = database.syncState;
        continue;
      }
      final fullLoad = state.cursor == null;
      database.applyPage(page, now: _clock());
      notifyListeners();
      state = database.syncState;
      if (page.next == null) {
        if (fullLoad) {
          logger?.info('Carga inicial concluída', fields: database.counts());
        }
        return;
      }
    }
  }
}
