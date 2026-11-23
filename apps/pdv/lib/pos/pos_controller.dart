import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/error_display.dart';
import '../core/local_logger.dart';
import '../local/local_database.dart';
import 'cart.dart';
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

/// Estado do caixa: quem está operando, o turno, a venda em montagem e o pagamento.
class PosController extends ChangeNotifier {
  PosController({
    required this.database,
    required this.auth,
    required this.printer,
    required this.terminalNumber,
    this.onSaleSaved,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

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
      cart.add(product, quantityMilli: quantityMilli);
      results = const [];
      notice = null;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    }
    notifyListeners();
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
