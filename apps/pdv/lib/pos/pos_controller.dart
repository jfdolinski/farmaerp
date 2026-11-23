import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/error_display.dart';
import '../core/local_logger.dart';
import '../customers/customer_service.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';
import 'cart.dart';
import 'discount.dart';
import 'pos_auth.dart';
import 'receipt.dart';

/// Venda concluída, para a tela e a reimpressão.
class CompletedSale {
  const CompletedSale({required this.code, required this.totalCents, required this.changeCents, required this.lines});

  final String code;
  final int totalCents;
  final int changeCents;
  final List<ReceiptLine> lines;
}

/// Produto sem estoque esperando a autorização do gerente (PDV sem internet há bastante tempo).
class PendingZeroStock {
  const PendingZeroStock({required this.product, required this.quantityMilli, required this.minutesOffline});

  final SaleProduct product;
  final int quantityMilli;
  final int minutesOffline;
}

/// Estado do caixa: quem está operando, o turno, a venda em montagem e o pagamento.
class PosController extends ChangeNotifier {
  PosController({
    required this.database,
    required this.auth,
    required this.printer,
    required this.terminalNumber,
    this.onSaleSaved,
    this.customers,
    this.networkStock,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Busca e escolha de cliente (com internet, ou entre os guardados no terminal).
  final CustomerService? customers;

  /// Estoque do produto nas filiais do grupo (com internet).
  final Future<List<Map<String, dynamic>>> Function(String productId)? networkStock;

  /// Produto sem estoque esperando a autorização do gerente.
  PendingZeroStock? pendingZeroStock;

  final LocalDatabase database;
  final PosAuth auth;

  /// Impressora em uso (muda pela configuração do terminal).
  ReceiptPrinter Function() printer;

  /// Número do terminal, que forma o código da venda.
  final int? Function() terminalNumber;

  /// Chamado depois de gravar a venda: adianta o envio, sem esperar o próximo sinal de vida.
  final void Function()? onSaleSaved;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  LocalUser? operator;
  LocalCashSession? session;
  final cart = Cart();
  bool paying = false;
  bool busy = false;
  ErrorDisplay? notice;
  CompletedSale? lastSale;

  /// Aviso que não é erro (por exemplo, venda concluída).
  String? info;

  /// Resultado da última busca por nome.
  List<SaleProduct> results = const [];

  void _fail(String code) {
    notice = ErrorDisplay.fromCode(code);
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    info = null;
    notifyListeners();
  }

  Future<void> login(String code, String pin) async {
    if (busy) return;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      operator = await auth.verify(code, pin, permission: 'sales.sell');
      session = database.openCashSession;
      logger?.info('Operador entrou no PDV', fields: {'user_code': operator!.code});
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void logout() {
    operator = null;
    cart.clear();
    paying = false;
    results = const [];
    notice = null;
    info = null;
    notifyListeners();
  }

  void openShift(int openingFloatCents) {
    final current = operator;
    if (current == null) return;
    session = database.openSession(operator: current, openingFloatCents: openingFloatCents, now: _clock());
    logger?.info('Turno aberto', fields: {'user_code': current.code});
    onSaleSaved?.call();
    notifyListeners();
  }

  /// Leitura do código de barras (ou o código do produto). Texto sem número busca por nome.
  void scan(String text) {
    final value = text.trim();
    if (value.isEmpty) return;
    notice = null;
    info = null;
    if (RegExp(r'^\d+$').hasMatch(value)) {
      final product = database.saleProductByCode(value);
      if (product == null) return _fail('FA970');
      add(product);
      return;
    }
    results = database.searchSaleProducts(value);
    if (results.isEmpty) return _fail('FA970');
    notifyListeners();
  }

  void add(SaleProduct product, {int quantityMilli = 1000}) {
    try {
      final quantity = product.barcodeFractionMilli == null
          ? quantityMilli
          : (quantityMilli * product.barcodeFractionMilli! / 1000).round();
      // Por encomenda não tem estoque mesmo: o aviso basta.
      if (product.status != 'on_order' && product.controlledClass == null && product.priceCents != null &&
          product.stockMilli - cart.quantityOf(product.id) - quantity < 0) {
        final minutes = minutesWithoutSync;
        if (minutes == null || minutes < offlineZeroStockMinutes) {
          throw const PosException('FA977');
        }
        pendingZeroStock = PendingZeroStock(product: product, quantityMilli: quantityMilli, minutesOffline: minutes);
        results = const [];
        notice = null;
        notifyListeners();
        return;
      }
      cart.add(product, quantityMilli: quantityMilli);
      results = const [];
      notice = null;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    }
    notifyListeners();
  }

  /// Minutos desde a última descida concluída (vazio se nunca desceu).
  int? get minutesWithoutSync {
    final last = database.syncState.lastPullAt;
    return last == null ? null : _clock().difference(last).inMinutes;
  }

  /// Tempo mínimo sem sincronizar para aceitar a venda sem estoque (filial ou terminal).
  int get offlineZeroStockMinutes => (database.fiscal?['offline_zero_stock_minutes'] as num?)?.toInt() ?? 30;

  /// O gerente autoriza a venda sem estoque com o código e o PIN dele.
  Future<void> approveZeroStock(String code, String pin) async {
    final pending = pendingZeroStock;
    final current = operator;
    if (pending == null || current == null || busy) return;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final supervisor = await auth.verify(code, pin);
      if (!supervisor.can('sales.zero_stock_release')) throw const PosException('FA981');
      final line = cart.add(pending.product, quantityMilli: pending.quantityMilli);
      line.zeroStockRelease = (supervisorId: supervisor.id, supervisorName: supervisor.name, minutesOffline: pending.minutesOffline);
      pendingZeroStock = null;
      logger?.warn('Venda sem estoque autorizada sem internet', fields: {
        'product_code': pending.product.code,
        'supervisor_code': supervisor.code,
        'minutes_offline': pending.minutesOffline,
      });
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void cancelZeroStock() {
    pendingZeroStock = null;
    notifyListeners();
  }

  /// Desconto em centavos no item. Dentro do limite do operador vale na hora; acima, devolve
  /// [DiscountNeed.release] e a tela pede o supervisor.
  DiscountNeed applyDiscount(CartLine line, int discountCents) {
    final current = operator;
    if (current == null) return DiscountNeed.none;
    try {
      final need = checkDiscount(line: line, discountCents: discountCents, operator: current, now: _clock());
      if (need == DiscountNeed.none) {
        line.discountCents = discountCents;
        line.release = null;
        cart.payments.clear();
        notice = null;
      }
      notifyListeners();
      return need;
    } on PosException catch (error) {
      _fail(error.code);
      return DiscountNeed.none;
    }
  }

  /// O supervisor libera o desconto com o código e o PIN dele, e o motivo fica registrado.
  Future<bool> releaseDiscount(CartLine line, int discountCents, String code, String pin, String reason) async {
    final current = operator;
    if (current == null || busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      if (reason.trim().isEmpty) throw const PosException('FA978');
      final supervisor = await auth.verify(code, pin);
      checkSupervisor(line: line, discountCents: discountCents, operator: current, supervisor: supervisor, now: _clock());
      line.discountCents = discountCents;
      line.release = (supervisorId: supervisor.id, supervisorName: supervisor.name, reason: reason.trim());
      cart.payments.clear();
      logger?.info('Desconto liberado por supervisor', fields: {'product_code': line.product.code, 'supervisor_code': supervisor.code});
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Cliente escolhido na busca: os dados completos ficam guardados no terminal.
  Future<void> selectCustomer(String id) async {
    final service = customers;
    if (service == null || busy) return;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final data = await service.select(id);
      cart.customer = SaleCustomer(
        id: id,
        name: data['name']! as String,
        code: data['code']! as int,
        documentMasked: maskDocument(data['document'] as String?),
        agreements: ((data['agreements'] as List?) ?? const []).cast<Map<String, dynamic>>(),
      );
    } on ApiException catch (error) {
      notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void clearCustomer() {
    cart.customer = null;
    cart.payments.removeWhere((payment) => payment.method == PaymentMethod.agreement);
    notifyListeners();
  }

  /// Estoque nas filiais; sem internet, FA984.
  Future<List<Map<String, dynamic>>?> stockElsewhere(SaleProduct product) async {
    final lookup = networkStock;
    if (lookup == null) return null;
    try {
      return await lookup(product.id);
    } on ApiException catch (error) {
      _fail(const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA984' : error.code);
      return null;
    }
  }

  void setQuantity(CartLine line, int quantityMilli) {
    if (quantityMilli <= 0) return _fail('FA975');
    line.quantityMilli = quantityMilli;
    notifyListeners();
  }

  void remove(CartLine line) {
    cart.lines.remove(line);
    cart.payments.clear();
    notifyListeners();
  }

  void startPayment() {
    if (cart.isEmpty) return;
    paying = true;
    notice = null;
    notifyListeners();
  }

  void backToItems() {
    paying = false;
    cart.payments.clear();
    notifyListeners();
  }

  void addPayment(Payment payment) {
    if (payment.amountCents <= 0) return _fail('FA972');
    if (payment.method == PaymentMethod.agreement && cart.customer == null) return _fail('FA983');
    cart.payments.add(payment);
    notice = null;
    notifyListeners();
  }

  void removePayment(Payment payment) {
    cart.payments.remove(payment);
    notifyListeners();
  }

  /// Grava a venda (com a outbox, numa transação) e imprime. Falha na impressão não desfaz a venda.
  Future<void> finish() async {
    final current = operator;
    final open = session;
    if (current == null || open == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      final now = _clock();
      final draft = buildSale(
        cart: cart,
        session: open,
        operator: current,
        number: database.nextSaleNumber,
        terminalNumber: terminalNumber() ?? 0,
        now: now,
      );
      database.saveSale(draft.payload, code: draft.code, itemRows: draft.itemRows, now: now);
      final lines = buildReceipt(
        fiscal: database.fiscal,
        saleCode: draft.code,
        soldAt: now,
        customer: cart.customer,
        operatorName: current.name,
        cart: cart,
        terminalNumber: terminalNumber() ?? 0,
      );
      lastSale = CompletedSale(code: draft.code, totalCents: cart.totalCents, changeCents: cart.changeCents, lines: lines);
      logger?.info('Venda concluída', fields: {'sale_code': draft.code, 'items': cart.lines.length});
      cart.clear();
      paying = false;
      info = 'Venda ${draft.code} concluída.';
      onSaleSaved?.call();
      await _print(lastSale!);
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> reprint() async {
    final sale = lastSale;
    if (sale == null || busy) return;
    busy = true;
    notifyListeners();
    try {
      await _print(sale);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _print(CompletedSale sale) async {
    try {
      await printer().print(sale.code, sale.lines);
    } catch (error, stack) {
      logger?.error('Falha ao imprimir o comprovante', errorCode: 'FA973', error: error, stackTrace: stack, fields: {'sale_code': sale.code});
      notice = ErrorDisplay.fromCode('FA973');
    }
  }
}
