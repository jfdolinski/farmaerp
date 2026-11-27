import 'package:flutter/material.dart' hide Text;

import 'caps.dart';
import 'pdv_theme.dart';

/// Rodapé das janelas com campos: lembra que o Enter avança (e conclui no último campo) e o Esc fecha.
/// Vai como primeiro item das ações, à esquerda dos botões.
class KeysHint extends StatelessWidget {
  const KeysHint({super.key, this.enter = 'avança'});

  /// O que o Enter faz nesta janela.
  final String enter;

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      child: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Row(
          key: const Key('keys-hint'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Keycap('Enter'),
            Padding(padding: const EdgeInsets.only(left: 6, right: 14), child: Text(enter, style: _label)),
            const _Keycap('Esc'),
            const Padding(padding: EdgeInsets.only(left: 6), child: Text('fecha', style: _label)),
          ],
        ),
      ),
    );
  }

  static const _label = TextStyle(fontSize: 12, color: PdvColors.inkSoft);
}

/// Tecla desenhada como no teclado: borda e uma base mais grossa embaixo.
class _Keycap extends StatelessWidget {
  const _Keycap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: PdvColors.paper,
        borderRadius: const BorderRadius.all(Radius.circular(5)),
        border: Border.all(color: PdvColors.line),
        boxShadow: const [BoxShadow(color: PdvColors.inkSoft, offset: Offset(0, 2))],
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: PdvColors.ink)),
    );
  }
}
