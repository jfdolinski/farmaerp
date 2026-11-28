import 'package:flutter/material.dart' hide Text, InputDecoration;

import '../core/error_display.dart';
import '../ui/caps.dart';
import 'terminal_controller.dart';

class TerminalScreen extends StatelessWidget {
  const TerminalScreen({super.key, required this.controller});

  final TerminalController controller;

  @override
  Widget build(BuildContext context) {
    final sync = controller.sync;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, ?sync]),
      builder: (context, _) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [..._content(context), ..._footer(context)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    switch (controller.phase) {
      case TerminalPhase.loading:
        return [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Preparando o terminal...'),
        ];
      case TerminalPhase.showingCode:
        return [
          _title(context, 'Cadastre este terminal'),
          const Text(
            'Na retaguarda, abra Terminais e digite o código abaixo.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SelectableText(
            controller.displayCode ?? '',
            key: const Key('pairing-code'),
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Se o código expirar, um novo aparece aqui automaticamente.',
            textAlign: TextAlign.center,
          ),
        ];
      case TerminalPhase.awaitingApproval:
        return [
          const Icon(Icons.hourglass_top, size: 56),
          const SizedBox(height: 16),
          _title(context, 'Aguardando aprovação'),
          const Text(
            'O código foi aceito. Peça ao administrador para aprovar este '
            'terminal na retaguarda.',
            textAlign: TextAlign.center,
          ),
        ];
      case TerminalPhase.ready:
        final sync = controller.sync;
        final loaded = sync != null && sync.initialLoadDone;
        final lastPullAt = sync?.lastPullAt;
        return [
          Icon(
            loaded ? Icons.check_circle : Icons.cloud_download,
            size: 56,
            color: loaded ? Colors.green : null,
          ),
          const SizedBox(height: 16),
          _title(context, 'Terminal aprovado'),
          if (controller.terminalNumber != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Terminal número ${controller.terminalNumber}'),
            ),
          if (!loaded && sync?.resetNotice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(sync!.resetNotice!, key: const Key('local-reset'), textAlign: TextAlign.center),
            ),
          if (!loaded) ..._preparing(context),
          if (loaded) ...[
            const Text(
              'Dados da filial prontos neste terminal.',
              key: Key('store-ready'),
              textAlign: TextAlign.center,
            ),
            if (lastPullAt != null)
              Text(
                'Última atualização: ${_time(lastPullAt.toLocal())}',
                key: const Key('last-sync'),
                textAlign: TextAlign.center,
              ),
          ],
        ];
      case TerminalPhase.blocked:
        return [
          const Icon(Icons.block, size: 56, color: Colors.red),
          const SizedBox(height: 16),
          _title(context, 'Terminal bloqueado'),
          const Text(
            'Procure o administrador da rede. Este terminal volta a funcionar '
            'assim que for desbloqueado.',
            textAlign: TextAlign.center,
          ),
        ];
      case TerminalPhase.revoked:
        return [
          const Icon(Icons.gpp_bad, size: 56, color: Colors.red),
          const SizedBox(height: 16),
          _title(context, 'Terminal revogado'),
          const Text(
            'Este aparelho não está mais autorizado. Para voltar a usá-lo, '
            'faça um novo cadastro.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: controller.startNewPairing,
            child: const Text('Fazer novo cadastro'),
          ),
        ];
    }
  }

  List<Widget> _footer(BuildContext context) {
    final notice = controller.notice;
    final isFinal =
        controller.phase == TerminalPhase.blocked ||
        controller.phase == TerminalPhase.revoked;
    return [
      if (!controller.online) ...[
        const SizedBox(height: 24),
        const Text(
          'Sem conexão com a central. Tentando novamente...',
          key: Key('offline-notice'),
          textAlign: TextAlign.center,
        ),
      ],
      if (notice != null) ...[
        const SizedBox(height: 24),
        // Sem conexão, o aviso acima já explica; fica só a referência.
        _Notice(notice: notice, showTexts: !isFinal && controller.online),
      ],
    ];
  }

  /// Carga inicial: a venda só é liberada quando ela termina.
  List<Widget> _preparing(BuildContext context) {
    final sync = controller.sync;
    final total = sync?.total;
    final received = sync?.received ?? 0;
    final progress = total != null && total > 0
        ? (received / total).clamp(0.0, 1.0)
        : null;
    return [
      Text(
        'Preparando a loja',
        key: const Key('preparing-store'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 12),
      LinearProgressIndicator(key: const Key('load-progress'), value: progress),
      const SizedBox(height: 12),
      Text(
        total != null && total > 0
            ? 'Recebendo os dados da filial: $received de $total.'
            : 'Recebendo os dados da filial...',
        textAlign: TextAlign.center,
      ),
      const Text(
        'As vendas são liberadas quando a carga terminar. Isso só demora '
        'na primeira vez.',
        textAlign: TextAlign.center,
      ),
    ];
  }

  String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  Widget _title(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.headlineSmall,
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.notice, required this.showTexts});

  final ErrorDisplay notice;

  /// As telas de bloqueio e revogação já explicam a situação.
  final bool showTexts;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showTexts) ...[
          Text(notice.message, textAlign: TextAlign.center),
          Text(notice.action, textAlign: TextAlign.center),
        ],
        SelectableText(
          caps(notice.reference),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
