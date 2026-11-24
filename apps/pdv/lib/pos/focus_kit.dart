import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../ui/caps.dart';

/// Seleciona todo o texto do campo: o operador digita por cima, sem apagar.
void selectAllText(TextEditingController controller) {
  controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
}

/// Campo de número: ao entrar (pelo teclado ou com o mouse), o valor fica todo selecionado.
class NumberField extends StatefulWidget {
  const NumberField({
    super.key,
    required this.controller,
    this.focusNode,
    this.autofocus = false,
    this.enabled,
    this.decoration = const InputDecoration(),
    this.decimal = false,
    this.obscureText = false,
    this.inputFormatters,
    this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? enabled;
  final InputDecoration decoration;
  final bool decimal;
  final bool obscureText;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.focusNode ?? _own;
    if (old != _focus) {
      old?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  void _onFocus() {
    if (!_focus.hasFocus) return;
    // Depois do quadro: o clique do mouse põe o cursor antes; aqui a seleção vence.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focus.hasFocus) selectAllText(widget.controller);
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      obscureText: widget.obscureText,
      decoration: widget.decoration,
      keyboardType: TextInputType.numberWithOptions(decimal: widget.decimal),
      inputFormatters: widget.inputFormatters ??
          [widget.decimal ? FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')) : FilteringTextInputFormatter.digitsOnly],
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      onTap: () => selectAllText(widget.controller),
    );
  }
}

/// Setas e Enter num campo com sugestões (autocompletar): sobe, desce e escolhe; Esc fecha.
class SuggestionKeys extends StatelessWidget {
  const SuggestionKeys({
    super.key,
    required this.child,
    required this.onMove,
    required this.onClose,
  });

  final Widget child;

  /// +1 desce, -1 sobe.
  final ValueChanged<int> onMove;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => onMove(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => onMove(-1),
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: child,
    );
  }
}
