import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/error_display.dart';
import 'cart.dart';
import 'cash_dialogs.dart';
import 'focus_kit.dart';
import 'money.dart';
import 'pos_controller.dart';
import 'controlled_dialog.dart';
import 'pos_dialogs.dart';
import 'product_info.dart';
import 'quote_panels.dart';
import 'return_dialog.dart';
import 'status_bar.dart';

/// Caixa: entrada, abertura do turno e venda. Tudo funciona sem internet.
class PosScreen extends StatelessWidget {
  const PosScreen({
    super.key,
    required this.controller,
    this.onPrinterSettings,
    this.onDisplaySettings,
    this.online = true,
    this.appVersion,
  });

  final PosController controller;
  final VoidCallback? onPrinterSettings;
  final VoidCallback? onDisplaySettings;
  final bool online;
  final String? appVersion;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final operator = controller.operator;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              controller.quoteMode
                  ? 'Orçamento'
                  : operator == null
                  ? 'FarmaERP PDV'
                  : 'Caixa · ${operator.name}',
            ),
            actions: [
              if (onDisplaySettings != null)
                IconButton(
                  key: const Key('display-settings-open'),
                  tooltip: 'Fonte do PDV',
                  icon: const Icon(Icons.text_fields),
                  onPressed: onDisplaySettings,
                ),
              if (onPrinterSettings != null)
                IconButton(
                  key: const Key('printer-settings'),
                  tooltip: 'Impressora',
                  icon: const Icon(Icons.print),
                  onPressed: onPrinterSettings,
                ),
              if (operator != null && controller.session != null) ...[
                TextButton(
                  key: const Key('cash-withdrawal'),
                  onPressed: () => showCashMovementDialog(context, controller, withdrawal: true),
                  child: const Text('Sangria (F6)'),
                ),
                TextButton(
                  key: const Key('cash-supply'),
                  onPressed: () => showCashMovementDialog(context, controller, withdrawal: false),
                  child: const Text('Suprimento (F7)'),
                ),
                TextButton(
                  key: const Key('return-open'),
                  onPressed: () => showReturnDialog(context, controller),
                  child: const Text('Devolução (F9)'),
                ),
                TextButton(
                  key: const Key('close-shift'),
                  onPressed: () => showCloseShiftDialog(context, controller),
                  child: const Text('Fechar caixa (F8)'),
                ),
              ],
              if (operator != null)
                TextButton(
                  key: const Key('logout'),
                  onPressed: controller.logout,
                  child: const Text('Sair'),
                ),
            ],
          ),
          body: controller.quoteMode
              ? _SaleView(controller: controller)
              : switch ((operator, controller.session)) {
            (null, _) => _LoginView(controller: controller),
            (_, null) => _OpenShiftView(controller: controller),
            _ => _SaleView(controller: controller),
          },
          bottomNavigationBar: PosStatusBar(controller: controller, online: online, appVersion: appVersion),
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
  final _codeFocus = FocusNode();
  final _pinFocus = FocusNode();

  @override
  void dispose() {
    _code.dispose();
    _pin.dispose();
    _codeFocus.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await widget.controller.login(_code.text, _pin.text);
    _pin.clear();
    // Não entrou: volta para o PIN (ou para o código, se ele estiver vazio).
    if (mounted && widget.controller.operator == null) {
      (_code.text.trim().isEmpty ? _codeFocus : _pinFocus).requestFocus();
    }
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
              if (controller.info != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(controller.info!, key: const Key('login-info'), textAlign: TextAlign.center),
                ),
              TextField(
                key: const Key('login-code'),
                controller: _code,
                focusNode: _codeFocus,
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
              NumberField(
                key: const Key('opening-float'),
                controller: _amount,
                autofocus: true,
                decimal: true,
                decoration: InputDecoration(
                  labelText: 'Fundo de troco (R\$)',
                  errorText: _error,
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
  final _sellerFocus = FocusNode();
  final _paymentFocus = FocusNode();
  final _zeroStockFocus = FocusNode();
  final _controlledFocus = FocusNode();
  final _shell = FocusNode(skipTraversal: true);
  Timer? _typing;
  int _highlight = -1;
  String? _target;

  PosController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChange);
    FocusManager.instance.addListener(_onFocusChange);
    _target = _currentTarget();
    _focusTarget();
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChange);
    FocusManager.instance.removeListener(_onFocusChange);
    _typing?.cancel();
    for (final node in [_scanFocus, _sellerFocus, _paymentFocus, _zeroStockFocus, _controlledFocus, _shell]) {
      node.dispose();
    }
    _scan.dispose();
    super.dispose();
  }

  /// Campo obrigatório do momento: painel aberto, pagamento, vendedor ou a leitura.
  String _currentTarget() {
    if (controller.paying) return 'payment';
    if (controller.pendingZeroStock != null) return 'zero-stock';
    if (controller.pendingControlled != null) return 'controlled';
    if (controller.seller == null) return 'seller';
    return 'scan';
  }

  FocusNode _nodeFor(String target) => switch (target) {
    'payment' => _paymentFocus,
    'zero-stock' => _zeroStockFocus,
    'controlled' => _controlledFocus,
    'seller' => _sellerFocus,
    _ => _scanFocus,
  };

  /// Põe o cursor no campo da vez (depois do quadro, quando ele já existe na tela).
  void _focusTarget() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      final node = _nodeFor(_currentTarget());
      if (node.context != null && node.canRequestFocus) node.requestFocus();
    });
  }

  void _onControllerChange() {
    final target = _currentTarget();
    if (target != _target) {
      _target = target;
      _focusTarget();
    }
  }

  /// Ninguém com o cursor (janela fechou, campo sumiu da tela): volta para o campo da vez.
  void _onFocusChange() {
    if (!mounted) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus == _shell || focus is FocusScopeNode || focus.context == null) _focusTarget();
  }

  /// Abre a janela e, ao fechar, volta para o campo da vez.
  void _dialog(Future<void> Function() open) {
    open().whenComplete(_focusTarget);
  }

  void _onTyping(String text) {
    _typing?.cancel();
    final value = text.trim();
    // Código de barras, código do produto ou cupom do orçamento: sem sugestões.
    if (value.isEmpty || RegExp(r'^\d+$').hasMatch(value) || RegExp(r'^[Oo]\d+-').hasMatch(value)) {
      controller.clearResults();
      return;
    }
    if (value.replaceAll(RegExp(r'\s'), '').length < 3) return;
    _typing = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || _scan.text.trim() != value) return;
      controller.suggest(value);
      setState(() => _highlight = controller.results.isEmpty ? -1 : 0);
    });
  }

  void _moveHighlight(int step) {
    final count = controller.results.length;
    if (count == 0) return;
    setState(() => _highlight = (_highlight + step).clamp(0, count - 1));
  }

  void _closeSuggestions() {
    setState(() => _highlight = -1);
    controller.clearResults();
    controller.clearNotice();
  }

  void _submitScan() {
    _typing?.cancel();
    final results = controller.results;
    final value = _scan.text.trim();
    final typedName = value.isNotEmpty && !RegExp(r'^\d+$').hasMatch(value) && !RegExp(r'^[Oo]\d+-').hasMatch(value);
    if (typedName && _highlight >= 0 && _highlight < results.length) {
      controller.add(results[_highlight]);
    } else {
      controller.scan(_scan.text);
    }
    _scan.clear();
    setState(() => _highlight = controller.results.isEmpty ? -1 : 0);
    _focusTarget();
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
            _dialog(() => showCustomerDialog(context, controller)),
        const SingleActivator(LogicalKeyboardKey.f3): () {
          if (!controller.quoteMode) _dialog(() => showQuoteLookup(context, controller));
        },
        const SingleActivator(LogicalKeyboardKey.f6): () =>
            _dialog(() => showCashMovementDialog(context, controller, withdrawal: true)),
        const SingleActivator(LogicalKeyboardKey.f7): () =>
            _dialog(() => showCashMovementDialog(context, controller, withdrawal: false)),
        const SingleActivator(LogicalKeyboardKey.f8): () =>
            _dialog(() => showCloseShiftDialog(context, controller)),
        const SingleActivator(LogicalKeyboardKey.f9): () {
          if (!controller.quoteMode) _dialog(() => showReturnDialog(context, controller));
        },
      },
      child: Focus(
        focusNode: _shell,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final items = _ItemsPanel(
                controller: controller,
                scan: _scan,
                scanFocus: _scanFocus,
                sellerFocus: _sellerFocus,
                zeroStockFocus: _zeroStockFocus,
                controlledFocus: _controlledFocus,
                highlight: _highlight,
                onScan: _submitScan,
                onTyping: _onTyping,
                onMove: _moveHighlight,
                onClose: _closeSuggestions,
                dialog: _dialog,
              );
              final side = controller.quoteMode
                  ? QuotePanel(controller: controller, dialog: _dialog)
                  : controller.paying
                  ? _PaymentPanel(controller: controller, amountFocus: _paymentFocus)
                  : _TotalsPanel(controller: controller, cart: cart, dialog: _dialog);
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
    required this.sellerFocus,
    required this.zeroStockFocus,
    required this.controlledFocus,
    required this.highlight,
    required this.onScan,
    required this.onTyping,
    required this.onMove,
    required this.onClose,
    required this.dialog,
  });

  final PosController controller;
  final TextEditingController scan;
  final FocusNode scanFocus;
  final FocusNode sellerFocus;
  final FocusNode zeroStockFocus;
  final FocusNode controlledFocus;
  final int highlight;
  final VoidCallback onScan;
  final ValueChanged<String> onTyping;
  final ValueChanged<int> onMove;
  final VoidCallback onClose;
  final void Function(Future<void> Function() open) dialog;

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
        SellerPanel(controller: controller, focusNode: sellerFocus, onIdentified: scanFocus.requestFocus),
        if (controller.pendingControlled != null)
          ControlledPanel(controller: controller, pending: controller.pendingControlled!, focusNode: controlledFocus),
        if (controller.pendingZeroStock != null)
          ZeroStockPanel(
            controller: controller,
            pending: controller.pendingZeroStock!,
            focusNode: zeroStockFocus,
          ),
        SuggestionKeys(
          onMove: onMove,
          onClose: onClose,
          child: TextField(
            key: const Key('scan-field'),
            controller: scan,
            focusNode: scanFocus,
            enabled: !controller.paying && (!controller.quoteMode || controller.seller != null),
            decoration: const InputDecoration(
              labelText: 'Código de barras, código do produto ou nome (F2)',
              helperText: 'Digite partes do nome separadas por espaço: "dip 500" acha Dipirona Sódica 500 mg.',
              prefixIcon: Icon(Icons.qr_code_scanner),
            ),
            onChanged: onTyping,
            onSubmitted: (_) => onScan(),
          ),
        ),
        if (controller.results.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: Card(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (index, product) in controller.results.indexed)
                    ListTile(
                      key: Key('result-${product.code}'),
                      selected: index == highlight,
                      selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
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
                            key: Key('info-result-${product.code}'),
                            tooltip: 'Dados do produto',
                            icon: const Icon(Icons.info_outline),
                            onPressed: () => dialog(() => showProductInfo(context, controller, product)),
                          ),
                          IconButton(
                            key: Key('network-result-${product.code}'),
                            tooltip: 'Estoque nas filiais',
                            icon: const Icon(Icons.store),
                            onPressed: () =>
                                dialog(() => showNetworkStock(context, controller, product)),
                          ),
                        ],
                      ),
                      onTap: () {
                        controller.add(product);
                        scan.clear();
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
                                : () => dialog(() => showDiscountDialog(
                                    context,
                                    controller,
                                    line,
                                  )),
                          ),
                          IconButton(
                            key: Key('info-$index'),
                            tooltip: 'Dados do produto',
                            icon: const Icon(Icons.info_outline),
                            onPressed: () => dialog(() => showProductInfo(context, controller, line.product)),
                          ),
                          IconButton(
                            key: Key('stock-$index'),
                            tooltip: 'Estoque nas filiais',
                            icon: const Icon(Icons.store),
                            onPressed: () => dialog(() => showNetworkStock(
                              context,
                              controller,
                              line.product,
                            )),
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
  const _TotalsPanel({required this.controller, required this.cart, required this.dialog});

  final PosController controller;
  final Cart cart;
  final void Function(Future<void> Function() open) dialog;

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
                    : () => dialog(() => showCustomerDialog(context, controller)),
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
            if (cart.isEmpty && controller.findQuote != null)
              OutlinedButton.icon(
                key: const Key('quote-lookup-open'),
                onPressed: () => dialog(() => showQuoteLookup(context, controller)),
                icon: const Icon(Icons.assignment),
                label: const Text('Puxar orçamento (F3)'),
              ),
            if (cart.quoteCode != null) Text('Orçamento ${cart.quoteCode}', key: const Key('cart-quote')),
            const SizedBox(height: 8),
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
  const _PaymentPanel({required this.controller, required this.amountFocus});

  final PosController controller;
  final FocusNode amountFocus;

  @override
  State<_PaymentPanel> createState() => _PaymentPanelState();
}

class _PaymentPanelState extends State<_PaymentPanel> {
  PaymentMethod _method = PaymentMethod.cash;
  Map<String, dynamic>? _agreement;
  ({String id, String code, int balanceCents})? _credit;
  final _creditCode = TextEditingController();
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
    _creditCode.dispose();
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
    final credit = _method == PaymentMethod.returnCredit ? _credit : null;
    if (_method == PaymentMethod.returnCredit && credit == null) {
      setState(() => _error = 'Digite o código do documento de devolução e busque o crédito.');
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
        returnId: credit?.id,
        returnCode: credit?.code,
        creditBalanceCents: credit?.balanceCents,
      ),
    );
    setState(() {
      _error = null;
      if (credit != null && widget.controller.cart.creditInCart(credit.id) > 0) {
        _credit = null;
        _creditCode.clear();
      }
      _brand.clear();
      _authorization.clear();
      _fillRemaining();
    });
    _refocusAmount();
  }

  /// Busca o crédito e sugere o menor entre o saldo e o que falta.
  Future<void> _findCredit() async {
    final found = await widget.controller.findReturnCredit(_creditCode.text);
    if (!mounted) return;
    setState(() {
      _credit = found;
      if (found == null) return;
      _error = null;
      final cart = widget.controller.cart;
      final available = found.balanceCents - cart.creditInCart(found.id);
      final suggested = available < cart.remainingCents ? available : cart.remainingCents;
      _amount.text = formatCents(suggested).replaceFirst('R\$ ', '');
    });
    if (found != null) _refocusAmount();
  }

  /// Volta para o valor, com o que falta selecionado.
  void _refocusAmount() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.amountFocus.requestFocus();
      selectAllText(_amount);
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
      // Rolável: com o crédito ou o cartão, os campos podem passar da altura da tela.
      child: SingleChildScrollView(
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
                      onSelected: (_) => setState(() {
                        _method = method;
                        _error = null;
                      }),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            if (_method == PaymentMethod.returnCredit) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('credit-code'),
                      controller: _creditCode,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Documento de devolução (D...)'),
                      onSubmitted: (_) => _findCredit(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('find-credit'),
                    onPressed: controller.busy ? null : _findCredit,
                    child: const Text('Buscar crédito'),
                  ),
                ],
              ),
              if (_credit != null)
                Text(
                  'Crédito ${_credit!.code}: saldo de ${formatCents(_credit!.balanceCents - cart.creditInCart(_credit!.id))}',
                  key: const Key('credit-balance'),
                ),
            ],
            NumberField(
              key: const Key('payment-amount'),
              controller: _amount,
              focusNode: widget.amountFocus,
              decimal: true,
              decoration: InputDecoration(
                labelText: _method == PaymentMethod.cash
                    ? 'Valor recebido (R\$)'
                    : 'Valor (R\$)',
                errorText: _error,
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
                title: Text(
                  payment.returnCode == null
                      ? payment.method.label
                      : '${payment.method.label} ${payment.returnCode}',
                ),
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
