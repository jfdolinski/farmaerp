import 'package:flutter/widgets.dart';

/// Movimento do PDV: curto e discreto, só para mostrar o que mudou. Durações e curva ficam aqui,
/// como as cores no tema; mudou aqui, muda em todas as telas. Com "Mostrar animações" desligado no
/// sistema (MediaQuery.disableAnimations), nada se mexe: tudo aparece na hora.
abstract final class PdvMotion {
  /// Trocas pequenas: cor da linha escolhida, número novo.
  static const fast = Duration(milliseconds: 150);

  /// Entradas: janela, aviso, item novo, painel.
  static const normal = Duration(milliseconds: 220);

  /// Folga entre itens que entram em sequência (cartões do extrato).
  static const stagger = Duration(milliseconds: 45);

  /// Desacelera no fim: começa rápido e assenta suave.
  static const curve = Curves.easeOutCubic;

  /// O sistema pediu para não animar.
  static bool off(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// A duração pedida, ou zero quando o sistema pediu para não animar.
  static Duration of(BuildContext context, Duration duration) =>
      off(context) ? Duration.zero : duration;
}

/// Entrada suave de um pedaço da tela: esmaece e desliza [offset] pixels até o lugar (e cresce de
/// [scale] até o tamanho, se pedido). Anima uma vez, quando aparece; para animar de novo numa troca,
/// dê uma chave nova. Não atrasa nada: o conteúdo já está na tela e responde desde o primeiro quadro.
class PdvAppear extends StatefulWidget {
  const PdvAppear({
    super.key,
    required this.child,
    this.offset = const Offset(0, 8),
    this.scale = 1,
    this.delay = Duration.zero,
    this.duration = PdvMotion.normal,
  });

  final Widget child;

  /// De onde vem, em pixels, até o lugar final.
  final Offset offset;

  /// Tamanho no começo (1 = sem crescer).
  final double scale;

  /// Espera antes de começar (para entrar em sequência), dentro da mesma animação: sem temporizador.
  final Duration delay;
  final Duration duration;

  @override
  State<PdvAppear> createState() => _PdvAppearState();
}

class _PdvAppearState extends State<PdvAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  @override
  void initState() {
    super.initState();
    final total = widget.delay + widget.duration;
    _controller = AnimationController(vsync: this, duration: total);
    final start = total.inMicroseconds == 0
        ? 0.0
        : widget.delay.inMicroseconds / total.inMicroseconds;
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, 1, curve: PdvMotion.curve),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (PdvMotion.off(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final t = _progress.value;
        Widget result = Transform.translate(
          offset: widget.offset * (1 - t),
          child: child,
        );
        if (widget.scale != 1) {
          result = Transform.scale(
            scale: widget.scale + (1 - widget.scale) * t,
            child: result,
          );
        }
        return Opacity(opacity: t, child: result);
      },
    );
  }
}
