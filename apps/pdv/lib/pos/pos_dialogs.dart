import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/error_display.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';
import 'cart.dart';
import 'discount.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';

/// Desconto no item, em R$ ou em %. Acima do limite, pede o supervisor na mesma janela.
Future<void> showDiscountDialog(BuildContext context, PosController controller, CartLine line) {
  return showDialog<void>(context: context, builder: (_) => _DiscountDialog(controller: controller, line: line));
}

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({required this.controller, required this.line});

  final PosController controller;
  final CartLine line;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _value = TextEditingController();
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _reason = TextEditingController();
  final _valueFocus = FocusNode();
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();
  bool _percent = true;

  void _focus(FocusNode node) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) node.requestFocus();
  });
  bool _needsRelease = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _code.dispose();
    _pin.dispose();
    _reason.dispose();
    _valueFocus.dispose();
    _codeFocus.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  int? get _cents {
    final gross = widget.line.grossCents;
    if (_percent) {
      final bp = parseCents(_value.text); // "8,5" → 850 centésimos de ponto
      return bp == null ? null : (gross * bp / 10000).round();
    }
    return parseCents(_value.text);
  }

  Future<void> _apply() async {
    final cents = _cents;
    if (cents == null) {
      setState(() => _error = _percent ? 'Digite o percentual, por exemplo 5 ou 7,5.' : 'Digite o valor, por exemplo 1,50.');
      _focus(_valueFocus);
      return;
    }
    if (!_needsRelease) {
      final need = widget.controller.applyDiscount(widget.line, cents);
      if (widget.controller.notice != null) {
        setState(() => _error = widget.controller.notice!.message);
        _focus(_valueFocus);
        return;
      }
      if (need == DiscountNeed.release) {
        setState(() {
          _needsRelease = true;
          _error = null;
        });
        _focus(_codeFocus);
        return;
      }
      if (mounted) Navigator.pop(context);
      return;
    }
    final ok = await widget.controller.releaseDiscount(widget.line, cents, _code.text, _pin.text, _reason.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _error = widget.controller.notice?.message;
        _pin.clear();
      });
      _focus(_code.text.trim().isEmpty ? _codeFocus : _pinFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final notice = _needsRelease ? ErrorDisplay.fromCode('FA978') : null;
    return AlertDialog(
      title: Text('Desconto · ${line.product.name}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Valor do item: ${formatCents(line.grossCents)}'),
            if (line.product.maxDiscountBp != null)
              Text('Máximo do produto: ${formatCents(line.product.maxDiscountBp!).replaceFirst('R\$ ', '')}%'),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('%')), ButtonSegment(value: false, label: Text('R\$'))],
              selected: {_percent},
              onSelectionChanged: _needsRelease ? null : (value) => setState(() => _percent = value.first),
            ),
            NumberField(
              key: const Key('discount-value'),
              controller: _value,
              focusNode: _valueFocus,
              autofocus: true,
              decimal: true,
              enabled: !_needsRelease,
              decoration: InputDecoration(labelText: _percent ? 'Desconto (%)' : 'Desconto (R\$)'),
              onSubmitted: (_) => _apply(),
            ),
            if (notice != null) ...[
              const SizedBox(height: 12),
              Text(notice.message, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(notice.action),
              TextField(
                key: const Key('supervisor-code'),
                controller: _code,
                focusNode: _codeFocus,
                onSubmitted: (_) => _pinFocus.requestFocus(),
                decoration: const InputDecoration(labelText: 'Código do supervisor'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              TextField(
                key: const Key('supervisor-pin'),
                controller: _pin,
                focusNode: _pinFocus,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'PIN do supervisor'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              ),
              TextField(key: const Key('release-reason'), controller: _reason, decoration: const InputDecoration(labelText: 'Motivo')),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const Key('discount-error'))),
          ],
        ),
      ),
      actions: [
        if (line.discountCents > 0)
          TextButton(
            onPressed: () {
              widget.controller.applyDiscount(line, 0);
              Navigator.pop(context);
            },
            child: const Text('Tirar o desconto'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          key: const Key('discount-apply'),
          onPressed: widget.controller.busy ? null : _apply,
          child: Text(_needsRelease ? 'Liberar' : 'Aplicar'),
        ),
      ],
    );
  }
}

/// Venda sem estoque com o PDV sem internet há bastante tempo: o gerente autoriza aqui.
class ZeroStockPanel extends StatefulWidget {
  const ZeroStockPanel({super.key, required this.controller, required this.pending, this.focusNode});

  final PosController controller;
  final PendingZeroStock pending;
  final FocusNode? focusNode;

  @override
  State<ZeroStockPanel> createState() => _ZeroStockPanelState();
}

class _ZeroStockPanelState extends State<ZeroStockPanel> {
  final _code = TextEditingController();
  final _pin = TextEditingController();
  final _pinFocus = FocusNode();

  @override
  void dispose() {
    _code.dispose();
    _pin.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    await widget.controller.approveZeroStock(_code.text, _pin.text);
    _pin.clear();
    if (mounted && widget.controller.pendingZeroStock != null) {
      (_code.text.trim().isEmpty ? widget.focusNode : _pinFocus)?.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    final hours = pending.minutesOffline ~/ 60;
    final minutes = pending.minutesOffline % 60;
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const Key('zero-stock-panel'),
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${pending.product.name} está sem estoque na cópia deste terminal.', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'O PDV está sem sincronizar há ${hours > 0 ? '$hours h ' : ''}$minutes min. A venda só passa com a autorização '
              'do gerente e fica registrada para conferência.',
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('zero-stock-code'),
                    controller: _code,
                    focusNode: widget.focusNode,
                    onSubmitted: (_) => _pinFocus.requestFocus(),
                    decoration: const InputDecoration(labelText: 'Código do gerente'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('zero-stock-pin'),
                    controller: _pin,
                    focusNode: _pinFocus,
                    onSubmitted: (_) => _approve(),
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'PIN'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: widget.controller.cancelZeroStock, child: const Text('Não vender')),
                FilledButton(
                  key: const Key('zero-stock-approve'),
                  onPressed: widget.controller.busy ? null : _approve,
                  child: const Text('Autorizar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Estoque do produto nas filiais (com internet).
Future<void> showNetworkStock(BuildContext context, PosController controller, SaleProduct product) async {
  final rows = await controller.stockElsewhere(product);
  if (rows == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Estoque nas filiais · ${product.name}'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final row in rows)
              ListTile(
                key: Key('network-${row['branch_id']}'),
                title: Text('${row['branch_name']}${row['own'] == true ? ' (esta filial)' : ''}'),
                subtitle: Text([row['city'], row['phone']].whereType<String>().join(' · ')),
                trailing: Text(formatMilli(((row['quantity'] as num) * 1000).round().clamp(0, 1 << 40))),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))],
    ),
  );
}

/// Identificação do cliente: busca com internet (ou entre os guardados) e escolha.
Future<void> showCustomerDialog(BuildContext context, PosController controller) {
  return showDialog<void>(context: context, builder: (_) => _CustomerDialog(controller: controller));
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({required this.controller});

  final PosController controller;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  final _query = TextEditingController();
  List<CustomerSummary> _results = const [];
  bool? _online;
  String? _error;
  bool _searching = false;
  int _highlight = -1;
  int _sequence = 0;
  Timer? _typing;

  @override
  void dispose() {
    _typing?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Sugestões enquanto digita: a partir de 3 letras, com uma pausa curta entre as teclas.
  void _onTyping(String text) {
    _typing?.cancel();
    if (text.trim().length < 3) return;
    _typing = Timer(const Duration(milliseconds: 350), () {
      if (mounted && _query.text == text) _search();
    });
  }

  Future<void> _search() async {
    final service = widget.controller.customers;
    if (service == null) return;
    final sequence = ++_sequence;
    final text = _query.text;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final result = await service.search(text);
      // Resposta velha (o operador continuou digitando): ignora.
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _results = result.customers;
        _online = result.online;
        _highlight = result.customers.isEmpty ? -1 : 0;
        if (result.customers.isEmpty) _error = 'Nenhum cliente encontrado.';
      });
    } on ApiException catch (error) {
      if (mounted && sequence == _sequence) setState(() => _error = ErrorDisplay.fromCode(error.code).message);
    } finally {
      if (mounted && sequence == _sequence) setState(() => _searching = false);
    }
  }

  Future<void> _choose(CustomerSummary customer) async {
    await widget.controller.selectCustomer(customer.id);
    if (mounted) Navigator.pop(context);
  }

  /// Enter: escolhe a sugestão marcada; sem sugestão, busca.
  void _submit() {
    _typing?.cancel();
    if (_highlight >= 0 && _highlight < _results.length) {
      _choose(_results[_highlight]);
    } else {
      _search();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Identificar o cliente'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SuggestionKeys(
              onMove: (step) {
                if (_results.isEmpty) return;
                setState(() => _highlight = (_highlight + step).clamp(0, _results.length - 1));
              },
              onClose: () => Navigator.pop(context),
              child: TextField(
                key: const Key('customer-query'),
                controller: _query,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nome, código ou CPF/CNPJ', helperText: 'As sugestões aparecem a partir de 3 letras.'),
                onChanged: (text) {
                  _onTyping(text);
                  setState(() {});
                },
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (_online == false)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Sem internet: a lista mostra só os clientes já usados neste terminal.', key: Key('customer-offline')),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
            if (_searching) const LinearProgressIndicator(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (index, customer) in _results.indexed)
                    ListTile(
                      key: Key('customer-${customer.code}'),
                      selected: index == _highlight,
                      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                      title: Text(customer.name),
                      subtitle: Text([
                        'Código ${customer.code}',
                        ?customer.documentMasked,
                        if (customer.city != null) '${customer.city}/${customer.state ?? ''}',
                      ].join(' · ')),
                      onTap: () => _choose(customer),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
        FilledButton(key: const Key('customer-search'), onPressed: _searching ? null : _search, child: const Text('Buscar')),
      ],
    );
  }
}
