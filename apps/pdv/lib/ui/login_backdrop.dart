import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'login_image.dart';
import 'pdv_motion.dart';
import 'pdv_theme.dart';

/// Tela de entrada do caixa: a imagem da plataforma ocupa a tela toda (sem ela, a cor do terminal)
/// e o cartão de entrada flutua à direita, no meio da altura. Em tela estreita o cartão vai para o
/// centro. A câmera do rosto abre dentro do próprio cartão.
class LoginBackdrop extends StatelessWidget {
  const LoginBackdrop({super.key, required this.child, this.image, this.wide = false});

  final Widget child;
  final LoginImageStore? image;

  /// Cartão mais largo (câmera aberta).
  final bool wide;

  /// Abaixo desta largura o cartão fica no centro.
  static const narrowWidth = 760.0;

  @override
  Widget build(BuildContext context) {
    final store = image;
    return store == null
        ? _build(context, null, null)
        : ListenableBuilder(listenable: store, builder: (context, _) => _build(context, store.bytes, store.sha256));
  }

  Widget _build(BuildContext context, Uint8List? bytes, String? version) {
    final primary = Theme.of(context).colorScheme.primary;
    final darker = Color.lerp(primary, Colors.black, 0.35)!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < narrowWidth;
        final right = narrow ? 16.0 : constraints.maxWidth * 0.07;
        // Largura fixa do cartão (mais larga com a câmera), sem passar da tela.
        final cardWidth = (wide ? 540.0 : 420.0).clamp(0.0, constraints.maxWidth - 16 - right);
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              key: const Key('login-backdrop-brand'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [primary, darker],
                ),
              ),
            ),
            if (bytes != null) ...[
              PdvAppear(
                key: ValueKey(version),
                offset: Offset.zero,
                scale: 1.03,
                duration: const Duration(milliseconds: 600),
                child: Image.memory(
                  bytes,
                  key: const Key('login-backdrop-image'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  // Imagem que não abre: fica a cor do terminal por baixo.
                  errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                ),
              ),
              // Véu leve do lado do cartão: o conjunto não briga com fotos muito claras.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [Color(0x470A1916), Color(0x000A1916)],
                    stops: [0, 0.55],
                  ),
                ),
              ),
            ],
            const Positioned(left: 32, top: 24, child: _BrandMark()),
            Align(
              alignment: narrow ? Alignment.center : Alignment.centerRight,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, narrow ? 72 : 24, right, 24),
                child: PdvAppear(
                  offset: narrow ? const Offset(0, 16) : const Offset(24, 0),
                  child: SizedBox(
                    width: cardWidth,
                    child: Container(
                      key: const Key('login-card'),
                      padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                      decoration: BoxDecoration(
                        color: PdvColors.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: const Color(0x66FFFFFF)),
                        boxShadow: const [
                          BoxShadow(color: Color(0x1F0A1916), blurRadius: 6, offset: Offset(0, 2)),
                          BoxShadow(color: Color(0x520A1916), blurRadius: 64, offset: Offset(0, 24)),
                        ],
                      ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(color: Color(0x59000000), blurRadius: 8)];
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.add_box_rounded, color: Colors.white, size: 22, shadows: shadow),
        SizedBox(width: 8),
        Text(
          'FarmaERP',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, shadows: shadow),
        ),
      ],
    );
  }
}
