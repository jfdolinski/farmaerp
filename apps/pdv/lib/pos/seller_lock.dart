import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;

import '../ui/caps.dart';
import '../ui/pdv_theme.dart';
import 'money.dart';
import 'pos_controller.dart';
import 'quote_panels.dart';

/// Tela preta depois de concluir a venda ou o orçamento: mostra o que foi concluído (e o troco, bem
/// grande) e só libera o caixa quando o vendedor do próximo atendimento se identifica. Com ela aberta,
/// só funcionam sangria, suprimento e fechar caixa (F6, F7 e F8).
class SellerLockScreen extends StatelessWidget {
  const SellerLockScreen({super.key, required this.controller, required this.sellerFocus, required this.onIdentified});

  final PosController controller;
  final FocusNode sellerFocus;
  final VoidCallback onIdentified;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sale = controller.quoteMode ? null : controller.lastSale;
        final change = sale?.changeCents ?? 0;
        final notice = controller.notice;
        final cashKeys = !controller.quoteMode && controller.operator != null && controller.session != null;
        return Material(
          key: const Key('seller-lock'),
          color: Colors.black,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (controller.info != null)
                        Text(
                          controller.info!,
                          key: const Key('seller-lock-info'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                      if (change > 0) ...[
                        const SizedBox(height: 24),
                        const Text('Troco', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 22)),
                        Text(
                          formatCents(change),
                          key: const Key('seller-lock-change'),
                          textAlign: TextAlign.center,
                          style: moneyStyle(context, size: 88, color: Colors.white),
                        ),
                      ],
                      if (notice != null) ...[
                        const SizedBox(height: 20),
                        Container(
                          key: const Key('seller-lock-notice'),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A2A00),
                            borderRadius: BorderRadius.circular(PdvShape.field),
                            border: Border.all(color: const Color(0xFFE0A800)),
                          ),
                          child: Text(
                            '${notice.message} ${notice.action}',
                            style: const TextStyle(color: Color(0xFFFFE08A), fontSize: 16),
                          ),
                        ),
                      ],
                      const SizedBox(height: 32),
                      SellerPanel(controller: controller, focusNode: sellerFocus, onIdentified: onIdentified),
                      if (cashKeys) ...[
                        const SizedBox(height: 20),
                        const Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 24,
                          runSpacing: 8,
                          children: [
                            _LockKey('F6', 'Sangria'),
                            _LockKey('F7', 'Suprimento'),
                            _LockKey('F8', 'Fechar caixa'),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Tecla que continua valendo com a tela bloqueada.
class _LockKey extends StatelessWidget {
  const _LockKey(this.key_, this.label);

  final String key_;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: Colors.white54),
          ),
          child: Text(key_, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
      ],
    );
  }
}
