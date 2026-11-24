import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/error_display.dart';
import '../core/local_logger.dart';
import '../customers/customer_service.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';
import 'cart.dart';
import 'cash.dart';
import 'controlled.dart';
import 'discount.dart';
import 'money.dart';
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

/// Controlado lido, esperando a receita e a liberação do farmacêutico.
class PendingControlled {
  const PendingControlled({required this.product, required this.quantityMilli});

  final SaleProduct product;
  final int quantityMilli;

  PrescriptionType get suggestedType => PrescriptionType.forClass(product.controlledClass!);
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

  /// Controlado esperando a receita e o farmacêutico.
  PendingControlled? pendingControlled;

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
    info = null;
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
    pendingControlled = null;
    pendingZeroStock = null;
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
      if (product.controlledClass != null) {
        if (product.priceCents == null) throw const PosException('FA974');
        final quantity = product.barcodeFractionMilli == null
            ? quantityMilli
            : (quantityMilli * product.barcodeFractionMilli! / 1000).round();
        pendingControlled = PendingControlled(product: product, quantityMilli: quantity);
        results = const [];
        notice = null;
        notifyListeners();
        return;
      }
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

  /// Lotes do controlado com saldo para esta venda (descontado o que já está nela), FEFO.
  /// Lote vencido não aparece: não pode ser vendido.
  List<ControlledBatch> controlledBatches(SaleProduct product) {
    final now = _clock();
    String two(int value) => value.toString().padLeft(2, '0');
    final today = '${now.year}-${two(now.month)}-${two(now.day)}';
    return [
      for (final batch in database.batchesOf(product.id))
        if (batch.expiresOn.compareTo(today) >= 0)
          ControlledBatch(
            id: batch.id,
            number: batch.number,
            expiresOn: batch.expiresOn,
            availableMilli: batch.quantityMilli - cart.quantityOfBatch(batch.id),
          ),
    ].where((batch) => batch.availableMilli > 0).toList();
  }

  /// Farmacêutico (ou quem tem a permissão) confere com código e PIN.
  Future<LocalUser> _pharmacist(String code, String pin) async {
    final user = await auth.verify(code, pin);
    if (!user.can('controlled.dispense')) throw const PosException('FA985');
    return user;
  }

  /// Venda do controlado com receita, comprador e lote. Devolve true quando o item entrou na venda.
  Future<bool> releaseControlled({
    required PrescriptionForm form,
    required String batchId,
    required int quantityMilli,
    required String code,
    required String pin,
  }) async {
    final pending = pendingControlled;
    if (pending == null || operator == null || busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      if (quantityMilli <= 0) throw const PosException('FA975');
      final today = _clock();
      // Confere a receita antes de pedir o PIN, para o farmacêutico não digitar à toa.
      final errors = prescriptionErrors(form, today);
      if (errors.containsKey('date') && form.date != null) throw const PosException('FA987');
      if (errors.isNotEmpty) throw const PosException('FA986');
      final batch = controlledBatches(pending.product).where((batch) => batch.id == batchId).firstOrNull;
      if (batch == null || batch.availableMilli < quantityMilli) throw const PosException('FA988');
      final pharmacist = await _pharmacist(code, pin);
      final release = ControlledRelease.complete(
        form: form,
        batch: batch,
        pharmacist: (id: pharmacist.id, name: pharmacist.name),
        today: today,
      );
      cart.add(pending.product, quantityMilli: quantityMilli, controlled: release);
      cart.payments.clear();
      pendingControlled = null;
      // Sem dados pessoais no log: só o produto, o lote e quem liberou.
      logger?.info('Controlado liberado', fields: {
        'product_code': pending.product.code,
        'batch_number': batch.number,
        'pharmacist_code': pharmacist.code,
      });
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Sem saldo em lote (estoque negativo): o farmacêutico libera e os dados do SNGPC ficam pendentes.
  Future<bool> releaseControlledPending({
    required String reason,
    required int quantityMilli,
    required String code,
    required String pin,
  }) async {
    final pending = pendingControlled;
    if (pending == null || operator == null || busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      if (quantityMilli <= 0) throw const PosException('FA975');
      if (controlledBatches(pending.product).any((batch) => batch.availableMilli >= quantityMilli)) {
        throw const PosException('FA989');
      }
      if (reason.trim().isEmpty) throw const PosException('FA986');
      final pharmacist = await _pharmacist(code, pin);
      final release = ControlledRelease.pending(reason: reason, pharmacist: (id: pharmacist.id, name: pharmacist.name));
      cart.add(pending.product, quantityMilli: quantityMilli, controlled: release);
      cart.payments.clear();
      pendingControlled = null;
      logger?.warn('Controlado liberado sem saldo em lote', fields: {
        'product_code': pending.product.code,
        'pharmacist_code': pharmacist.code,
      });
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void cancelControlled() {
    pendingControlled = null;
    notice = null;
    notifyListeners();
  }

  /// Sangria: até o limite do operador, vale na hora (devolve true); acima, devolve false e a tela
  /// pede quem libere. Nunca retira mais do que o dinheiro que deve estar na gaveta (FA993).
  Future<bool?> withdraw(int amountCents, String reason) async {
    final current = operator;
    final open = session;
    if (current == null || open == null || busy) return null;
    try {
      _checkMovement(amountCents, reason);
      if (amountCents > database.cashInDrawerCents(open.id)) throw const PosException('FA993');
      if (withdrawalNeedsRelease(current, amountCents)) {
        notice = null;
        notifyListeners();
        return false;
      }
      await _recordMovement('withdrawal', amountCents, reason, current, null);
      return true;
    } on PosException catch (error) {
      _fail(error.code);
      return null;
    }
  }

  /// Quem libera a sangria acima do limite: outra pessoa, com limite que cubra o valor.
  Future<bool> releaseWithdrawal(int amountCents, String reason, String code, String pin) async {
    final current = operator;
    final open = session;
    if (current == null || open == null || busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      _checkMovement(amountCents, reason);
      if (amountCents > database.cashInDrawerCents(open.id)) throw const PosException('FA993');
      final releaser = await auth.verify(code, pin);
      checkWithdrawalReleaser(operator: current, releaser: releaser, amountCents: amountCents);
      await _recordMovement('withdrawal', amountCents, reason, current, releaser);
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Suprimento: troco que entra na gaveta. Não precisa de liberação.
  Future<bool> supply(int amountCents, String reason) async {
    final current = operator;
    if (current == null || session == null || busy) return false;
    try {
      _checkMovement(amountCents, reason);
      await _recordMovement('supply', amountCents, reason, current, null);
      return true;
    } on PosException catch (error) {
      _fail(error.code);
      return false;
    }
  }

  void _checkMovement(int amountCents, String reason) {
    if (!cart.isEmpty || paying) throw const PosException('FA998');
    if (amountCents <= 0 || reason.trim().isEmpty || reason.trim().length > 500) throw const PosException('FA994');
  }

  Future<void> _recordMovement(String kind, int amountCents, String reason, LocalUser current, LocalUser? releaser) async {
    final now = _clock();
    database.recordCashMovement(
      sessionId: session!.id,
      kind: kind,
      amountCents: amountCents,
      reason: reason.trim(),
      operatorId: current.id,
      releasedBy: releaser?.id,
      now: now,
    );
    final withdrawal = kind == 'withdrawal';
    logger?.info(withdrawal ? 'Sangria registrada' : 'Suprimento registrado', fields: {
      'user_code': current.code,
      if (releaser != null) 'releaser_code': releaser.code,
    });
    notice = null;
    info = withdrawal ? 'Sangria de ${formatCents(amountCents)} registrada.' : 'Suprimento de ${formatCents(amountCents)} registrado.';
    onSaleSaved?.call();
    final lines = buildCashMovementReceipt(
      fiscal: database.fiscal,
      withdrawal: withdrawal,
      amountCents: amountCents,
      reason: reason.trim(),
      operatorName: current.name,
      releaserName: releaser?.name,
      at: now,
      terminalNumber: terminalNumber() ?? 0,
    );
    await _printLines(withdrawal ? 'sangria' : 'suprimento', lines);
    notifyListeners();
  }

  /// Fechamento com conferência cega: o operador informa o que contou de cada forma, sem ver o
  /// esperado. A diferença é calculada na central. Depois do fechamento, volta para a entrada.
  Future<bool> closeShift(Map<String, int?> countedCents, {String? note}) async {
    final current = operator;
    final open = session;
    if (current == null || open == null || busy) return false;
    try {
      if (!cart.isEmpty || paying) throw const PosException('FA998');
      if (countedMethods.keys.any((method) => countedCents[method] == null || countedCents[method]! < 0)) {
        throw const PosException('FA997');
      }
      if (note != null && note.trim().length > 500) throw const PosException('FA997');
    } on PosException catch (error) {
      _fail(error.code);
      return false;
    }
    busy = true;
    notifyListeners();
    final now = _clock();
    final counted = {for (final method in countedMethods.keys) method: countedCents[method]!};
    final text = note?.trim();
    database.closeSession(
      sessionId: open.id,
      closedBy: current.id,
      countedCents: counted,
      note: text == null || text.isEmpty ? null : text,
      now: now,
    );
    logger?.info('Caixa fechado', fields: {'user_code': current.code});
    onSaleSaved?.call();
    final lines = buildClosingReceipt(
      fiscal: database.fiscal,
      countedCents: counted,
      labels: countedMethods,
      operatorName: current.name,
      openedAt: open.openedAt,
      at: now,
      terminalNumber: terminalNumber() ?? 0,
      note: text,
    );
    busy = false;
    await _printLines('fechamento', lines);
    final printProblem = notice;
    logout();
    session = null;
    notice = printProblem;
    info = 'Caixa fechado. A conferência fica com a gerência.';
    notifyListeners();
    return true;
  }

  Future<void> _printLines(String name, List<ReceiptLine> lines) async {
    try {
      await printer().print(name, lines);
    } catch (error, stack) {
      logger?.error('Falha ao imprimir o comprovante de caixa', errorCode: 'FA973', error: error, stackTrace: stack);
      notice = ErrorDisplay.fromCode('FA973');
    }
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
    // Controlado com lote: a nova quantidade precisa caber no saldo do lote.
    final batch = line.controlled?.batch;
    if (batch != null) {
      final local = database.batchesOf(line.product.id).where((row) => row.id == batch.id).firstOrNull;
      final others = cart.quantityOfBatch(batch.id) - line.quantityMilli;
      if (local == null || local.quantityMilli - others < quantityMilli) return _fail('FA988');
    }
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
