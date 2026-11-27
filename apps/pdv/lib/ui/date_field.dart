import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import 'caps.dart';

/// Data digitada no formato dd/mm/aaaa, conferindo se o dia existe. Vazio ou incompleto: nula.
DateTime? parseBrDate(String text) {
  final match = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(text.trim());
  if (match == null) return null;
  final day = int.parse(match[1]!), month = int.parse(match[2]!), year = int.parse(match[3]!);
  if (month < 1 || month > 12 || day < 1 || year < 1900) return null;
  final date = DateTime(year, month, day);
  return date.day == day && date.month == month && date.year == year ? date : null;
}

/// dd/mm/aaaa de uma data.
String brDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year.toString().padLeft(4, '0')}';

/// Põe as barras sozinho: "12052026" vira "12/05/2026". Só aceita números (colar com barras também
/// funciona) e no máximo oito.
class DateMaskFormatter extends TextInputFormatter {
  const DateMaskFormatter();

  static String mask(String text) {
    final digits = text.replaceAll(RegExp(r'\D'), '');
    final kept = digits.length > 8 ? digits.substring(0, 8) : digits;
    final out = StringBuffer();
    for (var i = 0; i < kept.length; i += 1) {
      if (i == 2 || i == 4) out.write('/');
      out.write(kept[i]);
    }
    return out.toString();
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final masked = mask(newValue.text);
    return TextEditingValue(text: masked, selection: TextSelection.collapsed(offset: masked.length));
  }
}

/// Campo de data do PDV: digita só os números (as barras entram sozinhas) ou escolhe no calendário,
/// pelo botão ou com Alt+↓. Ao sair do campo, data incompleta ou que não existe já avisa.
class DateField extends StatefulWidget {
  const DateField({
    super.key,
    required this.controller,
    required this.label,
    this.focusNode,
    this.errorText,
    this.onChanged,
    this.firstDate,
    this.lastDate,
  });

  final TextEditingController controller;
  final String label;
  final FocusNode? focusNode;

  /// Erro da tela (regra do negócio). Tem prioridade sobre o aviso de data inválida.
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final DateTime? firstDate;
  final DateTime? lastDate;

  @override
  State<DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<DateField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant DateField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.focusNode ?? _own;
    if (old != _focus) {
      old?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  /// Confere ao sair do campo. O aviso fica até a data ficar certa (mesmo voltando ao campo).
  void _onFocus() {
    if (_focus.hasFocus) return;
    final text = widget.controller.text.trim();
    final invalid = text.isNotEmpty && parseBrDate(text) == null;
    if (invalid != _invalid) setState(() => _invalid = invalid);
  }

  Future<void> _pick() async {
    final today = DateTime.now();
    final first = widget.firstDate ?? DateTime(1900);
    final last = widget.lastDate ?? DateTime(today.year + 20, 12, 31);
    var initial = parseBrDate(widget.controller.text) ?? today;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: caps('Escolha a data'),
      cancelText: caps('Voltar'),
      confirmText: caps('Usar esta data'),
    );
    if (!mounted) return;
    if (picked != null) {
      widget.controller.text = brDate(picked);
      setState(() => _invalid = false);
      widget.onChanged?.call(widget.controller.text);
    }
    // Ao fechar, o calendário devolve o foco ao campo.
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): _pick},
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        keyboardType: TextInputType.datetime,
        inputFormatters: const [DateMaskFormatter()],
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: 'dd/mm/aaaa',
          errorText: widget.errorText ?? (_invalid ? 'Data inválida' : null),
          suffixIcon: IconButton(
            key: widget.key is ValueKey<String> ? Key('${(widget.key! as ValueKey<String>).value}-calendar') : null,
            tooltip: caps('Abrir calendário (Alt+↓)'),
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: _pick,
          ),
        ),
        onChanged: (value) {
          if (_invalid && parseBrDate(value) != null) setState(() => _invalid = false);
          widget.onChanged?.call(value);
        },
      ),
    );
  }
}
