import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../face/face_widgets.dart';
import '../ui/caps.dart';
import '../ui/pdv_window.dart';
import '../ui/keys_hint.dart';
import 'cash_dialogs.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';
import 'receipt.dart';

/// Devolução (F9): a venda pelo código do comprovante, as quantidades que voltam, o motivo e o
/// destino do valor. Em dinheiro, ao final abre a sangria com o documento da devolução.
Future<void> showReturnDialog(BuildContext context, PosController controller) async {
  controller.clearNotice();
  final result = await showDialog<({String id, String code, int totalCents, String destination})>(
    context: context,
    builder: (_) => _ReturnDialog(controller: controller),
  );
  if (result != null && result.destination == 'cash' && context.mounted) {
    await showCashMovementDialog(context, controller, withdrawal: true, returnCode: result.code);
  }
}

class _ReturnDialog extends StatefulWidget {
  const _ReturnDialog({required this.controller});

  final PosController controller;

  @override
  State<_ReturnDialog> createState() => _ReturnDialogState();
}

class _ReturnDialogState extends State<_ReturnDialog> {
  final _sale = TextEditingController();
  final _reason = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _saleFocus = FocusNode();
  final _reasonFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();
  final _quantities = <String, TextEditingController>{};
  final _quantityFocus = <String, FocusNode>{};
  Map<String, dynamic>? _found;
  String _destination = 'credit';
  bool _searching = false;

  @override
  void dispose() {
    for (final field in [_sale, _reason, _code, _pin, ..._quantities.values]) {
      field.dispose();
    }
    for (final node in [_saleFocus, _reasonFocus, _codeFocus, _pinFocus, ..._quantityFocus.values]) {
      node.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> get _items => ((_found?['items'] as List?) ?? const []).cast<Map<String, dynamic>>();

  static int _milli(num value) => (value * 1000).round();

  /// Quanto ainda pode voltar do item, em milésimos.
  int _remaining(Map<String, dynamic> item) => _milli(item['quantity'] as num) - _milli(item['returned_quantity'] as num);

  int? _typed(String id) {
    final text = _quantities[id]?.text.trim().replaceAll(',', '.') ?? '';
    if (text.isEmpty) return 0;
    final value = double.tryParse(text);
    return value == null ? null : (value * 1000).round();
  }

  void _focus(FocusNode node) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) node.requestFocus();
  });

  Future<void> _search() async {
    setState(() => _searching = true);
    final found = await widget.controller.findSaleForReturn(_sale.text);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _found = found;
      if (found != null) {
        for (final item in _items) {
          final id = item['id'] as String;
          _quantities.putIfAbsent(id, () => TextEditingController(text: '0'));
          _quantityFocus.putIfAbsent(id, FocusNode.new);
        }
        _destination = 'credit';
      }
    });
    if (found == null) {
      _focus(_saleFocus);
      return;
    }
    final first = _items.where((item) => item['controlled'] != true && _remaining(item) > 0).firstOrNull;
    _focus(first == null ? _reasonFocus : _quantityFocus[first['id']]!);
  }

  Future<void> _confirm() async {
    final sale = _found;
    if (sale == null) return _search();
    final quantities = <String, int>{};
    for (final item in _items) {
      final value = _typed(item['id'] as String);
      quantities[item['id'] as String] = value ?? -1;
    }
    final result = await widget.controller.makeReturn(
      sale: sale,
      quantities: quantities,
      reason: _reason.text,
      destination: _destination,
      code: _code.text,
      pin: _pin.text,
    );
    _pin.clear();
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop(result);
      return;
    }
    // Cursor no que falta: quantidade, motivo ou a liberação.
    final reference = widget.controller.notice?.reference ?? '';
    if (reference.contains('FA871') || reference.contains('FA892') || reference.contains('FA893')) {
      final first = _items.where((item) => item['controlled'] != true && _remaining(item) > 0).firstOrNull;
      if (first != null) _focus(_quantityFocus[first['id']]!);
    } else if (reference.contains('FA870')) {
      _focus(_reasonFocus);
    } else if (_code.text.trim().isEmpty) {
      _focus(_codeFocus);
    } else {
      _focus(_pinFocus);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sale = _found;
        final notice = controller.notice;
        final needsAuthorization = sale != null && controller.returnNeedsAuthorization(sale);
        var preview = 0;
        for (final item in _items) {
          final typed = _typed(item['id'] as String) ?? 0;
          final remaining = _remaining(item);
          if (typed <= 0 || typed > remaining || item['controlled'] == true) continue;
          final total = ((item['total'] as num) * 100).round();
          final sold = _milli(item['quantity'] as num);
          preview += typed == remaining ? total - ((item['returned_amount'] as num) * 100).round() : (total * typed / sold).round();
        }
        return PdvWindow(
          key: const Key('return-dialog'),
          title: 'Devolução',
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // Folga entre os campos: o rótulo de cima não encosta no texto.
              spacing: 10,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notice != null)
                  Container(
                    key: const Key('return-notice'),
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Text('${notice.message} ${notice.action}'),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('return-sale'),
                        controller: _sale,
                        focusNode: _saleFocus,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Código da venda (no comprovante, por exemplo 3-000123)',
                        ),
                        onSubmitted: (_) => _search(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const Key('return-search'),
                      onPressed: _searching ? null : _search,
                      child: const Text('Buscar'),
                    ),
                  ],
                ),
                if (sale != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Venda ${sale['code']} · ${formatCents(((sale['total'] as num) * 100).round())}'
                    '${sale['customer_name'] == null ? '' : ' · ${sale['customer_name']}'}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (sale['late'] == true)
                    Text(
                      'Fora do prazo de devolução da loja (${sale['return_days']} dias): precisa da liberação de outra pessoa.',
                      key: const Key('return-late'),
                    ),
                  for (final item in _items)
                    ListTile(
                      key: Key('return-item-${item['line']}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text('${item['line']} · ${item['product_code']} ${item['product_name']}'),
                      subtitle: Text(item['controlled'] == true
                          ? 'Controlado: a devolução é feita pelo farmacêutico, na manutenção do SNGPC.'
                          : 'Vendido ${formatMilli(_milli(item['quantity'] as num))} · já voltou '
                              '${formatMilli(_milli(item['returned_quantity'] as num))} · pode voltar ${formatMilli(_remaining(item))}'),
                      trailing: SizedBox(
                        width: 110,
                        child: NumberField(
                          key: Key('return-qty-${item['line']}'),
                          controller: _quantities[item['id']]!,
                          focusNode: _quantityFocus[item['id']],
                          decimal: true,
                          enabled: item['controlled'] != true && _remaining(item) > 0,
                          decoration: const InputDecoration(labelText: 'Volta'),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ),
                  Text('Total da devolução: ${formatCents(preview)}', key: const Key('return-total')),
                  TextField(
                    key: const Key('return-reason'),
                    controller: _reason,
                    focusNode: _reasonFocus,
                    maxLength: 500,
                    decoration: const InputDecoration(labelText: 'Motivo (por exemplo, produto com defeito)'),
                  ),
                  const Text('Para onde vai o valor?', style: TextStyle(fontWeight: FontWeight.bold)),
                  RadioGroup<String>(
                    groupValue: _destination,
                    onChanged: (value) => setState(() => _destination = value ?? _destination),
                    child: Column(
                      children: [
                        for (final entry in returnDestinationLabels.entries)
                          if ((entry.key != 'agreement' || sale['has_agreement'] == true) &&
                              (entry.key != 'store_credit' || sale['has_store_credit'] == true))
                            RadioListTile<String>(
                              key: Key('return-destination-${entry.key}'),
                              value: entry.key,
                              dense: true,
                              title: Text(entry.value),
                              subtitle: Text(switch (entry.key) {
                                'credit' => 'O cliente usa na próxima compra nesta loja.',
                                'agreement' => 'Abate na próxima fatura do convênio do cliente.',
                                'store_credit' => 'Abate o que o cliente deve no crediário.',
                                _ => 'Sai do caixa por uma sangria de devolução com o documento.',
                              }),
                            ),
                      ],
                    ),
                  ),
                  if (needsAuthorization) ...[
                    Text(
                      sale['late'] == true
                          ? 'Liberação de outra pessoa com a permissão "Fazer devolução":'
                          : 'Você não tem a permissão "Fazer devolução": chame quem tem para liberar.',
                      key: const Key('return-authorization'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('return-code'),
                            controller: _code,
                            focusNode: _codeFocus,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            decoration: const InputDecoration(labelText: 'Código de quem libera'),
                            onSubmitted: (_) => _pinFocus.requestFocus(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            key: const Key('return-pin'),
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
              ],
            ),
          ),
          actions: [
            const KeysHint(),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
            FilledButton(
              key: const Key('return-confirm'),
              onPressed: controller.busy || sale == null ? null : _confirm,
              child: const Text('Registrar a devolução'),
            ),
          ],
        );
      },
    );
  }
}
