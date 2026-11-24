import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cash.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';

final _moneyInput = [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')), LengthLimitingTextInputFormatter(13)];

Widget _dialogNotice(BuildContext context, PosController controller) {
  final notice = controller.notice;
  if (notice == null) return const SizedBox.shrink();
  return Container(
    key: const Key('cash-notice'),
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    margin: const EdgeInsets.only(bottom: 8),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Text('${notice.message} ${notice.action}'),
  );
}

/// Sangria (withdrawal) ou suprimento. Na sangria acima do limite, pede quem libere na mesma janela.
Future<void> showCashMovementDialog(BuildContext context, PosController controller, {required bool withdrawal}) {
  controller.clearNotice();
  return showDialog<void>(context: context, builder: (_) => _CashMovementDialog(controller: controller, withdrawal: withdrawal));
}

class _CashMovementDialog extends StatefulWidget {
  const _CashMovementDialog({required this.controller, required this.withdrawal});

  final PosController controller;
  final bool withdrawal;

  @override
  State<_CashMovementDialog> createState() => _CashMovementDialogState();
}

class _CashMovementDialogState extends State<_CashMovementDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _amountFocus = FocusNode();
  final _reasonFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();
  bool _needsRelease = false;

  @override
  void dispose() {
    for (final field in [_amount, _reason, _code, _pin]) {
      field.dispose();
    }
    for (final node in [_amountFocus, _reasonFocus, _codeFocus, _pinFocus]) {
      node.dispose();
    }
    super.dispose();
  }

  /// Depois de um erro: o valor, o motivo, o código ou o PIN, o que estiver faltando.
  void _focusProblem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final FocusNode node;
      if (_needsRelease) {
        node = _code.text.trim().isEmpty ? _codeFocus : _pinFocus;
      } else if ((parseCents(_amount.text) ?? 0) <= 0 || widget.controller.notice?.reference.contains('FA993') == true) {
        node = _amountFocus;
      } else {
        node = _reasonFocus;
      }
      node.requestFocus();
    });
  }

  Future<void> _confirm() async {
    final controller = widget.controller;
    final cents = parseCents(_amount.text) ?? 0;
    bool? done;
    if (!widget.withdrawal) {
      done = await controller.supply(cents, _reason.text);
    } else if (_needsRelease) {
      done = await controller.releaseWithdrawal(cents, _reason.text, _code.text, _pin.text);
      _pin.clear();
    } else {
      done = await controller.withdraw(cents, _reason.text);
      if (done == false) setState(() => _needsRelease = true);
    }
    if (done == true && mounted) {
      Navigator.of(context).pop();
    } else if (mounted) {
      _focusProblem();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final title = widget.withdrawal ? 'Sangria' : 'Suprimento';
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AlertDialog(
        key: const Key('cash-movement-dialog'),
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogNotice(context, controller),
              Text(widget.withdrawal
                  ? 'Dinheiro que sai da gaveta (para o cofre ou o banco). Sai um comprovante para assinar.'
                  : 'Troco que entra na gaveta. Sai um comprovante para assinar.'),
              NumberField(
                key: const Key('cash-amount'),
                controller: _amount,
                focusNode: _amountFocus,
                autofocus: true,
                decimal: true,
                enabled: !_needsRelease,
                onSubmitted: (_) => _reasonFocus.requestFocus(),
                inputFormatters: _moneyInput,
                decoration: const InputDecoration(labelText: 'Valor (R\$)'),
              ),
              TextField(
                key: const Key('cash-reason'),
                controller: _reason,
                focusNode: _reasonFocus,
                onSubmitted: (_) => _confirm(),
                enabled: !_needsRelease,
                maxLength: 500,
                decoration: InputDecoration(labelText: widget.withdrawal ? 'Motivo (por exemplo, envelope do cofre)' : 'Motivo'),
              ),
              if (_needsRelease) ...[
                Text(
                  'Esta sangria passa do seu limite. Um supervisor libera com o código e o PIN; acima do limite dele, o gerente.',
                  key: const Key('cash-release-hint'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('cash-release-code'),
                        controller: _code,
                        focusNode: _codeFocus,
                        autofocus: true,
                        onSubmitted: (_) => _pinFocus.requestFocus(),
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(labelText: 'Código de quem libera'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const Key('cash-release-pin'),
                        controller: _pin,
                        focusNode: _pinFocus,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        decoration: const InputDecoration(labelText: 'PIN'),
                        onSubmitted: (_) => _confirm(),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          FilledButton(
            key: const Key('cash-confirm'),
            onPressed: controller.busy ? null : _confirm,
            child: Text(_needsRelease ? 'Liberar e registrar' : 'Registrar'),
          ),
        ],
      ),
    );
  }
}

/// Fechamento com conferência cega: o operador digita o que contou, sem ver o esperado.
Future<void> showCloseShiftDialog(BuildContext context, PosController controller) {
  controller.clearNotice();
  return showDialog<void>(context: context, builder: (_) => _CloseShiftDialog(controller: controller));
}

class _CloseShiftDialog extends StatefulWidget {
  const _CloseShiftDialog({required this.controller});

  final PosController controller;

  @override
  State<_CloseShiftDialog> createState() => _CloseShiftDialogState();
}

class _CloseShiftDialogState extends State<_CloseShiftDialog> {
  final _fields = {for (final method in countedMethods.keys) method: TextEditingController()};
  final _note = TextEditingController();
  bool _confirming = false;

  @override
  void dispose() {
    for (final field in [..._fields.values, _note]) {
      field.dispose();
    }
    super.dispose();
  }

  Map<String, int?> get _counted => {for (final entry in _fields.entries) entry.key: parseCents(entry.value.text)};

  Future<void> _close() async {
    final navigator = Navigator.of(context);
    final ok = await widget.controller.closeShift(_counted, note: _note.text);
    if (ok) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final counted = _counted;
        final missing = counted.values.any((value) => value == null);
        return AlertDialog(
          key: const Key('close-shift-dialog'),
          title: const Text('Fechar o caixa'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _dialogNotice(context, controller),
                  const Text(
                    'Conte o dinheiro da gaveta (com o fundo de troco) e some os comprovantes de cartão e PIX. '
                    'Informe o que contou: a conferência com o sistema é feita pela gerência. Sem movimento, informe 0.',
                  ),
                  for (final entry in countedMethods.entries)
                    NumberField(
                      key: Key('count-${entry.key}'),
                      controller: _fields[entry.key]!,
                      autofocus: entry.key == countedMethods.keys.first,
                      decimal: true,
                      enabled: !_confirming,
                      inputFormatters: _moneyInput,
                      decoration: InputDecoration(labelText: '${entry.value} (R\$)'),
                      onChanged: (_) => setState(() {}),
                    ),
                  TextField(
                    key: const Key('count-note'),
                    controller: _note,
                    enabled: !_confirming,
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: 'Observação (opcional)'),
                  ),
                  if (_confirming)
                    Text(
                      'Confira antes de fechar: ${countedMethods.entries.map((e) => '${e.value} ${formatCents(counted[e.key] ?? 0)}').join(' · ')}. '
                      'Depois de fechado, o turno não reabre.',
                      key: const Key('close-shift-confirm-text'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _confirming ? setState(() => _confirming = false) : Navigator.of(context).pop(),
              child: Text(_confirming ? 'Corrigir' : 'Cancelar'),
            ),
            FilledButton(
              key: const Key('close-shift-submit'),
              onPressed: controller.busy || (!_confirming && missing)
                  ? null
                  : () => _confirming ? _close() : setState(() => _confirming = true),
              child: Text(_confirming ? 'Fechar o caixa' : 'Continuar'),
            ),
          ],
        );
      },
    );
  }
}
