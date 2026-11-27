import 'package:flutter/material.dart' hide Text;

import 'caps.dart';
import 'keys_hint.dart';
import 'pdv_theme.dart';

/// Tamanho das janelas internas do PDV. Só existem estes dois: mudou aqui, muda em todas.
enum PdvWindowSize {
  /// Consultas, extratos e lançamentos (receita, devolução, crediário, caixa): 80% da tela.
  large,

  /// Perguntas rápidas (cancelar, descartar, liberação do supervisor): largura fixa, altura do conteúdo.
  compact,
}

/// Moldura única das janelas internas do PDV: cabeçalho (título, linha de apoio, etiquetas e o X
/// de fechar), corpo com rolagem e rodapé com as teclas e os botões. Toda janela de consulta,
/// extrato ou lançamento usa esta; ajuste de visual se faz aqui, e vale para todas.
class PdvWindow extends StatelessWidget {
  const PdvWindow({
    super.key,
    required this.title,
    required this.content,
    this.subtitle,
    this.tags = const [],
    this.actions = const [],
    this.size = PdvWindowSize.large,
    this.scroll = true,
    this.closeKey,
    this.onClose,
  });

  /// Parte da tela que a janela grande ocupa, na largura e na altura.
  static const largeShare = 0.8;

  /// Largura da janela compacta.
  static const compactWidth = 560.0;

  final String title;
  final String? subtitle;

  /// Etiquetas ao lado do título (código, documento, curva).
  final List<String> tags;
  final Widget content;

  /// Botões do rodapé, da esquerda para a direita; o principal por último (FilledButton).
  final List<Widget> actions;
  final PdvWindowSize size;

  /// O corpo rola sozinho. Falso quando o conteúdo já tem a própria rolagem (tabela, lista grande).
  final bool scroll;
  final Key? closeKey;

  /// O que o X faz. Vazio: fecha a janela.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final large = size == PdvWindowSize.large;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: content,
    );
    return Dialog(
      key: const Key('pdv-window'),
      insetPadding: EdgeInsets.zero,
      backgroundColor: PdvColors.paper,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PdvShape.panel),
      ),
      // O espaço da tela que a janela tem (o mesmo que o caixa vê).
      child: LayoutBuilder(
        builder: (context, screen) {
          final width = large
              ? screen.maxWidth * largeShare
              : compactWidth.clamp(0.0, screen.maxWidth * 0.9);
          final maxHeight = screen.maxHeight * largeShare;
          return SizedBox(
            key: const Key('pdv-window-frame'),
            width: width,
            height: large ? maxHeight : null,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Column(
                mainAxisSize: large ? MainAxisSize.max : MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    title: title,
                    subtitle: subtitle,
                    tags: tags,
                    closeKey: closeKey,
                    onClose: onClose,
                  ),
                  Flexible(
                    fit: large ? FlexFit.tight : FlexFit.loose,
                    child: scroll ? SingleChildScrollView(child: body) : body,
                  ),
                  if (actions.isNotEmpty) _Footer(actions: actions),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.closeKey,
    required this.onClose,
  });

  final String title;
  final String? subtitle;
  final List<String> tags;
  final Key? closeKey;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PdvColors.surface,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: PdvColors.line)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 12, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    key: const Key('pdv-window-title'),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: PdvColors.ink,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: const TextStyle(
                          fontSize: 14,
                          color: PdvColors.inkSoft,
                        ),
                      ),
                    ),
                  if (tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final tag in tags)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: PdvColors.paper,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: PdvColors.line),
                              ),
                              child: Text(
                                tag,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: PdvColors.inkSoft,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            // Fora da ordem do Tab e do Enter: quem fecha pelo teclado usa o Esc.
            ExcludeFocus(
              child: IconButton(
                key: closeKey ?? const Key('pdv-window-close'),
                tooltip: 'FECHAR (ESC)',
                icon: const Icon(Icons.close),
                onPressed: onClose ?? () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.actions});

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final hints = [for (final action in actions) if (action is KeysHint) action];
    final buttons = [for (final action in actions) if (action is! KeysHint) action];
    return Container(
      decoration: const BoxDecoration(
        color: PdvColors.surface,
        border: Border(top: BorderSide(color: PdvColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      // As teclas (Enter e Esc) à esquerda; os botões à direita, o principal por último.
      child: Row(
        children: [
          ...hints,
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: buttons,
            ),
          ),
        ],
      ),
    );
  }
}
