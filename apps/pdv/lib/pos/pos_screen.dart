import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/error_display.dart';
import 'cart.dart';
import 'money.dart';
import 'pos_controller.dart';
import 'controlled_dialog.dart';
import 'pos_dialogs.dart';

/// Caixa: entrada, abertura do turno e venda. Tudo funciona sem internet.
class PosScreen extends StatelessWidget {
  const PosScreen({
    super.key,
    required this.controller,
    this.onPrinterSettings,
    this.online = true,
  });

  final PosController controller;
  final VoidCallback? onPrinterSettings;
  final bool online;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final operator = controller.operator;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              operator == null ? 'FarmaERP PDV' : 'Caixa · ${operator.name}',
            ),
            actions: [
              if (!online)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      'Sem internet: as vendas sobem quando voltar',
                      key: Key('pos-offline'),
                    ),
                  ),
                ),
              if (onPrinterSettings != null)
                IconButton(
                  key: const Key('printer-settings'),
                  tooltip: 'Impressora',
                  icon: const Icon(Icons.print),
                  onPressed: onPrinterSettings,
                ),
              if (operator != null)
                TextButton(
                  key: const Key('logout'),
                  onPressed: controller.logout,
                  child: const Text('Sair'),
                ),
            ],
          ),
          body: switch ((operator, controller.session)) {
            (null, _) => _LoginView(controller: controller),
            (_, null) => _OpenShiftView(controller: controller),
            _ => _SaleView(controller: controller),
          },
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.notice});

  final ErrorDisplay notice;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('pos-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            notice.message,
            style: TextStyle(
              color: colors.onErrorContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(notice.action, style: TextStyle(color: colors.onErrorContainer)),
          Text(notice.reference, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _LoginView extends StatefulWidget {
  const _LoginView({required this.controller});

  final PosController controller;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
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

  Future<void> _submit() async {
    await widget.controller.login(_code.text, _pin.text);
    _pin.clear();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Entrar no caixa',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (controller.notice != null)
                _Notice(notice: controller.notice!),
              TextField(
                key: const Key('login-code'),
                controller: _code,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Seu código'),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _pinFocus.requestFocus(),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('login-pin'),
                controller: _pin,
                focusNode: _pinFocus,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'PIN'),
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('login-submit'),
                onPressed: controller.busy ? null : _submit,
                child: Text(controller.busy ? 'Conferindo...' : 'Entrar'),
              ),
              const SizedBox(height: 12),
              const Text(
                'O PIN é definido pelo gerente na retaguarda, em Usuários.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpenShiftView extends StatefulWidget {
  const _OpenShiftView({required this.controller});

  final PosController controller;

  @override
  State<_OpenShiftView> createState() => _OpenShiftViewState();
}

class _OpenShiftViewState extends State<_OpenShiftView> {
  final _amount = TextEditingController(text: '0,00');
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _open() {
    final cents = parseCents(_amount.text);
    if (cents == null) {
      setState(
        () => _error = 'Digite o valor do fundo de troco, por exemplo 150,00.',
      );
      return;
    }
    widget.controller.openShift(cents);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Abrir o caixa',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Conte o dinheiro da gaveta e informe o fundo de troco.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('opening-float'),
                controller: _amount,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Fundo de troco (R\$)',
                  errorText: _error,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => _open(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('open-shift'),
                onPressed: _open,
                child: const Text('Abrir o caixa'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaleView extends StatefulWidget {
  const _SaleView({required this.controller});

  final PosController controller;

  @override
  State<_SaleView> createState() => _SaleViewState();
}

class _SaleViewState extends State<_SaleView> {
  final _scan = TextEditingController();
  final _scanFocus = FocusNode();

  @override
  void dispose() {
    _scan.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  void _submitScan() {
    widget.controller.scan(_scan.text);
    _scan.clear();
    _scanFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cart = controller.cart;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f10): controller.startPayment,
        const SingleActivator(LogicalKeyboardKey.escape): controller.paying
            ? controller.backToItems
            : controller.clearNotice,
        const SingleActivator(LogicalKeyboardKey.f2): _scanFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.f4): () =>
            showCustomerDialog(context, controller),
      },
      child: Focus(
        autofocus: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final items = _ItemsPanel(
                controller: controller,
                scan: _scan,
                scanFocus: _scanFocus,
                onScan: _submitScan,
              );
              final side = controller.paying
                  ? _PaymentPanel(controller: controller)
                  : _TotalsPanel(controller: controller, cart: cart);
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: items),
                    const SizedBox(width: 16),
                    SizedBox(width: 360, child: side),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: items),
                  const SizedBox(height: 12),
                  side,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ItemsPanel extends StatelessWidget {
  const _ItemsPanel({
    required this.controller,
    required this.scan,
    required this.scanFocus,
    required this.onScan,
  });

  final PosController controller;
  final TextEditingController scan;
  final FocusNode scanFocus;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final cart = controller.cart;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.notice != null) _Notice(notice: controller.notice!),
        if (controller.info != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              controller.info!,
              key: const Key('pos-info'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        if (controller.pendingControlled != null)
          ControlledPanel(controller: controller, pending: controller.pendingControlled!),
        if (controller.pendingZeroStock != null)
          ZeroStockPanel(
            controller: controller,
            pending: controller.pendingZeroStock!,
          ),
        TextField(
          key: const Key('scan-field'),
          controller: scan,
          focusNode: scanFocus,
          autofocus: true,
          enabled: !controller.paying,
          decoration: const InputDecoration(
            labelText: 'Código de barras, código do produto ou nome (F2)',
            prefixIcon: Icon(Icons.qr_code_scanner),
          ),
          onSubmitted: (_) => onScan(),
        ),
        if (controller.results.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: Card(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final product in controller.results)
                    ListTile(
                      key: Key('result-${product.code}'),
                      title: Text(product.name),
                      subtitle: Text(
                        [
                          if (product.activeIngredient != null)
                            product.activeIngredient!,
                          if (product.manufacturer != null)
                            product.manufacturer!,
                          'Estoque ${formatMilli(product.stockMilli < 0 ? 0 : product.stockMilli)}',
                          if (product.controlledClass != null) 'Controlado',
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            product.priceCents == null
                                ? 'Sem preço'
                                : formatCents(product.priceCents!),
                          ),
                          IconButton(
                            key: Key('network-result-${product.code}'),
                            tooltip: 'Estoque nas filiais',
                            icon: const Icon(Icons.store),
                            onPressed: () =>
                                showNetworkStock(context, controller, product),
                          ),
                        ],
                      ),
                      onTap: () {
                        controller.add(product);
                        scanFocus.requestFocus();
                      },
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: cart.isEmpty
              ? Center(
                  child: Text(
                    controller.lastSale == null
                        ? 'Passe o primeiro produto.'
                        : 'Pronto para a próxima venda.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                )
              : ListView.separated(
                  itemCount: cart.lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final line = cart.lines[index];
                    return ListTile(
                      key: Key('line-$index'),
                      leading: Text('${index + 1}'),
                      title: Text(line.product.name),
                      subtitle: Text(
                        [
                          '${formatMilli(line.quantityMilli)} × ${formatCents(line.unitPriceCents)}',
                          if (line.discountCents > 0)
                            'desconto ${formatCents(line.discountCents)}',
                          ...line.warnings,
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Menos um',
                            icon: const Icon(Icons.remove),
                            onPressed:
                                controller.paying || line.quantityMilli <= 1000
                                ? null
                                : () => controller.setQuantity(
                                    line,
                                    line.quantityMilli - 1000,
                                  ),
                          ),
                          IconButton(
                            key: Key('more-$index'),
                            tooltip: 'Mais um',
                            icon: const Icon(Icons.add),
                            onPressed: controller.paying
                                ? null
                                : () => controller.setQuantity(
                                    line,
                                    line.quantityMilli + 1000,
                                  ),
                          ),
                          IconButton(
                            key: Key('discount-$index'),
                            tooltip: 'Desconto',
                            icon: const Icon(Icons.percent),
                            onPressed: controller.paying
                                ? null
                                : () => showDiscountDialog(
                                    context,
                                    controller,
                                    line,
                                  ),
                          ),
                          IconButton(
                            key: Key('stock-$index'),
                            tooltip: 'Estoque nas filiais',
                            icon: const Icon(Icons.store),
                            onPressed: () => showNetworkStock(
                              context,
                              controller,
                              line.product,
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: Text(
                              formatCents(line.totalCents),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          IconButton(
                            key: Key('remove-$index'),
                            tooltip: 'Tirar da venda',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: controller.paying
                                ? null
                                : () => controller.remove(line),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TotalsPanel extends StatelessWidget {
  const _TotalsPanel({required this.controller, required this.cart});

  final PosController controller;
  final Cart cart;

  @override
  Widget build(BuildContext context) {
    final last = controller.lastSale;
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
                    : () => showCustomerDialog(context, controller),
                icon: const Icon(Icons.person_search),
                label: const Text('Identificar cliente (F4)'),
              )
            else
              ListTile(
                key: const Key('customer-name'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person),
                title: Text(cart.customer!.name),
                subtitle: Text(
                  [
                    'Código ${cart.customer!.code}',
                    ?cart.customer!.documentMasked,
                    if (cart.customer!.agreements.isNotEmpty)
                      'Convênio: ${cart.customer!.agreements.map((a) => a['name']).join(', ')}',
                  ].join(' · '),
                ),
                trailing: IconButton(
                  tooltip: 'Tirar o cliente',
                  icon: const Icon(Icons.close),
                  onPressed: controller.clearCustomer,
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '${cart.lines.length} ${cart.lines.length == 1 ? 'item' : 'itens'}',
            ),
            if (cart.discountCents > 0)
              Text('Descontos: ${formatCents(cart.discountCents)}'),
            const SizedBox(height: 8),
            Text('Total', style: Theme.of(context).textTheme.titleMedium),
            Text(
              formatCents(cart.totalCents),
              key: const Key('total'),
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('pay'),
              onPressed: cart.isEmpty ? null : controller.startPayment,
              icon: const Icon(Icons.payments),
              label: const Text('Pagamento (F10)'),
            ),
            if (last != null) ...[
              const SizedBox(height: 16),
              const Divider(),
              Text(
                'Última venda: ${last.code} · ${formatCents(last.totalCents)}',
              ),
              if (last.changeCents > 0)
                Text(
                  'Troco: ${formatCents(last.changeCents)}',
                  key: const Key('last-change'),
                ),
              TextButton.icon(
                key: const Key('reprint'),
                onPressed: controller.busy ? null : controller.reprint,
                icon: const Icon(Icons.print),
                label: const Text('Reimprimir'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaymentPanel extends StatefulWidget {
  const _PaymentPanel({required this.controller});

  final PosController controller;

  @override
  State<_PaymentPanel> createState() => _PaymentPanelState();
}

class _PaymentPanelState extends State<_PaymentPanel> {
  PaymentMethod _method = PaymentMethod.cash;
  Map<String, dynamic>? _agreement;
  final _amount = TextEditingController();
  final _brand = TextEditingController();
  final _authorization = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _fillRemaining();
  }

  void _fillRemaining() {
    final remaining = widget.controller.cart.remainingCents;
    _amount.text = formatCents(remaining).replaceFirst('R\$ ', '');
  }

  @override
  void dispose() {
    _amount.dispose();
    _brand.dispose();
    _authorization.dispose();
    super.dispose();
  }

  void _add() {
    final cents = parseCents(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = 'Digite o valor recebido, por exemplo 50,00.');
      return;
    }
    final card =
        _method == PaymentMethod.creditCard ||
        _method == PaymentMethod.debitCard;
    final agreement = _method == PaymentMethod.agreement ? _agreement : null;
    if (_method == PaymentMethod.agreement && agreement == null) {
      setState(() => _error = 'Escolha o convênio do cliente.');
      return;
    }
    widget.controller.addPayment(
      Payment(
        method: _method,
        amountCents: cents,
        cardBrand: card && _brand.text.trim().isNotEmpty
            ? _brand.text.trim()
            : null,
        authorizationCode: card && _authorization.text.trim().isNotEmpty
            ? _authorization.text.trim()
            : null,
        agreementId: agreement?['agreement_id'] as String?,
        agreementName: agreement?['name'] as String?,
        agreementRegistration: agreement?['registration'] as String?,
      ),
    );
    setState(() {
      _error = null;
      _brand.clear();
      _authorization.clear();
      _fillRemaining();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cart = controller.cart;
    final card =
        _method == PaymentMethod.creditCard ||
        _method == PaymentMethod.debitCard;
    final ready =
        cart.paidCents >= cart.totalCents && !cart.overpaidWithoutCash;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Pagamento', style: Theme.of(context).textTheme.titleLarge),
            Text(
              'Total ${formatCents(cart.totalCents)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final method in PaymentMethod.values)
                  if (method != PaymentMethod.agreement ||
                      (cart.customer?.agreements.isNotEmpty ?? false))
                    ChoiceChip(
                      key: Key('method-${method.code}'),
                      label: Text(method.label),
                      selected: _method == method,
                      onSelected: (_) => setState(() => _method = method),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('payment-amount'),
              controller: _amount,
              decoration: InputDecoration(
                labelText: _method == PaymentMethod.cash
                    ? 'Valor recebido (R\$)'
                    : 'Valor (R\$)',
                errorText: _error,
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onSubmitted: (_) => _add(),
            ),
            if (_method == PaymentMethod.agreement)
              DropdownButtonFormField<Map<String, dynamic>>(
                key: const Key('agreement'),
                initialValue: _agreement,
                decoration: const InputDecoration(labelText: 'Convênio'),
                items: [
                  for (final agreement
                      in cart.customer?.agreements ??
                          const <Map<String, dynamic>>[])
                    DropdownMenuItem(
                      value: agreement,
                      child: Text(
                        '${agreement['name']} · matrícula ${agreement['registration']}',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _agreement = value),
              ),
            if (card) ...[
              TextField(
                key: const Key('card-brand'),
                controller: _brand,
                decoration: const InputDecoration(
                  labelText: 'Bandeira (opcional)',
                ),
              ),
              TextField(
                key: const Key('authorization'),
                controller: _authorization,
                decoration: const InputDecoration(
                  labelText: 'Autorização da maquininha (opcional)',
                ),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('add-payment'),
              onPressed: _add,
              child: const Text('Lançar pagamento'),
            ),
            const SizedBox(height: 8),
            for (final payment in cart.payments)
              ListTile(
                dense: true,
                title: Text(payment.method.label),
                subtitle:
                    payment.cardBrand == null &&
                        payment.authorizationCode == null
                    ? null
                    : Text(
                        [
                          payment.cardBrand,
                          payment.authorizationCode,
                        ].whereType<String>().join(' · '),
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatCents(payment.amountCents)),
                    IconButton(
                      tooltip: 'Tirar',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        controller.removePayment(payment);
                        setState(_fillRemaining);
                      },
                    ),
                  ],
                ),
              ),
            const Divider(),
            Text(
              'Falta: ${formatCents(cart.remainingCents)}',
              key: const Key('remaining'),
            ),
            if (cart.changeCents > 0)
              Text(
                'Troco: ${formatCents(cart.changeCents)}',
                key: const Key('change'),
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            if (cart.overpaidWithoutCash)
              const Text(
                'Pagamento em cartão ou PIX acima do total. Tire e lance de novo.',
                key: Key('overpaid'),
              ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('finish'),
              onPressed: ready && !controller.busy ? controller.finish : null,
              child: Text(controller.busy ? 'Gravando...' : 'Finalizar venda'),
            ),
            TextButton(
              onPressed: controller.backToItems,
              child: const Text('Voltar aos itens (Esc)'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Escolha da impressora do comprovante: térmica (ESC/POS) pela fila do Windows ou PDF.
Future<String?> choosePrinter(
  BuildContext context, {
  required List<String> printers,
  required String? current,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Impressora do comprovante'),
      children: [
        SimpleDialogOption(
          key: const Key('printer-pdf'),
          onPressed: () => Navigator.pop(context, 'pdf'),
          child: Text(
            'Salvar em PDF${current == null || current == 'pdf' ? ' (em uso)' : ''}',
          ),
        ),
        for (final name in printers)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'escpos:$name'),
            child: Text(
              '$name (térmica ESC/POS)${current == 'escpos:$name' ? ' (em uso)' : ''}',
            ),
          ),
        if (printers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text('Nenhuma impressora instalada no Windows.'),
          ),
      ],
    ),
  );
}
