import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/error_display.dart';
import '../core/local_logger.dart';
import '../customers/customer_service.dart';
import '../face/face_math.dart' show templateBytes;
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
    this.openQuotes,
    this.findQuote,
    this.saleForReturn,
    this.returnDocument,
    this.returnCredit,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Busca e escolha de cliente (com internet, ou entre os guardados no terminal).
  final CustomerService? customers;

  /// Estoque do produto nas filiais do grupo (com internet).
  final Future<List<Map<String, dynamic>>> Function(String productId)? networkStock;

  /// Produto sem estoque esperando a autorização do gerente.
  PendingZeroStock? pendingZeroStock;

  /// Orçamentos da loja (com internet): a lista dos pendentes e a busca pela plaquinha ou pelo cupom.
  final Future<List<Map<String, dynamic>>> Function()? openQuotes;
  final Future<Map<String, dynamic>> Function(String key)? findQuote;

  /// Devolução (com internet): a venda pelo código do comprovante e o documento para a sangria.
  final Future<Map<String, dynamic>> Function(String code)? saleForReturn;
  final Future<Map<String, dynamic>> Function(String code)? returnDocument;

  /// Crédito de devolução pelo código D (com internet; sem internet, os créditos deste terminal).
  final Future<Map<String, dynamic>> Function(String code)? returnCredit;

  /// Controlados do orçamento esperando a receita, um por vez.
  final controlledQueue = <PendingControlled>[];

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

  /// Terminal de orçamento: sem entrada de operador nem turno; cada orçamento é do vendedor.
  bool get quoteMode => database.terminalProfile == 'quote';

  /// Quem responde pelos limites de desconto: no caixa, o operador; no orçamento, o vendedor.
  LocalUser? get actor => quoteMode ? cart.seller : operator;

  /// Vendedor fixo do terminal (autoatendimento) entra sozinho.
  void _applyFixedSeller() {
    if (cart.seller != null) return;
    final id = database.fixedSellerId;
    if (id != null) cart.seller = database.userById(id);
  }

  /// O vendedor se identifica com o código (e o PIN, se a filial exigir). Precisa poder orçar ou vender.
  Future<bool> identifySeller(String code, [String pin = '']) async {
    if (busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final LocalUser user;
      if (database.sellerPinRequired) {
        user = await auth.verify(code, pin, purpose: AuthPurpose.seller);
      } else {
        final number = int.tryParse(code.trim());
        final found = number == null ? null : database.userByCode(number);
        if (found == null) throw const PosException('FA880');
        user = found;
      }
      if (!user.can('sales.quote') && !user.can('sales.sell')) throw const PosException('FA880');
      cart.seller = user;
      info = null;
      logger?.info('Vendedor identificado', fields: {'seller_code': user.code});
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Vendedor desta venda ou orçamento (o fixo do terminal entra sozinho).
  LocalUser? get seller {
    _applyFixedSeller();
    return cart.seller;
  }

  /// Troca o vendedor (os itens ficam).
  void changeSeller() {
    cart.seller = null;
    notifyListeners();
  }

  /// Último orçamento concluído neste terminal (para reimprimir).
  CompletedSale? lastQuote;
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
      operator = await auth.verify(code, pin, permission: 'sales.sell', purpose: AuthPurpose.login);
      session = database.openCashSession;
      logger?.info('Operador entrou no PDV', fields: {'user_code': operator!.code});
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Quem digitou este código não tem como entrar sozinho aqui (só câmera ou só digital, sem o
  /// aparelho): a tela pede a liberação do gerente.
  bool loginNeedsRelease(String code) {
    final user = auth.userByCodeText(code);
    return user != null && auth.needsRelease(user);
  }

  /// Entrada pelo rosto: a câmera reconheceu a pessoa (com prova de vida e o desafio).
  void loginWithFace(LocalUser user) {
    if (busy) return;
    notice = null;
    info = null;
    try {
      operator = auth.acceptFace(user, permission: 'sales.sell');
      session = database.openCashSession;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
    }
    notifyListeners();
  }

  /// Rosto não reconhecido entre os cadastrados deste terminal.
  void faceNotRecognized() {
    notice = ErrorDisplay.fromCode('FA825');
    notifyListeners();
  }

  /// Quem autoriza o cadastro do rosto: código e PIN de quem tem "Cadastrar o rosto no PDV".
  Future<LocalUser?> faceEnroller(String code, String pin) async {
    try {
      final enroller = await auth.verify(code, pin);
      if (!enroller.can('users.biometrics')) throw const PosException('FA822');
      notice = null;
      return enroller;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return null;
    } finally {
      notifyListeners();
    }
  }

  /// Cadastra o rosto lido: vale neste terminal na hora e sobe para a central com o consentimento.
  void enrollFace({
    required LocalUser person,
    required LocalUser enroller,
    required List<double> template,
    required String model,
    required String termVersion,
    required DateTime consentedAt,
  }) {
    const uuid = Uuid();
    final now = _clock();
    final bytes = templateBytes(template);
    database.saveFaceEnrollment({
      'id': uuid.v7(),
      'user_id': person.id,
      'enrolled_by': enroller.id,
      'enrolled_at': now.toUtc().toIso8601String(),
      'model': model,
      'template': base64.encode(bytes),
      'consent': {'id': uuid.v7(), 'term_version': termVersion, 'consented_at': consentedAt.toUtc().toIso8601String()},
    }, template: bytes, now: now);
    logger?.info('Rosto cadastrado', fields: {'user_code': person.code, 'enroller_code': enroller.code});
    info = 'Rosto de ${person.name} cadastrado.';
    notifyListeners();
    onSaleSaved?.call();
  }

  /// Entrada liberada pelo gerente (código e PIN dele), com registro dos dois.
  Future<void> releaseLogin(String code, String managerCode, String managerPin) async {
    if (busy) return;
    busy = true;
    notice = null;
    info = null;
    notifyListeners();
    try {
      operator = await auth.release(code, managerCode, managerPin, permission: 'sales.sell');
      session = database.openCashSession;
      logger?.info('Operador entrou no PDV com a liberação do gerente', fields: {'user_code': operator!.code});
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
    controlledQueue.clear();
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
    // Cupom do orçamento: traz o vendedor junto.
    if (!quoteMode && RegExp(r'^[Oo]\d+-\d{6,}$').hasMatch(value)) {
      unawaited(loadQuote(value.toUpperCase()));
      return;
    }
    _applyFixedSeller();
    if (cart.seller == null) return _fail('FA881');
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

  /// Sugestões enquanto o operador digita o nome (autocompletar). Sem achar nada, só limpa a lista.
  void suggest(String text) {
    final next = database.searchSaleProducts(text);
    results = next;
    notifyListeners();
  }

  void clearResults() {
    if (results.isEmpty) return;
    results = const [];
    notifyListeners();
  }

  void add(SaleProduct product, {int quantityMilli = 1000}) {
    _applyFixedSeller();
    if (cart.seller == null) return _fail('FA881');
    try {
      // No orçamento, controlado e falta de estoque só avisam: a receita e a venda são do caixa.
      if (quoteMode) {
        cart.add(product, quantityMilli: quantityMilli, quote: true);
        results = const [];
        notice = null;
        notifyListeners();
        return;
      }
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
      reprice();
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
      reprice();
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

  /// Recalcula a venda com as condições de agora: preço atual da loja e o desconto de cada item na
  /// mesma fração. Roda a cada mudança (itens, quantidade, cliente, pagamento). As regras por cliente
  /// e por forma de pagamento entram aqui quando chegarem (Etapa 7). Se o total mudar com pagamento
  /// lançado, o pagamento é refeito.
  void reprice() {
    final before = cart.totalCents;
    for (final line in cart.lines) {
      final current = database.saleProductById(line.product.id);
      if (current?.priceCents != null) line.unitPriceCents = current!.priceCents!;
      final rate = line.discountRate;
      if (rate != null) line.discountCents = math.min(line.grossCents, (line.grossCents * rate).round());
    }
    if (cart.totalCents != before && cart.payments.isNotEmpty) {
      cart.payments.clear();
      info = 'O total mudou: refaça o pagamento.';
    }
  }

  /// Lista dos orçamentos pendentes da loja; sem internet, FA890.
  Future<List<Map<String, dynamic>>?> pendingQuotes() async {
    final lookup = openQuotes;
    if (lookup == null) {
      _fail('FA890');
      return null;
    }
    try {
      return await lookup();
    } on ApiException catch (error) {
      _fail(const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA890' : error.code);
      return null;
    }
  }

  /// Puxa o orçamento (plaquinha ou código do cupom) para a venda: vendedor, cliente e itens com o
  /// preço de agora e o desconto do orçamento na mesma fração (com a liberação que veio). Item sem
  /// estoque ou fora deste terminal fica de fora, com aviso; controlado abre a receita, um por vez.
  Future<bool> loadQuote(String key) async {
    final lookup = findQuote;
    final current = operator;
    if (quoteMode || current == null || session == null || busy) return false;
    if (!cart.isEmpty) {
      _fail('FA889');
      return false;
    }
    if (lookup == null) {
      _fail('FA890');
      return false;
    }
    busy = true;
    notice = null;
    info = null;
    results = const [];
    notifyListeners();
    try {
      final data = await lookup(key.trim());
      final skipped = <String>[];
      final sellerId = data['seller_id'] as String?;
      cart.seller = sellerId == null ? null : database.userById(sellerId);
      cart.quoteId = data['id'] as String;
      cart.quoteCode = data['code'] as String;
      final now = _clock();
      for (final item in ((data['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final product = database.saleProductById(item['product_id'] as String);
        final quantity = ((item['quantity'] as num) * 1000).round();
        if (product == null) {
          skipped.add('item ${item['line']}, que não está neste terminal');
          continue;
        }
        if (product.priceCents == null) {
          skipped.add('${product.name}, sem preço');
          continue;
        }
        if (product.controlledClass != null) {
          controlledQueue.add(PendingControlled(product: product, quantityMilli: quantity));
          continue;
        }
        if (product.status != 'on_order' && product.stockMilli - cart.quantityOf(product.id) - quantity < 0) {
          skipped.add('${product.name}, sem estoque');
          continue;
        }
        final discount = (item['discount'] as num?) ?? 0;
        final line = cart.add(product, quantityMilli: quantity, merge: discount <= 0);
        if (discount > 0) {
          final gross = (item['quantity'] as num) * (item['unit_price'] as num);
          line.discountRate = gross <= 0 ? null : discount / gross;
          final release = item['release'] as Map<String, dynamic>?;
          if (release != null) {
            final supervisorId = release['supervisor_id'] as String;
            line.release = (
              supervisorId: supervisorId,
              supervisorName: database.userById(supervisorId)?.name ?? 'supervisor',
              reason: release['reason'] as String,
            );
          }
        }
      }
      reprice();
      // Sem liberação, o desconto do orçamento fica no que o operador pode dar sozinho.
      for (final line in cart.lines) {
        if (line.discountCents == 0 || line.release != null) continue;
        if (checkDiscount(line: line, discountCents: line.discountCents, operator: current, now: now) == DiscountNeed.none) continue;
        final limit = discountLimitBp(current) ?? 10000;
        final rule = current.can('sales.discount_override') ? 10000 : (line.product.maxDiscountAt(now) ?? 10000);
        line.setDiscount((line.grossCents * math.min(limit, rule) / 10000).floor());
      }
      final customerId = data['customer_id'] as String?;
      final service = customers;
      if (customerId != null && service != null) {
        try {
          final customer = await service.select(customerId);
          cart.customer = SaleCustomer(
            id: customerId,
            name: customer['name']! as String,
            code: customer['code']! as int,
            documentMasked: maskDocument(customer['document'] as String?),
            agreements: ((customer['agreements'] as List?) ?? const []).cast<Map<String, dynamic>>(),
          );
        } on ApiException {
          skipped.add('o cliente (identifique de novo)');
        }
      }
      _nextControlled();
      info = 'Orçamento ${data['code']} carregado.${skipped.isEmpty ? '' : ' Ficou de fora: ${skipped.join('; ')}.'}';
      logger?.info('Orçamento puxado no caixa', fields: {'quote_code': data['code'], 'skipped': skipped.length});
      return true;
    } on ApiException catch (error) {
      cart.clear();
      controlledQueue.clear();
      notice = ErrorDisplay.fromCode(const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA890' : error.code, traceId: error.traceId);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Próximo controlado do orçamento, se houver.
  void _nextControlled() {
    if (pendingControlled == null && controlledQueue.isNotEmpty) pendingControlled = controlledQueue.removeAt(0);
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
      _nextControlled();
      reprice();
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
      _nextControlled();
      reprice();
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
    _nextControlled();
    notice = null;
    notifyListeners();
  }

  /// Sangria: até o limite do operador, vale na hora (devolve true); acima, devolve false e a tela
  /// pede quem libere. Nunca retira mais do que o dinheiro que deve estar na gaveta (FA993).
  Future<bool?> withdraw(int amountCents, String reason, {String? returnId}) async {
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
      await _recordMovement('withdrawal', amountCents, reason, current, null, returnId: returnId);
      return true;
    } on PosException catch (error) {
      _fail(error.code);
      return null;
    }
  }

  /// Quem libera a sangria acima do limite: outra pessoa, com limite que cubra o valor.
  Future<bool> releaseWithdrawal(int amountCents, String reason, String code, String pin, {String? returnId}) async {
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
      await _recordMovement('withdrawal', amountCents, reason, current, releaser, returnId: returnId);
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Documento de devolução em dinheiro ainda não pago: deste terminal (sem internet) ou da loja.
  Future<Map<String, dynamic>?> findReturnDocument(String code) async {
    final value = code.trim().toUpperCase();
    final local = database.localCashReturn(value);
    if (local != null) return local;
    final lookup = returnDocument;
    if (lookup == null) {
      _fail('FA896');
      return null;
    }
    try {
      return await lookup(value);
    } on ApiException catch (error) {
      notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
      notifyListeners();
      return null;
    }
  }

  /// Crédito de devolução para pagar a compra: o saldo da central menos o que este terminal
  /// usou e ainda não enviou; sem internet, os créditos feitos aqui. Devolve o saldo sem contar esta venda.
  Future<({String id, String code, int balanceCents})?> findReturnCredit(String code) async {
    final value = code.trim().toUpperCase();
    if (value.isEmpty) return null;
    Map<String, dynamic>? found;
    var balanceCents = 0;
    final lookup = returnCredit;
    var offline = lookup == null;
    if (lookup != null) {
      try {
        found = await lookup(value);
        balanceCents = ((found['balance'] as num) * 100).round() - database.unsentReturnCreditCents(found['id'] as String);
      } on ApiException catch (error) {
        if (!const {'FA001', 'FA008', 'FA009'}.contains(error.code)) {
          notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
          notifyListeners();
          return null;
        }
        offline = true;
      }
    }
    if (offline) {
      found = database.localReturnCredit(value);
      if (found != null) balanceCents = ((found['balance'] as num) * 100).round();
    }
    if (found == null || balanceCents - cart.creditInCart(found['id'] as String) <= 0) {
      _fail('FA872');
      return null;
    }
    notice = null;
    notifyListeners();
    return (id: found['id'] as String, code: found['code'] as String, balanceCents: balanceCents);
  }

  /// Venda para devolver: da central (com internet; qualquer caixa da loja) ou, sem internet, deste terminal.
  Future<Map<String, dynamic>?> findSaleForReturn(String code) async {
    final value = code.trim();
    if (value.isEmpty) return null;
    final lookup = saleForReturn;
    if (lookup != null) {
      try {
        return await lookup(value);
      } on ApiException catch (error) {
        if (!const {'FA001', 'FA008', 'FA009'}.contains(error.code)) {
          notice = ErrorDisplay.fromCode(error.code, traceId: error.traceId);
          notifyListeners();
          return null;
        }
      }
    }
    final local = database.localSaleForReturn(value, now: _clock());
    if (local == null) _fail('FA891');
    return local;
  }

  /// A devolução desta venda precisa da liberação de outra pessoa? Fora do prazo, sempre; no
  /// prazo, quando o operador não tem a permissão "Fazer devolução".
  bool returnNeedsAuthorization(Map<String, dynamic> sale) =>
      sale['late'] == true || !(operator?.can('sales.return') ?? false);

  /// Grava a devolução (documento, itens e destino), põe na outbox e imprime o comprovante.
  /// [quantities] em milésimos por item da venda. Devolve o documento, ou null com o aviso na tela.
  Future<({String id, String code, int totalCents, String destination})?> makeReturn({
    required Map<String, dynamic> sale,
    required Map<String, int> quantities,
    required String reason,
    required String destination,
    String code = '',
    String pin = '',
  }) async {
    final current = operator;
    final open = session;
    if (current == null || open == null || busy || quoteMode) return null;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      if (!cart.isEmpty || paying) throw const PosException('FA998');
      if (reason.trim().isEmpty || reason.trim().length > 500) throw const PosException('FA870');
      if (destination == 'agreement' && sale['has_agreement'] != true) throw const PosException('FA897');
      if (!returnDestinationLabels.containsKey(destination)) throw const PosException('FA894');
      const uuid = Uuid();
      final items = <Map<String, Object?>>[];
      final printed = <({String name, int quantityMilli, int amountCents})>[];
      var totalCents = 0;
      for (final item in ((sale['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final quantity = quantities[item['id']] ?? 0;
        if (quantity <= 0) continue;
        if (item['controlled'] == true) throw const PosException('FA893');
        final sold = ((item['quantity'] as num) * 1000).round();
        final returned = ((item['returned_quantity'] as num) * 1000).round();
        final lineTotal = ((item['total'] as num) * 100).round();
        final returnedCents = ((item['returned_amount'] as num) * 100).round();
        if (quantity > sold - returned) throw const PosException('FA892');
        final amount = quantity == sold - returned ? lineTotal - returnedCents : (lineTotal * quantity / sold).round();
        totalCents += amount;
        items.add({'id': uuid.v7(), 'sale_item_id': item['id'], 'quantity': quantity / 1000, 'amount': amount / 100});
        printed.add((name: '${item['product_code']} ${item['product_name']}', quantityMilli: quantity, amountCents: amount));
      }
      if (items.isEmpty || totalCents <= 0) throw const PosException('FA871');
      LocalUser? authorizer;
      if (returnNeedsAuthorization(sale)) {
        if (sale['late'] == true && code.trim().isEmpty) throw const PosException('FA898');
        authorizer = await auth.verify(code, pin);
        if (authorizer.id == current.id || !authorizer.can('sales.return')) throw const PosException('FA895');
      }
      final now = _clock();
      final number = database.nextReturnNumber;
      final documentCode = 'D${terminalNumber() ?? 0}-${number.toString().padLeft(6, '0')}';
      final id = uuid.v7();
      database.saveReturn({
        'id': id,
        'number': number,
        'cash_session_id': open.id,
        'sale_id': sale['id'],
        'operator_id': current.id,
        'authorized_by': authorizer?.id,
        'reason': reason.trim(),
        'destination': destination,
        'returned_at': now.toUtc().toIso8601String(),
        'items': items,
        'total': totalCents / 100,
      }, code: documentCode, saleCode: sale['code'] as String, now: now);
      logger?.info('Devolução registrada', fields: {
        'return_code': documentCode,
        'destination': destination,
        'items': items.length,
        if (authorizer != null) 'authorizer_code': authorizer.code,
      });
      info = 'Devolução $documentCode registrada: ${formatCents(totalCents)}, ${returnDestinationLabels[destination]!.toLowerCase()}.';
      onSaleSaved?.call();
      final lines = buildReturnReceipt(
        fiscal: database.fiscal,
        code: documentCode,
        saleCode: sale['code'] as String,
        items: printed,
        totalCents: totalCents,
        destination: destination,
        reason: reason.trim(),
        operatorName: current.name,
        authorizerName: authorizer?.name,
        at: now,
        terminalNumber: terminalNumber() ?? 0,
      );
      busy = false;
      await _printLines(documentCode, lines);
      return (id: id, code: documentCode, totalCents: totalCents, destination: destination);
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return null;
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

  Future<void> _recordMovement(String kind, int amountCents, String reason, LocalUser current, LocalUser? releaser, {String? returnId}) async {
    final now = _clock();
    database.recordCashMovement(
      sessionId: session!.id,
      kind: kind,
      amountCents: amountCents,
      reason: reason.trim(),
      operatorId: current.id,
      releasedBy: releaser?.id,
      returnId: returnId,
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
    final current = actor;
    if (current == null) return DiscountNeed.none;
    try {
      final need = checkDiscount(line: line, discountCents: discountCents, operator: current, now: _clock());
      if (need == DiscountNeed.none) {
        line.setDiscount(discountCents);
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
    final current = actor;
    if (current == null || busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      if (reason.trim().isEmpty) throw const PosException('FA978');
      final supervisor = await auth.verify(code, pin);
      checkSupervisor(line: line, discountCents: discountCents, operator: current, supervisor: supervisor, now: _clock());
      line.setDiscount(discountCents);
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
      reprice();
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
    reprice();
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
    reprice();
    notifyListeners();
  }

  void remove(CartLine line) {
    cart.lines.remove(line);
    cart.payments.clear();
    reprice();
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
    if (payment.method == PaymentMethod.returnCredit) {
      final returnId = payment.returnId;
      final balance = payment.creditBalanceCents;
      if (returnId == null || balance == null) return _fail('FA872');
      if (cart.creditInCart(returnId) + payment.amountCents > balance) return _fail('FA873');
    }
    reprice();
    cart.payments.add(payment);
    notice = null;
    notifyListeners();
  }

  void removePayment(Payment payment) {
    cart.payments.remove(payment);
    reprice();
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

  /// Conclui o orçamento: grava, põe na outbox e imprime o cupom (se pedido). A plaquinha é opcional,
  /// mas sem ela o cupom sai sempre.
  Future<bool> finishQuote({int? cardNumber, bool printCoupon = true}) async {
    if (!quoteMode || busy) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final now = _clock();
      final draft = buildQuote(
        cart: cart,
        number: database.nextQuoteNumber,
        terminalNumber: terminalNumber() ?? 0,
        now: now,
        cardNumber: cardNumber,
      );
      database.saveQuote(draft.payload, code: draft.code, now: now);
      final local = now.toLocal();
      final validUntil = DateTime(local.year, local.month, local.day).add(Duration(days: database.quoteValidityDays));
      final lines = buildQuoteReceipt(
        fiscal: database.fiscal,
        quoteCode: draft.code,
        quotedAt: now,
        validUntil: validUntil,
        cart: cart,
        cardNumber: cardNumber,
      );
      lastQuote = CompletedSale(code: draft.code, totalCents: cart.totalCents, changeCents: 0, lines: lines);
      logger?.info('Orçamento concluído', fields: {
        'quote_code': draft.code,
        'items': cart.lines.length,
        'seller_code': cart.seller?.code,
        'card': cardNumber != null,
      });
      cart.clear();
      info = cardNumber == null
          ? 'Orçamento ${draft.code} concluído.'
          : 'Orçamento ${draft.code} concluído na plaquinha $cardNumber.';
      onSaleSaved?.call();
      if (printCoupon || cardNumber == null) await _print(lastQuote!);
      return true;
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> reprint() async {
    final sale = quoteMode ? lastQuote : lastSale;
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
