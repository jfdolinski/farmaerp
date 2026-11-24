import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:flutter/services.dart';

import '../face/face_widgets.dart';
import '../ui/caps.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';
import 'pos_dialogs.dart';

/// Vendedor da venda ou do orçamento: pedido a cada novo atendimento (código, e o PIN se a filial
/// exigir). Identificado, mostra o nome e deixa trocar.
class SellerPanel extends StatefulWidget {
  const SellerPanel({super.key, required this.controller, required this.onIdentified, this.focusNode});

  final PosController controller;
  final VoidCallback onIdentified;

  /// Campo do código (a tela põe o cursor nele a cada venda ou orçamento novo).
  final FocusNode? focusNode;

  @override
  State<SellerPanel> createState() => _SellerPanelState();
}

class _SellerPanelState extends State<SellerPanel> {
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

  Future<void> _confirm() async {
    final ok = await widget.controller.identifySeller(_code.text, _pin.text);
    _pin.clear();
    if (ok) {
      _code.clear();
      widget.onIdentified();
    } else if (mounted) {
      final pinRequired = widget.controller.database.sellerPinRequired;
      final node = pinRequired && _code.text.trim().isNotEmpty ? _pinFocus : widget.focusNode;
      node?.requestFocus();
      if (node == widget.focusNode) selectAllText(_code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final seller = controller.seller;
    if (seller != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.badge_outlined),
            const SizedBox(width: 8),
            Expanded(child: Text('Vendedor: ${seller.name}', key: const Key('seller-name'))),
            if (controller.database.fixedSellerId == null)
              TextButton(key: const Key('seller-change'), onPressed: controller.changeSeller, child: const Text('Trocar')),
          ],
        ),
      );
    }
    final pinRequired = controller.database.sellerPinRequired;
    return Card(
      key: const Key('seller-panel'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              controller.quoteMode ? 'Novo orçamento: quem está atendendo?' : 'Nova venda: quem atendeu o cliente?',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('seller-code'),
                    controller: _code,
                    focusNode: widget.focusNode,
                    autofocus: widget.focusNode == null,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Código do vendedor'),
                    onSubmitted: (_) => pinRequired ? _pinFocus.requestFocus() : _confirm(),
                  ),
                ),
                if (pinRequired) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('seller-pin'),
                      controller: _pin,
                      focusNode: _pinFocus,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                      decoration: const InputDecoration(labelText: 'PIN'),
                      onSubmitted: (_) => _confirm(),
                    ),
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
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('seller-confirm'),
                  onPressed: controller.busy ? null : _confirm,
                  child: const Text('Confirmar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Painel lateral do terminal de orçamento: cliente, total, plaquinha e cupom.
class QuotePanel extends StatefulWidget {
  const QuotePanel({super.key, required this.controller, this.dialog});

  final PosController controller;
  final void Function(Future<void> Function() open)? dialog;

  @override
  State<QuotePanel> createState() => _QuotePanelState();
}

class _QuotePanelState extends State<QuotePanel> {
  final _card = TextEditingController();
  bool _print = true;

  @override
  void dispose() {
    _card.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final text = _card.text.trim();
    final ok = await widget.controller.finishQuote(
      cardNumber: text.isEmpty ? null : int.tryParse(text) ?? 0,
      printCoupon: _print,
    );
    if (ok) {
      _card.clear();
      setState(() => _print = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cart = controller.cart;
    final last = controller.lastQuote;
    final noCard = _card.text.trim().isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cart.customer == null)
              OutlinedButton.icon(
                key: const Key('identify-customer'),
                onPressed: controller.customers == null
                    ? null
                    : () => (widget.dialog ?? (open) => open())(() => showCustomerDialog(context, controller)),
                icon: const Icon(Icons.person_search),
                label: const Text('Identificar cliente (F4)'),
              )
            else
              ListTile(
                key: const Key('customer-name'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person),
                title: Text(cart.customer!.name),
                trailing: IconButton(tooltip: 'TIRAR O CLIENTE', icon: const Icon(Icons.close), onPressed: controller.clearCustomer),
              ),
            const SizedBox(height: 8),
            Text('${cart.lines.length} ${cart.lines.length == 1 ? 'item' : 'itens'}'),
            if (cart.discountCents > 0) Text('Descontos: ${formatCents(cart.discountCents)}'),
            Text('Total', style: Theme.of(context).textTheme.titleMedium),
            Text(
              formatCents(cart.totalCents),
              key: const Key('total'),
              style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            NumberField(
              key: const Key('quote-card'),
              controller: _card,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              decoration: const InputDecoration(labelText: 'Plaquinha (número do cartão, opcional)'),
              onChanged: (_) => setState(() {}),
            ),
            CheckboxListTile(
              key: const Key('quote-print'),
              contentPadding: EdgeInsets.zero,
              value: _print || noCard,
              onChanged: noCard ? null : (value) => setState(() => _print = value ?? true),
              title: Text(noCard ? 'Imprimir o cupom (sem plaquinha, o cupom sai sempre)' : 'Imprimir o cupom'),
            ),
            FilledButton.icon(
              key: const Key('quote-finish'),
              onPressed: cart.isEmpty || controller.busy ? null : _finish,
              icon: const Icon(Icons.assignment_turned_in),
              label: const Text('Concluir orçamento'),
            ),
            if (last != null) ...[
              const SizedBox(height: 16),
              const Divider(),
              Text('Último orçamento: ${last.code} · ${formatCents(last.totalCents)}'),
              TextButton.icon(
                key: const Key('reprint'),
                onPressed: controller.busy ? null : controller.reprint,
                icon: const Icon(Icons.print),
                label: const Text('Reimprimir o cupom'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Caixa: puxa o orçamento pela plaquinha ou pelo código do cupom, ou escolhe na lista dos pendentes
/// da loja (com internet). Mostra os itens de cada um antes de puxar.
Future<void> showQuoteLookup(BuildContext context, PosController controller) {
  controller.clearNotice();
  return showDialog<void>(context: context, builder: (_) => _QuoteLookupDialog(controller: controller));
}

class _QuoteLookupDialog extends StatefulWidget {
  const _QuoteLookupDialog({required this.controller});

  final PosController controller;

  @override
  State<_QuoteLookupDialog> createState() => _QuoteLookupDialogState();
}

class _QuoteLookupDialogState extends State<_QuoteLookupDialog> {
  final _key = TextEditingController();
  List<Map<String, dynamic>>? _pending;
  bool _loading = true;
  int _highlight = 0;

  /// Pendentes que combinam com o que foi digitado (plaquinha, código, vendedor ou cliente).
  List<Map<String, dynamic>> get _filtered {
    final words = _key.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final all = _pending ?? const [];
    if (words.isEmpty) return all;
    return [
      for (final quote in all)
        if (words.every((word) => [quote['card_number'], quote['code'], quote['seller_name'], quote['customer_name']]
            .whereType<Object>()
            .any((value) => '$value'.toLowerCase().contains(word))))
          quote,
    ];
  }

  /// Enter: plaquinha ou código digitado inteiro vai direto; senão, o marcado na lista.
  void _submit() {
    final text = _key.text.trim();
    final filtered = _filtered;
    if (RegExp(r'^\d{1,4}$').hasMatch(text) || RegExp(r'^[Oo]\d+-\d{6,}$').hasMatch(text) || filtered.isEmpty) {
      _load(text);
    } else {
      _load(filtered[_highlight.clamp(0, filtered.length - 1)]['code'] as String);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller.pendingQuotes().then((list) {
      if (mounted) {
        setState(() {
          _pending = list;
          _loading = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load(String key) async {
    if (key.trim().isEmpty) return;
    final navigator = Navigator.of(context);
    final ok = await widget.controller.loadQuote(key);
    if (ok) navigator.pop();
  }

  String _time(String? value) {
    final date = DateTime.tryParse(value ?? '')?.toLocal();
    if (date == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)} ${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final notice = controller.notice;
        final pending = _filtered;
        return AlertDialog(
          key: const Key('quote-lookup'),
          title: const Text('Puxar orçamento'),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notice != null)
                  Container(
                    key: const Key('quote-lookup-notice'),
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 8),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Text('${notice.message} ${notice.action}'),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: SuggestionKeys(
                        onMove: (step) {
                          if (pending.isEmpty) return;
                          setState(() => _highlight = (_highlight + step).clamp(0, pending.length - 1));
                        },
                        onClose: () => Navigator.of(context).pop(),
                        child: TextField(
                          key: const Key('quote-key'),
                          controller: _key,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'Plaquinha, código do cupom, vendedor ou cliente',
                            helperText: 'A lista filtra enquanto digita; Enter puxa o marcado.',
                          ),
                          onChanged: (_) => setState(() => _highlight = 0),
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('quote-load'),
                      onPressed: controller.busy ? null : _submit,
                      child: const Text('Puxar'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Pendentes da loja', style: Theme.of(context).textTheme.titleSmall),
                if (_loading) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
                if (!_loading && _pending != null && pending.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(_key.text.trim().isEmpty ? 'Nenhum orçamento aberto.' : 'Nenhum pendente combina com o que foi digitado.'),
                  ),
                if (!_loading && _pending == null)
                  const Padding(padding: EdgeInsets.all(8), child: Text('Sem a lista agora: busque pela plaquinha ou pelo cupom.')),
                if (pending.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final (index, quote) in pending.indexed)
                          ListTile(
                            key: Key('quote-${quote['code']}'),
                            selected: index == _highlight,
                            selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                            leading: Text(quote['card_number'] == null ? '—' : '${quote['card_number']}',
                                style: Theme.of(context).textTheme.titleLarge),
                            title: Text('${quote['code']} · ${formatCents(((quote['total'] as num) * 100).round())}'),
                            subtitle: Text([
                              'Vendedor: ${quote['seller_name']}',
                              if (quote['customer_name'] != null) 'Cliente: ${quote['customer_name']}',
                              '${quote['item_count']} ${quote['item_count'] == 1 ? 'item' : 'itens'}',
                              _time(quote['quoted_at'] as String?),
                            ].join(' · ')),
                            onTap: controller.busy ? null : () => _load(quote['code'] as String),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Fechar'))],
        );
      },
    );
  }
}
