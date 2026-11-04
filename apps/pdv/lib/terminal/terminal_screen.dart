import 'package:flutter/material.dart';

import '../core/error_display.dart';
import 'terminal_controller.dart';

class TerminalScreen extends StatelessWidget {
  const TerminalScreen({super.key, required this.controller});

  final TerminalController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
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
        return [
          const Icon(Icons.check_circle, size: 56, color: Colors.green),
          const SizedBox(height: 16),
          _title(context, 'Terminal aprovado'),
          if (controller.terminalNumber != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Terminal número ${controller.terminalNumber}'),
            ),
          const Text(
            'Aguardando a carga inicial de dados da filial antes de liberar '
            'as vendas.',
            textAlign: TextAlign.center,
          ),
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
          notice.reference,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
