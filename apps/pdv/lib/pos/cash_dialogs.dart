import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../face/face_widgets.dart';
import '../ui/caps.dart';
import '../ui/keys_hint.dart';
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
/// A sangria de devolução pede o documento da devolução: o valor vem dele e a devolução fica paga.
/// [returnCode] já abre a sangria de devolução com o documento (logo depois da devolução em dinheiro).
Future<void> showCashMovementDialog(BuildContext context, PosController controller, {required bool withdrawal, String? returnCode}) {
  controller.clearNotice();
  return showDialog<void>(
    context: context,
    builder: (_) => _CashMovementDialog(controller: controller, withdrawal: withdrawal, returnCode: returnCode),
  );
}

class _CashMovementDialog extends StatefulWidget {
  const _CashMovementDialog({required this.controller, required this.withdrawal, this.returnCode});

  final PosController controller;
  final bool withdrawal;
  final String? returnCode;

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
  final _document = TextEditingController();
  final _documentFocus = FocusNode();
  bool _needsRelease = false;

  /// Sangria de devolução: o documento achado (id, código, total).
  bool _forReturn = false;
  Map<String, dynamic>? _refund;

  @override
  void initState() {
    super.initState();
    final code = widget.returnCode;
    if (code != null) {
      _forReturn = true;
      _document.text = code;
      WidgetsBinding.instance.addPostFrameCallback((_) => _findDocument());
    }
  }

  @override
  void dispose() {
    for (final field in [_amount, _reason, _code, _pin, _document]) {
      field.dispose();
    }
    for (final node in [_amountFocus, _reasonFocus, _codeFocus, _pinFocus, _documentFocus]) {
      node.dispose();
    }
    super.dispose();
  }

  /// Acha o documento da devolução e preenche o valor e o motivo.
  Future<void> _findDocument() async {
    final found = await widget.controller.findReturnDocument(_document.text);
    if (!mounted) return;
    setState(() {
      _refund = found;
      if (found != null) {
        final cents = ((found['total'] as num) * 100).round();
        _amount.text = formatCents(cents).replaceFirst('R\$ ', '');
        _reason.text = 'Devolução ${found['code']} (venda ${found['sale_code']})';
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (found == null) {
        _documentFocus.requestFocus();
        selectAllText(_document);
      }
    });
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
    if (_forReturn && _refund == null) return _findDocument();
    final cents = parseCents(_amount.text) ?? 0;
    final returnId = _forReturn ? _refund!['id'] as String : null;
    bool? done;
    if (!widget.withdrawal) {
      done = await controller.supply(cents, _reason.text);
    } else if (_needsRelease) {
      done = await controller.releaseWithdrawal(cents, _reason.text, _code.text, _pin.text, returnId: returnId);
      _pin.clear();
    } else {
      done = await controller.withdraw(cents, _reason.text, returnId: returnId);
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
            // Folga entre os campos: o rótulo de cima não encosta no texto.
            spacing: 10,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogNotice(context, controller),
              Text(widget.withdrawal
                  ? 'Dinheiro que sai da gaveta (para o cofre ou o banco, ou para pagar uma devolução). Sai um comprovante para assinar.'
                  : 'Troco que entra na gaveta. Sai um comprovante para assinar.'),
              if (widget.withdrawal)
                SegmentedButton<bool>(
                  key: const Key('cash-kind'),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Sangria comum')),
                    ButtonSegment(value: true, label: Text('Devolução')),
                  ],
                  selected: {_forReturn},
                  onSelectionChanged: _needsRelease
                      ? null
                      : (value) {
                          setState(() {
                            _forReturn = value.first;
                            _refund = null;
                            _amount.clear();
                            _reason.clear();
                          });
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => (_forReturn ? _documentFocus : _amountFocus).requestFocus(),
                          );
                        },
                ),
              if (_forReturn)
                TextField(
                  key: const Key('cash-return-document'),
                  controller: _document,
                  focusNode: _documentFocus,
                  autofocus: true,
                  enabled: !_needsRelease,
                  decoration: InputDecoration(
                    labelText: 'Documento da devolução (por exemplo D3-000012)',
                    helperText: _refund == null ? 'Leia ou digite o código do comprovante da devolução.' : null,
                  ),
                  onChanged: (_) => setState(() => _refund = null),
                  onSubmitted: (_) => _findDocument(),
                ),
              NumberField(
                key: const Key('cash-amount'),
                controller: _amount,
                focusNode: _amountFocus,
                autofocus: !_forReturn,
                decimal: true,
                enabled: !_needsRelease && !_forReturn,
                onSubmitted: (_) => _reasonFocus.requestFocus(),
                inputFormatters: _moneyInput,
                decoration: const InputDecoration(labelText: 'Valor (R\$)'),
              ),
              TextField(
                key: const Key('cash-reason'),
                controller: _reason,
                focusNode: _reasonFocus,
                onSubmitted: (_) => _confirm(),
                enabled: !_needsRelease && !_forReturn,
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
                FaceApproveButton(
                  controller: widget.controller,
                  onApproved: (code) {
                    _code.text = code;
                    _pin.clear();
                    _confirm();
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          const KeysHint(),
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
  final _submitFocus = FocusNode();
  bool _confirming = false;

  @override
  void dispose() {
    for (final field in [..._fields.values, _note]) {
      field.dispose();
    }
    _submitFocus.dispose();
    super.dispose();
  }

  /// Na conferência os campos travam: o foco vai para "Fechar o caixa", e o Enter fecha.
  void _review() {
    setState(() => _confirming = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _submitFocus.requestFocus();
    });
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
                // Folga entre os campos: o rótulo de cima não encosta no texto.
                spacing: 10,
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
            const KeysHint(),
            TextButton(
              onPressed: () => _confirming ? setState(() => _confirming = false) : Navigator.of(context).pop(),
              child: Text(_confirming ? 'Corrigir' : 'Cancelar'),
            ),
            FilledButton(
              key: const Key('close-shift-submit'),
              focusNode: _submitFocus,
              onPressed: controller.busy || (!_confirming && missing)
                  ? null
                  : () => _confirming ? _close() : _review(),
              child: Text(_confirming ? 'Fechar o caixa' : 'Continuar'),
            ),
          ],
        );
      },
    );
  }
}
