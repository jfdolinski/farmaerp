import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../face/face_widgets.dart';
import '../ui/caps.dart';
import 'cash.dart';
import 'credit.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';

final _moneyInput = [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')), LengthLimitingTextInputFormatter(13)];

Widget _notice(BuildContext context, PosController controller) {
  final notice = controller.notice;
  if (notice == null) return const SizedBox.shrink();
  return Container(
    key: const Key('credit-notice'),
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    margin: const EdgeInsets.only(bottom: 8),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Text('${notice.message} ${notice.action}'),
  );
}

String _brDay(String day) => day.split('-').reversed.join('/');

/// Recebimento de parcelas do crediário, em qualquer loja: escolhe o cliente, vê o que está em aberto
/// (com multa e juros de hoje), informa o valor e a forma. Sai o comprovante.
Future<void> showCreditReceiptDialog(BuildContext context, PosController controller) {
  controller.clearNotice();
  return showDialog<void>(context: context, builder: (_) => _CreditReceiptDialog(controller: controller));
}

class _CreditReceiptDialog extends StatefulWidget {
  const _CreditReceiptDialog({required this.controller});

  final PosController controller;

  @override
  State<_CreditReceiptDialog> createState() => _CreditReceiptDialogState();
}

class _CreditReceiptDialogState extends State<_CreditReceiptDialog> {
  final _search = TextEditingController();
  final _amount = TextEditingController();
  final _brand = TextEditingController();
  final _authorization = TextEditingController();
  final _amountFocus = FocusNode();
  ({String id, String name, int code})? _customer;
  CreditSummary? _summary;
  String _method = 'cash';

  @override
  void dispose() {
    for (final field in [_search, _amount, _brand, _authorization]) {
      field.dispose();
    }
    _amountFocus.dispose();
    super.dispose();
  }

  void _choose(({String id, String name, int code}) customer) {
    final found = widget.controller.creditForReceipt(customer.id);
    setState(() {
      _customer = customer;
      _summary = found?.account.summary(widget.controller.creditToday);
      _amount.text = formatCents(_summary?.totalOpenCents ?? 0).replaceFirst('R\$ ', '');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _amountFocus.requestFocus();
      selectAllText(_amount);
    });
  }

  Future<void> _confirm() async {
    final customer = _customer;
    final cents = parseCents(_amount.text);
    if (customer == null || cents == null) return;
    final card = _method == 'credit_card' || _method == 'debit_card';
    final done = await widget.controller.receiveCredit(
      customerId: customer.id,
      amountCents: cents,
      method: _method,
      cardBrand: card ? _brand.text : null,
      authorizationCode: card ? _authorization.text : null,
    );
    if (done && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final summary = _summary;
    final customers = _customer == null ? controller.creditCustomers(_search.text) : const <({String id, String name, int code})>[];
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AlertDialog(
        key: const Key('credit-receipt-dialog'),
        title: const Text('Receber crediário'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _notice(context, controller),
                if (_customer == null) ...[
                  const Text('Busque o cliente pelo nome ou pelo código. Aparecem os clientes com crediário neste terminal.'),
                  TextField(
                    key: const Key('credit-search'),
                    controller: _search,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Cliente'),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (customers.isEmpty) const Text('Nenhum cliente com crediário encontrado.'),
                  for (final customer in customers)
                    ListTile(
                      key: Key('credit-customer-${customer.code}'),
                      dense: true,
                      title: Text(customer.name),
                      subtitle: Text('Código ${customer.code}'),
                      onTap: () => _choose(customer),
                    ),
                ] else ...[
                  Text('${_customer!.code} · ${_customer!.name}', style: Theme.of(context).textTheme.titleMedium),
                  if (summary == null || summary.positions.isEmpty)
                    const Text('Nada em aberto no crediário.')
                  else ...[
                    for (final item in summary.positions)
                      Text(
                        'Vence ${_brDay(item.state.dueDate)}: ${formatCents(item.position.principalCents)}'
                        '${item.position.feeCents + item.position.interestCents > 0 ? ' + multa e juros ${formatCents(item.position.feeCents + item.position.interestCents)}' : ''}',
                      ),
                    Text(
                      'Total em aberto hoje: ${formatCents(summary.totalOpenCents)}',
                      key: const Key('credit-total-open'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final entry in countedMethods.entries)
                        ChoiceChip(
                          key: Key('credit-method-${entry.key}'),
                          label: Text(entry.value),
                          selected: _method == entry.key,
                          onSelected: (_) => setState(() => _method = entry.key),
                        ),
                    ],
                  ),
                  NumberField(
                    key: const Key('credit-amount'),
                    controller: _amount,
                    focusNode: _amountFocus,
                    decimal: true,
                    inputFormatters: _moneyInput,
                    decoration: const InputDecoration(
                      labelText: 'Valor recebido (R\$)',
                      helperText: 'Abate primeiro multa e juros, depois a parcela mais antiga.',
                    ),
                    onSubmitted: (_) => _confirm(),
                  ),
                  if (_method == 'credit_card' || _method == 'debit_card') ...[
                    TextField(controller: _brand, decoration: const InputDecoration(labelText: 'Bandeira (opcional)')),
                    TextField(controller: _authorization, decoration: const InputDecoration(labelText: 'Autorização da maquininha (opcional)')),
                  ],
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
          if (_customer != null)
            TextButton(
              onPressed: () => setState(() {
                _customer = null;
                _summary = null;
              }),
              child: const Text('Outro cliente'),
            ),
          if (_customer != null && (summary?.totalOpenCents ?? 0) > 0)
            FilledButton(
              key: const Key('credit-confirm'),
              onPressed: controller.busy ? null : _confirm,
              child: const Text('Receber'),
            ),
        ],
      ),
    );
  }
}

/// Liberação da venda no crediário acima do limite do operador: outra pessoa com limite que cubra.
Future<({String supervisorId, String supervisorName, String reason})?> showCreditReleaseDialog(
  BuildContext context,
  PosController controller,
  int amountCents,
) {
  controller.clearNotice();
  return showDialog(context: context, builder: (_) => _CreditReleaseDialog(controller: controller, amountCents: amountCents));
}

class _CreditReleaseDialog extends StatefulWidget {
  const _CreditReleaseDialog({required this.controller, required this.amountCents});

  final PosController controller;
  final int amountCents;

  @override
  State<_CreditReleaseDialog> createState() => _CreditReleaseDialogState();
}

class _CreditReleaseDialogState extends State<_CreditReleaseDialog> {
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _reason = TextEditingController();
  final _pinFocus = FocusNode();

  @override
  void dispose() {
    for (final field in [_code, _pin, _reason]) {
      field.dispose();
    }
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final release = await widget.controller.releaseCredit(widget.amountCents, _code.text, _pin.text, _reason.text);
    if (release != null && mounted) Navigator.of(context).pop(release);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => AlertDialog(
      key: const Key('credit-release-dialog'),
      title: const Text('Liberar o crediário'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _notice(context, widget.controller),
            Text(
              '${formatCents(widget.amountCents)} no crediário passa do seu limite. Outra pessoa com limite maior libera com o código e o PIN.',
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('credit-release-code'),
                    controller: _code,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Código de quem libera'),
                    onSubmitted: (_) => _pinFocus.requestFocus(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('credit-release-pin'),
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
            TextField(
              key: const Key('credit-release-reason'),
              controller: _reason,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Motivo (opcional)'),
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
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(
          key: const Key('credit-release-confirm'),
          onPressed: widget.controller.busy ? null : _confirm,
          child: const Text('Liberar'),
        ),
      ],
    ),
  );
}
