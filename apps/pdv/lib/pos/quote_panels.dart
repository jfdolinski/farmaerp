import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'money.dart';
import 'pos_controller.dart';
import 'pos_dialogs.dart';

/// Vendedor da venda ou do orçamento: pedido a cada novo atendimento (código, e o PIN se a filial
/// exigir). Identificado, mostra o nome e deixa trocar.
class SellerPanel extends StatefulWidget {
  const SellerPanel({super.key, required this.controller, required this.onIdentified});

  final PosController controller;
  final VoidCallback onIdentified;

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
                    autofocus: true,
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
  const QuotePanel({super.key, required this.controller});

  final PosController controller;

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
                onPressed: controller.customers == null ? null : () => showCustomerDialog(context, controller),
                icon: const Icon(Icons.person_search),
                label: const Text('Identificar cliente (F4)'),
              )
            else
              ListTile(
                key: const Key('customer-name'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person),
                title: Text(cart.customer!.name),
                trailing: IconButton(tooltip: 'Tirar o cliente', icon: const Icon(Icons.close), onPressed: controller.clearCustomer),
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
            TextField(
              key: const Key('quote-card'),
              controller: _card,
              keyboardType: TextInputType.number,
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
