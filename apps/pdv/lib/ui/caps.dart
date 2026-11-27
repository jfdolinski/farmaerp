import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';

import 'enter_form.dart';

/// O PDV escreve só em caixa alta. As telas importam o Material escondendo `Text`,
/// `InputDecoration` e `TextField` e usam estas versões, que convertem na hora de mostrar:
/// o texto guardado no código continua normal (e o log e o banco não mudam por isso).

/// Caixa alta respeitando o português (á → Á, ç → Ç).
String caps(String value) => value.toUpperCase();

/// Texto da tela em caixa alta.
class Text extends material.Text {
  const Text(
    super.data, {
    super.key,
    super.style,
    super.strutStyle,
    super.textAlign,
    super.textDirection,
    super.locale,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.semanticsLabel,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.selectionColor,
  });

  @override
  String? get data => super.data == null ? null : caps(super.data!);

  @override
  String? get semanticsLabel => super.semanticsLabel == null ? null : caps(super.semanticsLabel!);
}

/// Rótulos, dicas e mensagens dos campos em caixa alta.
class InputDecoration extends material.InputDecoration {
  const InputDecoration({
    super.icon,
    super.labelText,
    super.helperText,
    super.hintText,
    super.errorText,
    super.prefixIcon,
    super.prefixText,
    super.suffixIcon,
    super.suffixText,
    super.counterText,
    super.border,
    super.isDense,
    super.filled,
    super.contentPadding,
  });

  static String? _caps(String? value) => value == null ? null : caps(value);

  @override
  String? get labelText => _caps(super.labelText);
  @override
  String? get helperText => _caps(super.helperText);
  @override
  String? get hintText => _caps(super.hintText);
  @override
  String? get errorText => _caps(super.errorText);
  @override
  String? get prefixText => _caps(super.prefixText);
  @override
  String? get suffixText => _caps(super.suffixText);
}

/// O que o operador digita aparece em caixa alta (senha e PIN ficam como estão).
class UpperCaseFormatter extends TextInputFormatter {
  const UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final upper = caps(newValue.text);
    // Letra que muda de tamanho na conversão (raro): deixa como veio para não perder o cursor.
    if (upper.length != newValue.text.length) return newValue;
    return newValue.copyWith(text: upper);
  }
}

/// Campo de texto do PDV: digita em caixa alta.
class TextField extends material.TextField {
  const TextField({
    super.key,
    super.controller,
    super.focusNode,
    super.decoration,
    super.keyboardType,
    super.textInputAction,
    super.textCapitalization,
    super.style,
    super.textAlign,
    super.autofocus,
    super.obscureText,
    super.readOnly,
    super.maxLines,
    super.minLines,
    super.maxLength,
    super.onChanged,
    super.onEditingComplete,
    super.onSubmitted,
    super.inputFormatters,
    super.enabled,
    super.onTap,
  });

  @override
  List<TextInputFormatter>? get inputFormatters =>
      obscureText ? super.inputFormatters : [...?super.inputFormatters, const UpperCaseFormatter()];

  /// Campo de uma linha sem ação própria no Enter: o Enter vai para o próximo campo da janela (ou
  /// aciona a ação principal no último, ver [EnterForm]).
  bool get _advances =>
      super.onSubmitted == null && super.onEditingComplete == null && maxLines == 1 && !readOnly;

  @override
  ValueChanged<String>? get onSubmitted => super.onSubmitted ?? (_advances ? enterAdvance : null);

  @override
  VoidCallback? get onEditingComplete => _advances ? keepFocus : super.onEditingComplete;

  @override
  TextInputAction? get textInputAction => super.textInputAction ?? (_advances ? TextInputAction.next : null);
}
