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
