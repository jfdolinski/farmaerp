import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/error_display.dart';
import '../core/local_logger.dart';
import '../customers/customer_service.dart';
import '../face/face_math.dart' show templateBytes;
import '../face/face_service.dart';
import '../fiscal/danfe_a4.dart';
import '../fiscal/nfce_emitter.dart';
import '../local/local_database.dart';
import '../terminal/terminal_api.dart';
import 'cart.dart';
import 'cash.dart';
import 'controlled.dart';
import 'credit.dart';
import 'credit_engine.dart';
import 'danfe_printer.dart';
import 'discount.dart';
import 'discount_engine.dart';
import 'money.dart';
import 'pos_auth.dart';
import 'receipt.dart';

/// Venda concluída, para a tela e a reimpressão.
class CompletedSale {
  const CompletedSale({required this.code, required this.totalCents, required this.changeCents, required this.lines, this.saleId});

  final String code;
  /// Id da venda (para cancelar a NFC-e dela). Vazio no orçamento.
  final String? saleId;
  final int totalCents;
  final int changeCents;
  final List<ReceiptLine> lines;
}

/// Produto sem estoque esperando a autorização do gerente (PDV sem internet há bastante tempo).
class PendingZeroStock {
  const PendingZeroStock({required this.product, required this.quantityMilli, this.minutesOffline});

  final SaleProduct product;
  final int quantityMilli;

  /// Minutos sem sincronizar, quando o terminal está sem internet há mais que o tempo da filial.
  final int? minutesOffline;
}

/// Controlado da venda esperando a receita e a liberação do farmacêutico (pedidas ao finalizar).
class PendingControlled {
  const PendingControlled({required this.line});

  final CartLine line;

  SaleProduct get product => line.product;
  int get quantityMilli => line.quantityMilli;

  PrescriptionType get suggestedType => PrescriptionType.forClass(product.controlledClass!);
}

/// Estado do caixa: quem está operando, o turno, a venda em montagem e o pagamento.
class PosController extends ChangeNotifier {
  /// Emissão da NFC-e (null: o caixa não emite, como no orçamento).
  final NfceEmitter? nfce;

  PosController({
    this.nfce,
    required this.database,
    required this.auth,
    required this.printer,
    required this.terminalNumber,
    this.onSaleSaved,
    this.onShiftClosed,
    this.customers,
    this.networkStock,
    this.openQuotes,
    this.findQuote,
    this.saleForReturn,
    this.returnDocument,
    this.returnCredit,
    this.cashbackBalance,
    this.cashbackReserve,
    this.cashbackRelease,
    this.pbmPrograms,
    this.pbmAuthorize,
    this.pbmConfirm,
    this.pbmUndo,
    this.cancelNfce,
    this.danfePrinter,
    this.syncNow,
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

  /// Cashback na central (só com internet): saldo, reserva do uso e liberação.
  final Future<Map<String, dynamic>> Function(String customerId)? cashbackBalance;
  final Future<Map<String, dynamic>> Function(String customerId, double amount, double saleTotal)? cashbackReserve;
  final Future<void> Function(String reservationId)? cashbackRelease;

  /// PBM pela central (só com internet): programas da loja, autorização, confirmação e desfazer.
  final Future<List<Map<String, dynamic>>> Function()? pbmPrograms;
  final Future<Map<String, dynamic>> Function(String programId, String beneficiary, List<Map<String, Object?>> items)? pbmAuthorize;
  final Future<void> Function(String authorizationId, String saleId)? pbmConfirm;
  final Future<void> Function(String authorizationId, String reason)? pbmUndo;

  /// Pede à central o cancelamento da NFC-e (id da nota, motivo, supervisor). Com internet.
  final Future<Map<String, dynamic>> Function(String documentId, String reason, String supervisorId)? cancelNfce;

  /// Impressão do DANFE A4 da NF-e de venda (null: o caixa não imprime A4).
  final DanfePrinter? danfePrinter;

  /// Último DANFE guardado (para a tela oferecer abrir de novo).
  String? lastDanfePath;

  /// A NF-e de venda (modelo 55) pode ser escolhida: o caixa emite nota, tem série 55 e o cliente da
  /// venda é PJ com cadastro completo.
  bool get nfeAvailable {
    final customer = cart.customer;
    if (nfce?.enabled != true || customer == null || database.nextFiscalNumber('55') == null) return false;
    return nfeRecipientOf(database.customerById(customer.id)) != null;
  }

  /// Troca o documento da venda entre NFC-e (65) e NF-e (55). A NF-e só quando disponível.
  void setFiscalModel(String model) {
    if (model == '55' && !nfeAvailable) return _fail('FA784');
    cart.fiscalModel = model == '55' ? '55' : '65';
    notice = null;
    notifyListeners();
  }

  /// Documento que já vem marcado para o cliente escolhido: NF-e para o contribuinte do ICMS (com
  /// IE), quando disponível; senão NFC-e.
  String _defaultFiscalModel() {
    final customer = cart.customer;
    if (customer == null || !nfeAvailable) return '65';
    return nfeRecipientOf(database.customerById(customer.id))?.ieIndicator == 1 ? '55' : '65';
  }
  /// Sincroniza agora (manda a fila para a central).
  final Future<void> Function()? syncNow;

  /// Controlados do orçamento esperando a receita, um por vez.
  /// Pagamento pedido com controlado sem receita: depois do último liberado, segue para o pagamento.
  bool _payAfterControlled = false;

  /// Controlado esperando a receita e o farmacêutico.
  PendingControlled? pendingControlled;

  final LocalDatabase database;
  final PosAuth auth;

  /// Rosto no PDV (câmera e modelos), quando o terminal tem: entrada e liberações pela câmera.
  FaceService? face;

  /// Impressora em uso (muda pela configuração do terminal).
  ReceiptPrinter Function() printer;

  /// Número do terminal, que forma o código da venda.
  final int? Function() terminalNumber;

  /// Chamado depois de gravar a venda: adianta o envio, sem esperar o próximo sinal de vida.
  final void Function()? onSaleSaved;

  /// Chamado depois do fechamento de caixa (momento seguro para a atualização automática).
  final Future<void> Function()? onShiftClosed;
  final LocalLogger? logger;
  final DateTime Function() _clock;

  LocalUser? operator;
  LocalCashSession? session;

  /// Terminal de orçamento: sem entrada de operador nem turno; cada orçamento é do vendedor.
  bool get quoteMode => database.terminalProfile == 'quote';

  /// Quem responde pelos limites de desconto: no caixa, o operador; no orçamento, o vendedor.
  LocalUser? get actor => quoteMode ? cart.seller : operator;

  /// Tela bloqueada (fundo preto) depois de concluir a venda ou o orçamento, até identificar o
  /// vendedor do próximo atendimento. Terminal com vendedor padrão não bloqueia.
  bool sellerLock = false;

  /// Depois de concluir: o vendedor padrão já entra; sem ele, bloqueia pedindo o vendedor.
  void _lockForNextSeller() {
    _applyFixedSeller();
    sellerLock = cart.seller == null;
  }

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
      sellerLock = false;
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
    sellerLock = false;
    pendingControlled = null;
    _payAfterControlled = false;
    pendingZeroStock = null;
    _releaseCashback(cart.payments.where((payment) => payment.method == PaymentMethod.cashback));
    _undoPbm('Operador saiu do caixa');
    saleCashback = null;
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
      final quantity = product.barcodeFractionMilli == null
          ? quantityMilli
          : (quantityMilli * product.barcodeFractionMilli! / 1000).round();
      // Estoque negativo (por encomenda e controlado têm regra própria): quem tem "Vender com estoque
      // negativo" segue; quem não tem chama o supervisor. No autoatendimento, sempre o supervisor.
      if (_stockShort(product, quantity)) {
        final user = actor;
        if (!stockReleaseAlwaysAsks && user != null && user.can('sales.zero_stock_release')) {
          final same = cart.lines.where((line) =>
              line.product.id == product.id && line.zeroStockRelease?.supervisorId == user.id && line.quoteId == null &&
              line.manualDiscountCents == 0 && line.controlled == null && !line.needsStockRelease).firstOrNull;
          if (same != null) {
            same.quantityMilli += quantity;
            reprice();
            results = const [];
            notice = null;
            notifyListeners();
            return;
          }
          final line = cart.add(product, quantityMilli: quantityMilli, quote: quoteMode, merge: false);
          line.zeroStockRelease = (
            supervisorId: user.id,
            supervisorName: user.name,
            minutesOffline: _offlineMinutes,
            stockMilli: product.stockMilli,
          );
          reprice();
          results = const [];
          notice = null;
          notifyListeners();
          return;
        }
        pendingZeroStock = PendingZeroStock(product: product, quantityMilli: quantityMilli, minutesOffline: _offlineMinutes);
        results = const [];
        notice = null;
        notifyListeners();
        return;
      }
      // No orçamento, o controlado entra sem a receita: ela é do caixa.
      cart.add(product, quantityMilli: quantityMilli, quote: quoteMode);
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

  /// O item deixaria o estoque negativo? Por encomenda, controlado (o lote é conferido na receita) e
  /// sem preço ficam de fora.
  bool _stockShort(SaleProduct product, int quantityMilli) =>
      product.status != 'on_order' && product.controlledClass == null && product.priceCents != null &&
      product.stockMilli - cart.quantityOf(product.id) - quantityMilli < 0;

  /// Minutos sem sincronizar, só quando passa do tempo da filial (o terminal está sem internet).
  int? get _offlineMinutes {
    final minutes = minutesWithoutSync;
    return minutes != null && minutes >= offlineZeroStockMinutes ? minutes : null;
  }

  /// No autoatendimento quem está na tela é o cliente: a liberação pede sempre o código e o PIN.
  bool get stockReleaseAlwaysAsks => screen == 'self_service';

  /// Quem tem "Vender com estoque negativo" libera com o código e o PIN (no caixa ou no orçamento).
  Future<void> approveZeroStock(String code, String pin) async {
    final pending = pendingZeroStock;
    if (pending == null || busy) return;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final supervisor = await auth.verify(code, pin);
      if (!supervisor.can('sales.zero_stock_release')) throw const PosException('FA981');
      final line = cart.add(pending.product, quantityMilli: pending.quantityMilli, quote: quoteMode, merge: false);
      line.zeroStockRelease = (
        supervisorId: supervisor.id,
        supervisorName: supervisor.name,
        minutesOffline: pending.minutesOffline,
        stockMilli: pending.product.stockMilli,
      );
      reprice();
      pendingZeroStock = null;
      logger?.warn('Venda com estoque negativo liberada', fields: {
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
  /// Contexto da venda para os descontos automáticos, com outras formas de pagamento se pedido.
  DiscountContext _discountContext({List<String>? methods}) {
    final now = _clock();
    final local = now.toLocal();
    final customer = cart.customer;
    return DiscountContext(
      at: now,
      today: DateTime(local.year, local.month, local.day),
      branchId: (database.fiscal?['branch'] as Map?)?['id'] as String?,
      paymentMethods: methods ?? [for (final payment in cart.payments) payment.method.code],
      hasCustomer: customer != null,
      customerGroupId: customer?.groupId,
      customerBirthDate: customer?.birthDate,
      agreementIds: [
        for (final payment in cart.payments)
          if (payment.agreementId != null) payment.agreementId!,
      ],
      coupon: cart.coupon,
    );
  }

  List<DiscountLine> get _discountLines => [
    for (var index = 0; index < cart.lines.length; index += 1)
      DiscountLine(
        line: index + 1,
        quantityMilli: cart.lines[index].quantityMilli,
        unitPriceCents: cart.lines[index].unitPriceCents,
        subject: cart.lines[index].product.discountSubject.isEmpty
            ? {'id': cart.lines[index].product.id}
            : cart.lines[index].product.discountSubject,
      ),
  ];

  /// Refaz os descontos automáticos da venda (motor de regras, igual à central).
  void applyAutoDiscounts() {
    final result = calculateDiscounts(database.discountRules, _discountLines, _discountContext());
    for (var index = 0; index < cart.lines.length; index += 1) {
      final line = cart.lines[index];
      line.autoDiscountCents = line.pbm == null ? result[index].totalCents : 0;
      line.autoApplied = line.pbm == null ? result[index].applied : const [];
    }
  }

  /// Quanto falta se o resto for pago nesta forma (o desconto pela forma de pagamento já conta).
  int remainingIfPaidWith(PaymentMethod method) {
    final methods = [for (final payment in cart.payments) payment.method.code, method.code];
    final result = calculateDiscounts(database.discountRules, _discountLines, _discountContext(methods: methods));
    var total = 0;
    for (var index = 0; index < cart.lines.length; index += 1) {
      final line = cart.lines[index];
      final sum = result[index].totalCents + line.manualDiscountCents;
      total += line.grossCents - (sum > line.grossCents ? line.grossCents : sum);
    }
    final remaining = total - cart.paidCents;
    return remaining > 0 ? remaining : 0;
  }

  /// Cupom digitado no caixa: vale se algum desconto de cupom passar a valer; senão, FA832.
  bool applyCoupon(String code) {
    final value = code.trim().toUpperCase();
    cart.coupon = value.isEmpty ? null : value;
    reprice();
    if (value.isNotEmpty && !cart.lines.any((line) => line.autoApplied.any((applied) => applied.kind == 'coupon'))) {
      cart.coupon = null;
      reprice();
      _fail('FA832');
      return false;
    }
    notice = null;
    notifyListeners();
    return true;
  }

  void reprice() {
    final before = cart.totalCents;
    for (final line in cart.lines) {
      final current = database.saleProductById(line.product.id);
      if (current?.priceCents != null) line.unitPriceCents = current!.priceCents!;
      final rate = line.discountRate;
      if (rate != null) line.manualDiscountCents = math.min(line.grossCents, (line.grossCents * rate).round());
    }
    _checkPbm();
    applyAutoDiscounts();
    if (cart.totalCents != before && cart.payments.isNotEmpty) {
      _clearPayments();
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
  Future<bool> loadQuote(String key) => loadQuotes([key]);

  /// Puxa um ou mais orçamentos para a mesma venda. Cada item fica com o vendedor e o orçamento de
  /// origem; o vendedor da venda é o do primeiro, e o cliente, o do primeiro que tiver cliente. Item
  /// sem estoque: vale a liberação feita no orçamento; sem ela, quem tem a permissão libera ao puxar,
  /// e os outros esperam a liberação antes do pagamento.
  Future<bool> loadQuotes(List<String> keys) async {
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
    final quotes = <Map<String, dynamic>>[];
    try {
      final seen = <String>{};
      for (final key in keys) {
        final found = await lookup(key.trim());
        if (seen.add(found['id'] as String)) quotes.add(found);
      }
      if (quotes.isEmpty) return false;
      final skipped = <String>[];
      final quoteDiscounts = <CartLine, double>{};
      final first = quotes.first;
      final firstSeller = first['seller_id'] as String?;
      cart.seller = firstSeller == null ? null : database.userById(firstSeller);
      cart.quoteId = first['id'] as String;
      cart.quoteCode = [for (final quote in quotes) quote['code'] as String].join(', ');
      final merged = quotes.length > 1;
      final now = _clock();
      for (final data in quotes) {
      final seller = data['seller_id'] == null ? null : database.userById(data['seller_id'] as String);
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
        // Sem estoque: a liberação do orçamento vale; sem ela, quem tem a permissão libera agora e os
        // outros liberam antes de pagar.
        final short = _stockShort(product, quantity);
        final quoted = item['zero_stock_release'] as Map<String, dynamic>?;
        final discount = (item['discount'] as num?) ?? 0;
        final line = cart.add(product, quantityMilli: quantity, merge: false);
        line.quoteId = data['id'] as String;
        line.sellerId = seller?.id ?? data['seller_id'] as String?;
        if (merged) line.sellerName = seller?.name;
        if (short && quoted != null) {
          final supervisorId = quoted['supervisor_id'] as String;
          line.zeroStockRelease = (
            supervisorId: supervisorId,
            supervisorName: database.userById(supervisorId)?.name ?? 'supervisor',
            minutesOffline: null,
            stockMilli: quoted['stock'] == null ? null : ((quoted['stock'] as num) * 1000).round(),
          );
        } else if (short && !stockReleaseAlwaysAsks && current.can('sales.zero_stock_release')) {
          line.zeroStockRelease = (
            supervisorId: current.id,
            supervisorName: current.name,
            minutesOffline: _offlineMinutes,
            stockMilli: product.stockMilli,
          );
        } else if (short) {
          line.needsStockRelease = true;
        }
        if (discount > 0) {
          // O desconto do orçamento (na mesma fração, com o preço de agora) inclui os automáticos:
          // o manual é o que passa deles.
          final gross = (item['quantity'] as num) * (item['unit_price'] as num);
          if (gross > 0) quoteDiscounts[line] = discount / gross;
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
      }
      reprice();
      for (final entry in quoteDiscounts.entries) {
        final manual = (entry.key.grossCents * entry.value).round() - entry.key.autoDiscountCents;
        entry.key.setDiscount(manual > 0 ? math.min(manual, entry.key.grossCents) : 0);
      }
      // Sem liberação, o desconto do orçamento fica no que o operador pode dar sozinho.
      for (final line in cart.lines) {
        if (line.manualDiscountCents == 0 || line.release != null) continue;
        if (checkDiscount(line: line, discountCents: line.manualDiscountCents, operator: current, now: now) == DiscountNeed.none) continue;
        final limit = discountLimitBp(current) ?? 10000;
        final rule = current.can('sales.discount_override') ? 10000 : (line.product.maxDiscountAt(now) ?? 10000);
        line.setDiscount((line.grossCents * math.min(limit, rule) / 10000).floor());
      }
      // O cliente do primeiro orçamento (na ordem escolhida) que tiver cliente.
      final customerId = quotes.map((quote) => quote['customer_id'] as String?).whereType<String>().firstOrNull;
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
            groupId: customer['customer_group_id'] as String?,
            birthDate: customer['birth_date'] as String?,
            credit: CreditAccount.fromJson(customer['credit']),
            abcCurve: customer['abc_curve'] as String?,
          );
          reprice();
        } on ApiException {
          skipped.add('o cliente (identifique de novo)');
        }
      }
      final waiting = linesNeedingStockRelease.length;
      info = '${merged ? 'Orçamentos' : 'Orçamento'} ${cart.quoteCode} ${merged ? 'carregados' : 'carregado'}.'
          '${skipped.isEmpty ? '' : ' Ficou de fora: ${skipped.join('; ')}.'}'
          '${waiting == 0 ? '' : ' $waiting ${waiting == 1 ? 'item sem estoque precisa' : 'itens sem estoque precisam'} de liberação.'}';
      logger?.info('Orçamento puxado no caixa', fields: {'quotes': quotes.length, 'skipped': skipped.length, 'waiting_release': waiting});
      return true;
    } on ApiException catch (error) {
      cart.clear();
      notice = ErrorDisplay.fromCode(const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA890' : error.code, traceId: error.traceId);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Itens controlados que ainda não têm a receita (nem a liberação pendente).
  List<CartLine> get controlledWithoutRelease =>
      [for (final line in cart.lines) if (line.product.controlledClass != null && line.controlled == null) line];

  /// Próximo controlado sem receita; sem nenhum, segue para o pagamento se foi pedido.
  void _nextControlled() {
    final next = controlledWithoutRelease.firstOrNull;
    pendingControlled = next == null ? null : PendingControlled(line: next);
    if (next == null && _payAfterControlled) {
      _payAfterControlled = false;
      if (!cart.isEmpty) paying = true;
    }
  }

  /// Prescritores do cadastro (nome ou número no conselho), para preencher a receita.
  List<LocalProfessional> searchPrescribers(String term) => database.searchProfessionals(term);

  /// Prescritor da receita já está no cadastro (mesmo conselho, número e UF)?
  bool prescriberRegistered(PrescriptionForm form) =>
      database.professionalByRegistration(form.prescriberCouncil, form.prescriberNumber, form.prescriberState) != null;

  /// Cadastro rápido do prescritor digitado na receita. Sobe para a central pela outbox; já
  /// cadastrado devolve o que existe. Campos do prescritor com problema: FA734.
  LocalProfessional? registerPrescriber(PrescriptionForm form, {String? authorizedBy}) {
    final responsible = authorizedBy ?? actor?.id;
    if (responsible == null || (authorizedBy == null && !can('pdv.prescriber_create'))) {
      _fail('FA002');
      return null;
    }
    final errors = prescriptionErrors(form, _clock());
    if (const ['prescriberName', 'prescriberCouncil', 'prescriberNumber', 'prescriberState'].any(errors.containsKey)) {
      _fail('FA734');
      return null;
    }
    final existing = database.professionalByRegistration(form.prescriberCouncil, form.prescriberNumber, form.prescriberState);
    if (existing != null) return existing;
    final saved = database.saveProfessional(
      name: form.prescriberName,
      council: form.prescriberCouncil,
      registration: form.prescriberNumber,
      state: form.prescriberState,
      createdBy: responsible,
      now: _clock(),
    );
    notice = null;
    // Sem dados pessoais do paciente: só o registro do profissional.
    logger?.info('Prescritor cadastrado no caixa', fields: {'council': saved.council, 'state': saved.state});
    notifyListeners();
    return saved;
  }

  /// Receitas completas já lançadas em outros itens desta venda (para reaproveitar).
  List<CartLine> prescriptionSources(PendingControlled pending) => [
    for (final line in cart.lines)
      if (line != pending.line && line.controlled?.form != null) line,
  ];

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
      pending.line
        ..quantityMilli = quantityMilli
        ..controlled = release;
      _clearPayments();
      reprice();
      _nextControlled();
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
      pending.line
        ..quantityMilli = quantityMilli
        ..controlled = release;
      _clearPayments();
      reprice();
      _nextControlled();
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

  /// Volta aos itens sem preencher: o controlado continua na venda, marcado como sem receita.
  void cancelControlled() {
    pendingControlled = null;
    _payAfterControlled = false;
    notice = null;
    notifyListeners();
  }

  /// "Não vender": tira o controlado da venda e segue para o próximo (ou para o pagamento).
  void dropControlled() {
    final pending = pendingControlled;
    if (pending == null) return;
    cart.lines.remove(pending.line);
    _clearPayments();
    reprice();
    notice = null;
    _nextControlled();
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
      if (destination == 'store_credit' && sale['has_store_credit'] != true) throw const PosException('FA846');
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
      final cashbackRefundCents = returnCashbackRefundCents(sale, totalCents);
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
      }, code: documentCode, saleCode: sale['code'] as String, now: now, cashbackRefundCents: cashbackRefundCents);
      logger?.info('Devolução registrada', fields: {
        'return_code': documentCode,
        'destination': destination,
        'items': items.length,
        if (authorizer != null) 'authorizer_code': authorizer.code,
      });
      info = 'Devolução $documentCode registrada: ${formatCents(totalCents - cashbackRefundCents)}, ${returnDestinationLabels[destination]!.toLowerCase()}'
          '${cashbackRefundCents > 0 ? ', e ${formatCents(cashbackRefundCents)} volta como cashback' : ''}.';
      onSaleSaved?.call();
      final lines = buildReturnReceipt(
        fiscal: database.fiscal,
        code: documentCode,
        saleCode: sale['code'] as String,
        items: printed,
        totalCents: totalCents,
        destination: destination,
        reason: reason.trim(),
        cashbackRefundCents: cashbackRefundCents,
        operatorName: current.name,
        authorizerName: authorizer?.name,
        at: now,
        terminalNumber: terminalNumber() ?? 0,
      );
      busy = false;
      await _printLines(documentCode, lines);
      return (id: id, code: documentCode, totalCents: totalCents - cashbackRefundCents, destination: destination);
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ---- PBM ----

  /// Programas de benefício ligados na loja. Sem internet: FA797 (a venda segue pelo preço normal).
  Future<List<Map<String, dynamic>>?> loadPbmPrograms() async {
    final lookup = pbmPrograms;
    if (lookup == null) {
      _fail('FA797');
      return null;
    }
    try {
      return await lookup();
    } on ApiException catch (error) {
      _fail(_offline(error.code) ? 'FA797' : error.code);
      return null;
    }
  }

  static bool _offline(String code) => const {'FA001', 'FA008', 'FA009'}.contains(code);

  /// Consulta o programa com os itens da venda e aplica o preço dele nos itens aceitos. Um PBM por
  /// venda: aplicar de novo desfaz o anterior. O desconto do programa substitui os outros no item.
  Future<bool> applyPbm({required String programId, required String programName, required String beneficiary}) async {
    final authorize = pbmAuthorize;
    if (busy || quoteMode) return false;
    if (authorize == null) {
      _fail('FA797');
      return false;
    }
    if (cart.isEmpty) {
      _fail('FA796');
      return false;
    }
    final document = beneficiary.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
    if (document.length < 4 || document.length > 30) {
      _fail('FA005');
      return false;
    }
    _undoPbm('PBM consultado de novo');
    // Um item por produto: o primeiro da venda (o programa responde por produto).
    final byProduct = <String, CartLine>{};
    for (final line in cart.lines) {
      byProduct.putIfAbsent(line.product.id, () => line);
    }
    busy = true;
    notice = null;
    info = null;
    notifyListeners();
    try {
      final result = await authorize(programId, document, [
        for (final line in byProduct.values)
          {'productId': line.product.id, 'quantity': line.quantityMilli / 1000, 'unitPrice': line.unitPriceCents / 100},
      ]);
      int cents(Object? value) => (((value as num?) ?? 0) * 100).round();
      for (final item in ((result['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
        final line = byProduct[item['productId']];
        if (line == null) continue;
        line.pbm = PbmLine(
          quantityMilli: (((item['quantity'] as num?) ?? 0) * 1000).round(),
          listPriceCents: cents(item['listPrice']),
          pbmPriceCents: cents(item['pbmPrice']),
        );
        line.setDiscount(0);
        line.release = null;
      }
      cart.pbm = PbmSale(
        authorizationId: '${result['id']}',
        programName: programName,
        beneficiaryMasked: maskPbmDocument(document),
        externalId: result['externalId'] as String?,
      );
      busy = false;
      reprice();
      info = 'PBM $programName aplicado: economia de ${formatCents(cart.pbmBenefitCents)}.';
      logger?.info('PBM aplicado', fields: {'items': cart.lines.where((line) => line.pbm != null).length});
      return true;
    } on ApiException catch (error) {
      notice = ErrorDisplay.fromCode(_offline(error.code) ? 'FA797' : error.code, traceId: error.traceId);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Tira o PBM da venda (desfaz no programa); os itens voltam ao preço normal.
  void removePbm() {
    if (cart.pbm == null) return;
    _undoPbm('PBM retirado pelo operador');
    reprice();
    info = 'PBM retirado: os itens voltaram ao preço normal.';
    notifyListeners();
  }

  /// Desfaz a autorização no programa (sem esperar; sem internet, ela expira na central) e tira o
  /// preço do programa dos itens.
  void _undoPbm(String reason) {
    final current = cart.pbm;
    if (current == null) return;
    cart.pbm = null;
    for (final line in cart.lines) {
      line.pbm = null;
    }
    final undo = pbmUndo;
    if (undo == null || current.confirmedSaleId != null) return;
    unawaited(undo(current.authorizationId, reason).catchError((Object error) {
      logger?.warn('Autorização do PBM não desfeita', fields: {'error': '$error'});
    }));
  }

  /// O PBM vale para os itens como foram autorizados: item do programa retirado, com outra
  /// quantidade ou com outro preço desfaz o PBM da venda.
  void _checkPbm() {
    if (cart.pbm == null) return;
    final changed = cart.lines.every((line) => line.pbm == null) ||
        cart.lines.any((line) =>
            line.pbm != null && (line.pbm!.quantityMilli != line.quantityMilli || line.pbm!.listPriceCents != line.unitPriceCents));
    if (!changed) return;
    _undoPbm('Itens do PBM alterados');
    info = 'O PBM foi desfeito porque os itens do programa mudaram. Aplique de novo, se for o caso.';
  }

  /// Confirma o PBM com a venda antes de gravar. Sem internet ou com recusa, a venda continua aberta.
  Future<bool> _confirmPbm(String saleId) async {
    final current = cart.pbm;
    final confirm = pbmConfirm;
    if (current == null) return true;
    if (current.confirmedSaleId == saleId) return true;
    if (confirm == null) {
      notice = ErrorDisplay.fromCode('FA797');
      return false;
    }
    try {
      await confirm(current.authorizationId, saleId);
      current.confirmedSaleId = saleId;
      return true;
    } on ApiException catch (error) {
      notice = ErrorDisplay.fromCode(_offline(error.code) ? 'FA797' : error.code, traceId: error.traceId);
      return false;
    }
  }

  // ---- Cashback ----

  /// Cashback do cliente da venda, buscado na central (só com internet). Vazio: sem cliente, ainda
  /// não buscado ou sem internet ([cashbackOffline]).
  ({int availableCents, int waitingCents, bool consent, int maxUseBp, int waitingDays})? saleCashback;
  bool cashbackOffline = false;

  Future<void> loadCashback() async {
    final customer = cart.customer;
    final lookup = cashbackBalance;
    saleCashback = null;
    cashbackOffline = false;
    if (customer == null || lookup == null) return notifyListeners();
    try {
      final data = await lookup(customer.id);
      final policy = (data['policy'] as Map?)?.cast<String, dynamic>() ?? const {};
      saleCashback = (
        availableCents: (((data['available'] as num?) ?? 0) * 100).round(),
        waitingCents: (((data['waiting'] as num?) ?? 0) * 100).round(),
        consent: data['consent'] == true,
        maxUseBp: (((policy['max_use_percent'] as num?) ?? 50) * 100).round(),
        waitingDays: (policy['waiting_days'] as num?)?.toInt() ?? 0,
      );
    } on ApiException catch (error) {
      cashbackOffline = const {'FA001', 'FA008', 'FA009'}.contains(error.code);
    }
    notifyListeners();
  }

  int get cashbackInCartCents =>
      cart.payments.where((p) => p.method == PaymentMethod.cashback).fold(0, (sum, p) => sum + p.amountCents);

  /// Quanto ainda dá para pagar com cashback nesta venda: o saldo e o máximo da rede.
  int get cashbackUsableCents {
    final info = saleCashback;
    if (info == null || !info.consent) return 0;
    final max = (cart.totalCents * info.maxUseBp * 2 + 10000) ~/ 20000 - cashbackInCartCents;
    final balance = info.availableCents;
    final usable = max < balance ? max : balance;
    return usable > 0 ? usable : 0;
  }

  /// Ganho estimado nesta venda (a central confirma): percentual de cada item sobre o que foi pago
  /// sem cashback, arredondado no centavo como na central.
  int get cashbackEarnEstimateCents {
    final info = saleCashback;
    final total = cart.totalCents;
    if (info == null || !info.consent || total <= 0) return 0;
    var weighted = 0;
    for (final line in cart.lines) {
      weighted += line.totalCents * (line.product.cashbackBp ?? 0);
    }
    final paid = total - cashbackInCartCents;
    if (weighted <= 0 || paid <= 0) return 0;
    final numerator = weighted * paid;
    final denominator = 10000 * total;
    return (2 * numerator + denominator) ~/ (2 * denominator);
  }

  /// Reserva o cashback na central e lança o pagamento. Sem internet, não dá (FA855).
  Future<bool> addCashback(int amountCents) async {
    final customer = cart.customer;
    final reserve = cashbackReserve;
    if (busy) return false;
    try {
      if (customer == null) throw const PosException('FA983');
      if (reserve == null || cashbackOffline) throw const PosException('FA855');
      final info = saleCashback;
      if (info != null && !info.consent) throw const PosException('FA849');
      if (amountCents <= 0) throw const PosException('FA972');
      if (info != null && amountCents > cashbackUsableCents) {
        throw PosException(amountCents > info.availableCents ? 'FA850' : 'FA851');
      }
    } on PosException catch (error) {
      _fail(error.code);
      return false;
    }
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final result = await reserve(customer.id, amountCents / 100, cart.totalCents / 100);
      busy = false;
      addPayment(Payment(method: PaymentMethod.cashback, amountCents: amountCents, reservationId: '${result['reservation_id']}'));
      final info = saleCashback;
      if (info != null) {
        saleCashback = (
          availableCents: (((result['balance'] as num?) ?? 0) * 100).round(),
          waitingCents: info.waitingCents,
          consent: info.consent,
          maxUseBp: info.maxUseBp,
          waitingDays: info.waitingDays,
        );
      }
      return true;
    } on ApiException catch (error) {
      final offline = const {'FA001', 'FA008', 'FA009'}.contains(error.code);
      if (offline) cashbackOffline = true;
      notice = ErrorDisplay.fromCode(offline ? 'FA855' : error.code, traceId: error.traceId);
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Libera reservas de cashback (venda desistida). Sem internet, a central libera sozinha em 2 horas.
  void _releaseCashback(Iterable<Payment> payments) {
    final release = cashbackRelease;
    if (release == null) return;
    for (final payment in payments.toList()) {
      final id = payment.reservationId;
      if (id == null) continue;
      unawaited(release(id).catchError((Object error) {
        logger?.warn('Reserva de cashback não liberada', fields: {'error': '$error'});
      }));
      if (saleCashback case final info?) {
        saleCashback = (
          availableCents: info.availableCents + payment.amountCents,
          waitingCents: info.waitingCents,
          consent: info.consent,
          maxUseBp: info.maxUseBp,
          waitingDays: info.waitingDays,
        );
      }
    }
  }

  void _clearPayments() {
    _releaseCashback(cart.payments.where((payment) => payment.method == PaymentMethod.cashback));
    cart.payments.clear();
  }

  /// Parte do cashback numa devolução: a proporção acumulada do que já voltou da venda, para a soma
  /// das devoluções fechar no centavo com o que foi usado (a mesma conta da central).
  int returnCashbackRefundCents(Map<String, dynamic> sale, int returnCents) {
    int cents(Object? value) => (((value as num?) ?? 0) * 100).round();
    final used = cents(sale['cashback_used']);
    final total = cents(sale['total']);
    if (used <= 0 || total <= 0) return 0;
    final numerator = used * (cents(sale['returned_total']) + returnCents);
    final cumulative = (2 * numerator + total) ~/ (2 * total);
    final refund = cumulative - cents(sale['cashback_refunded']);
    return refund < 0 ? 0 : (refund > returnCents ? returnCents : refund);
  }

  // ---- Crediário ----

  /// Hoje em São Paulo, como a central conta os vencimentos.
  String get creditToday => saoPauloDay(_clock());

  /// Crediário de um cliente com o que este terminal ainda não enviou.
  CreditAccount? creditAccountOf(String customerId, CreditAccount? base) =>
      base?.withPending(database.pendingCreditEvents(customerId));

  /// Crediário do cliente da venda, hoje (sem o que já está lançado nesta venda).
  CreditSummary? get saleCredit {
    final customer = cart.customer;
    return customer == null ? null : creditAccountOf(customer.id, customer.credit)?.summary(creditToday);
  }

  /// Quanto desta venda já está lançado no crediário.
  int get creditInCartCents =>
      cart.payments.where((p) => p.method == PaymentMethod.storeCredit).fold(0, (sum, p) => sum + p.amountCents);

  /// Parcelas de um valor no crediário do cliente da venda, como a central vai calcular.
  List<ScheduledInstallment> creditPlan(int amountCents, int count) {
    final account = cart.customer?.credit;
    if (account == null || amountCents <= 0 || count < 1) return const [];
    return creditSchedule(account.terms, creditToday, amountCents, count);
  }

  /// O valor no crediário (com o que já está na venda) passa do limite do operador?
  bool creditNeedsRelease(int amountCents) {
    final current = operator;
    if (current == null) return false;
    final limit = creditSaleLimitCents(current);
    return limit != null && creditInCartCents + amountCents > limit;
  }

  void _checkCreditPayment(int amountCents, int count) {
    final customer = cart.customer;
    final account = customer == null ? null : creditAccountOf(customer.id, customer.credit);
    if (account == null) throw const PosException('FA834');
    if (account.blocked) throw const PosException('FA840');
    final summary = account.summary(creditToday);
    if (summary.blockedByOverdue) throw const PosException('FA841');
    if (count < 1 || count > account.policy.maxInstallments) throw const PosException('FA843');
    if (creditInCartCents + amountCents > summary.availableCents) throw const PosException('FA842');
  }

  /// Confere o crediário antes de pedir a liberação: o erro aparece na tela e devolve falso.
  bool checkCreditPayment(int amountCents, int count) {
    try {
      _checkCreditPayment(amountCents, count);
      return true;
    } on PosException catch (error) {
      _fail(error.code);
      return false;
    }
  }

  /// Quem libera a venda no crediário acima do limite do operador: outra pessoa, com limite que cubra.
  Future<({String supervisorId, String supervisorName, String reason})?> releaseCredit(
    int amountCents,
    String code,
    String pin,
    String reason,
  ) async {
    final current = operator;
    if (current == null || busy) return null;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final releaser = await auth.verify(code, pin);
      if (releaser.id == current.id) throw const PosException('FA845');
      final limit = creditSaleLimitCents(releaser);
      if (limit != null && creditInCartCents + amountCents > limit) throw const PosException('FA845');
      logger?.info('Crediário liberado acima do limite', fields: {'releaser_code': releaser.code});
      return (supervisorId: releaser.id, supervisorName: releaser.name, reason: reason.trim());
    } on PosException catch (error) {
      notice = ErrorDisplay.fromCode(error.code);
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Clientes com crediário guardados no terminal, para o recebimento.
  List<({String id, String name, int code})> creditCustomers(String query) => database.localCreditCustomers(query);

  /// Crediário do cliente para o recebimento: o que a central mandou mais o que ainda não subiu.
  ({String name, int code, CreditAccount account})? creditForReceipt(String customerId) {
    final row = database.customerById(customerId);
    final base = row == null ? null : CreditAccount.fromJson(row['credit']);
    final account = creditAccountOf(customerId, base);
    if (row == null || account == null) return null;
    return (name: row['name']! as String, code: row['code']! as int, account: account);
  }

  /// Recebe parcelas do crediário: grava na outbox e imprime o comprovante. O caixa precisa estar
  /// sem venda em andamento.
  Future<bool> receiveCredit({
    required String customerId,
    required int amountCents,
    required String method,
    String? cardBrand,
    String? authorizationCode,
  }) async {
    final current = operator;
    final open = session;
    if (current == null || open == null || busy || quoteMode) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      if (!cart.isEmpty || paying) throw const PosException('FA998');
      if (!countedMethods.containsKey(method)) throw const PosException('FA972');
      final found = creditForReceipt(customerId);
      if (found == null) throw const PosException('FA834');
      final today = creditToday;
      final summary = found.account.summary(today);
      if (amountCents <= 0) throw const PosException('FA972');
      if (amountCents > summary.totalOpenCents) throw const PosException('FA844');
      final allocation = creditAllocate(found.account.installments, amountCents, today, found.account.policy);
      final now = _clock();
      database.saveCreditPayment({
        'id': const Uuid().v7(),
        'cash_session_id': open.id,
        'customer_id': customerId,
        'received_by': current.id,
        'received_at': now.toUtc().toIso8601String(),
        'method': method,
        'amount': amountCents / 100,
        'card_brand': cardBrand?.trim().isEmpty ?? true ? null : cardBrand!.trim(),
        'authorization_code': authorizationCode?.trim().isEmpty ?? true ? null : authorizationCode!.trim(),
      }, now: now);
      final after = creditApplyPayment(found.account.installments, amountCents, today, found.account.policy);
      final remaining = after.fold(0, (sum, state) => sum + creditPosition(state, today, found.account.policy).totalCents);
      logger?.info('Recebimento do crediário', fields: {'customer_code': found.code, 'method': method});
      info = 'Recebimento de ${formatCents(amountCents)} do crediário de ${found.name} registrado.';
      onSaleSaved?.call();
      final lines = buildCreditPaymentReceipt(
        fiscal: database.fiscal,
        customerName: found.name,
        customerCode: found.code,
        amountCents: amountCents,
        methodLabel: countedMethods[method]!,
        chargesCents: allocation.allocations.fold(0, (sum, a) => sum + a.feeCents + a.interestCents),
        principalCents: allocation.allocations.fold(0, (sum, a) => sum + a.principalCents),
        remainingCents: remaining,
        nextDue: [for (final state in (after..sort((a, b) => a.dueDate.compareTo(b.dueDate))).take(3)) (dueDate: state.dueDate, openCents: state.principalOpenCents)],
        operatorName: current.name,
        at: now,
        terminalNumber: terminalNumber() ?? 0,
      );
      busy = false;
      await _printLines('crediario', lines);
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
    // Momento seguro para aplicar uma atualização já baixada.
    await onShiftClosed?.call();
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
    // O item do PBM fica com o preço do programa: outro desconto só tirando o PBM.
    if (line.pbm != null) {
      _fail('FA800');
      return DiscountNeed.none;
    }
    try {
      final need = checkDiscount(line: line, discountCents: discountCents, operator: current, now: _clock());
      if (need == DiscountNeed.none) {
        line.setDiscount(discountCents);
        line.release = null;
        _clearPayments();
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
      _clearPayments();
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
  /// Cadastra o cliente na tela de vendas e já o escolhe para a venda. Devolve o código do erro
  /// (null quando deu certo): sem internet, FA984 (a venda segue sem cliente).
  Future<String?> createCustomer({
    String name = '',
    String document = '',
    String? phone,
    DateTime? birthDate,
    CompanyCustomer? company,
    bool cashbackConsent = false,
    bool marketingConsent = false,
    String? authorizedBy,
  }) async {
    final service = customers;
    // Quem responde pelo cadastro: o supervisor que liberou, ou quem está no terminal (o vendedor no orçamento).
    final responsible = authorizedBy ?? actor?.id;
    if (service == null || responsible == null || busy) return 'FA000';
    if (authorizedBy == null && !can('pdv.customer_create')) {
      _fail('FA002');
      return 'FA002';
    }
    busy = true;
    notice = null;
    notifyListeners();
    String? id;
    try {
      String two(int value) => value.toString().padLeft(2, '0');
      id = await service.create(
        operatorId: responsible,
        name: name,
        document: document,
        phone: phone,
        birthDate: birthDate == null ? null : '${birthDate.year}-${two(birthDate.month)}-${two(birthDate.day)}',
        company: company,
        cashbackConsent: cashbackConsent,
        marketingConsent: marketingConsent,
      );
    } on ApiException catch (error) {
      final code = const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA984' : error.code;
      notice = ErrorDisplay.fromCode(code, traceId: error.traceId);
      return code;
    } finally {
      busy = false;
      notifyListeners();
    }
    await selectCustomer(id);
    return null;
  }

  /// Busca os dados públicos do CNPJ para o cadastro de pessoa jurídica (com internet). Devolve os
  /// dados ou o código do erro: sem internet, FA984; CNPJ não encontrado, FA907.
  Future<({CompanyCustomer? data, String? code})> lookupCnpj(String cnpj, {String? authorizedBy}) async {
    final service = customers;
    final responsible = authorizedBy ?? actor?.id;
    if (service == null || responsible == null) return (data: null, code: 'FA000');
    if (authorizedBy == null && !can('pdv.customer_create')) return (data: null, code: 'FA002');
    try {
      return (data: await service.lookupCnpj(operatorId: responsible, cnpj: cnpj), code: null);
    } on ApiException catch (error) {
      return (data: null, code: const {'FA001', 'FA008', 'FA009'}.contains(error.code) ? 'FA984' : error.code);
    }
  }

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
        groupId: data['customer_group_id'] as String?,
        birthDate: data['birth_date'] as String?,
        credit: CreditAccount.fromJson(data['credit']),
        abcCurve: data['abc_curve'] as String?,
      );
      cart.fiscalModel = _defaultFiscalModel();
      // Cliente novo: o cashback do anterior não vale; reservas dele são liberadas.
      _releaseCashback(cart.payments.where((payment) => payment.method == PaymentMethod.cashback));
      cart.payments.removeWhere((payment) => payment.method == PaymentMethod.cashback);
      saleCashback = null;
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
    cart.fiscalModel = '65';
    saleCashback = null;
    _releaseCashback(cart.payments.where((payment) => payment.method == PaymentMethod.cashback));
    cart.payments.removeWhere((payment) =>
        payment.method == PaymentMethod.agreement || payment.method == PaymentMethod.storeCredit || payment.method == PaymentMethod.cashback);
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
    final extra = quantityMilli - line.quantityMilli;
    final short = extra > 0 && _stockShort(line.product, extra);
    line.quantityMilli = quantityMilli;
    if (short) {
      final user = actor;
      if (!stockReleaseAlwaysAsks && user != null && user.can('sales.zero_stock_release')) {
        line.needsStockRelease = false;
        line.zeroStockRelease = (
          supervisorId: user.id,
          supervisorName: user.name,
          minutesOffline: _offlineMinutes,
          stockMilli: line.product.stockMilli,
        );
      } else {
        // Sem a permissão: o item espera a liberação (botão "Liberar estoque negativo") antes de fechar.
        line.zeroStockRelease = null;
        line.needsStockRelease = true;
        info = '${line.product.name}: o estoque fica negativo e precisa de liberação.';
      }
    }
    reprice();
    notifyListeners();
  }

  void remove(CartLine line) {
    if (pendingControlled?.line == line) {
      pendingControlled = null;
      _payAfterControlled = false;
    }
    cart.lines.remove(line);
    _clearPayments();
    reprice();
    notifyListeners();
  }

  /// Finalizar: antes do pagamento, a receita (ou a liberação) de cada controlado, um por vez.
  /// Itens que vieram de orçamento sem estoque e ainda esperam a liberação.
  List<CartLine> get linesNeedingStockRelease => [for (final line in cart.lines) if (line.needsStockRelease) line];

  /// Libera de uma vez os itens sem estoque que vieram dos orçamentos (código e PIN de quem tem
  /// "Vender com estoque negativo"). Devolve true quando liberou.
  Future<bool> releasePendingStock(String code, String pin) async {
    final lines = linesNeedingStockRelease;
    if (lines.isEmpty || busy) return false;
    final supervisor = await authorize('sales.zero_stock_release', code, pin, allowSelf: true);
    if (supervisor == null) return false;
    for (final line in lines) {
      line.needsStockRelease = false;
      line.zeroStockRelease = (
        supervisorId: supervisor.id,
        supervisorName: supervisor.name,
        minutesOffline: _offlineMinutes,
        stockMilli: line.product.stockMilli,
      );
    }
    logger?.warn('Venda com estoque negativo liberada', fields: {'items': lines.length, 'supervisor_code': supervisor.code});
    notice = null;
    notifyListeners();
    return true;
  }

  void startPayment() {
    if (cart.isEmpty) return;
    if (linesNeedingStockRelease.isNotEmpty) return _fail('FA760');
    if (controlledWithoutRelease.isNotEmpty) {
      _payAfterControlled = true;
      notice = null;
      _nextControlled();
      notifyListeners();
      return;
    }
    paying = true;
    notice = null;
    notifyListeners();
  }

  void backToItems() {
    paying = false;
    _clearPayments();
    notifyListeners();
  }

  /// Quanto do limite do convênio o cliente ainda tem neste terminal: limite menos o usado que a
  /// central mandou, as vendas no convênio que ela ainda não conhece e o que já está no carrinho.
  /// Null quando o cliente não tem este convênio.
  int? agreementAvailableCents(String agreementId) {
    final customer = cart.customer;
    if (customer == null) return null;
    final agreement = customer.agreements.where((a) => a['agreement_id'] == agreementId).firstOrNull;
    if (agreement == null) return null;
    final limit = (((agreement['credit_limit'] as num?) ?? 0) * 100).round();
    final used = (((agreement['used'] as num?) ?? 0) * 100).round();
    final inCart = cart.payments
        .where((p) => p.method == PaymentMethod.agreement && p.agreementId == agreementId)
        .fold(0, (sum, p) => sum + p.amountCents);
    return limit - used - database.pendingAgreementCents(customer.id, agreementId) - inCart;
  }

  void addPayment(Payment payment) {
    if (payment.amountCents <= 0) return _fail('FA972');
    if (payment.method == PaymentMethod.agreement && cart.customer == null) return _fail('FA983');
    if (payment.method == PaymentMethod.agreement) {
      final available = agreementAvailableCents(payment.agreementId ?? '');
      if (available != null && payment.amountCents > available) return _fail('FA859');
    }
    if (payment.method == PaymentMethod.storeCredit) {
      try {
        if (creditNeedsRelease(payment.amountCents) && payment.creditRelease == null) throw const PosException('FA845');
        _checkCreditPayment(payment.amountCents, payment.installments?.length ?? 0);
      } on PosException catch (error) {
        return _fail(error.code);
      }
    }
    if (payment.method == PaymentMethod.returnCredit) {
      final returnId = payment.returnId;
      final balance = payment.creditBalanceCents;
      if (returnId == null || balance == null) return _fail('FA872');
      if (cart.creditInCart(returnId) + payment.amountCents > balance) return _fail('FA873');
    }
    reprice();
    cart.payments.add(payment);
    // Desconto pela forma de pagamento (ou pelo convênio) passa a valer com o pagamento lançado.
    applyAutoDiscounts();
    notice = null;
    notifyListeners();
  }

  void removePayment(Payment payment) {
    if (payment.method == PaymentMethod.cashback) _releaseCashback([payment]);
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
        saleId: cart.pbm?.confirmedSaleId,
      );
      final saleId = draft.payload['id']! as String;
      if (!await _confirmPbm(saleId)) return;
      final LocalNfce? document;
      String? noticeCode;
      if (cart.fiscalModel == '55') {
        // NF-e de venda: emitida antes de gravar. Sem comunicação com a Sefaz ou recusada, a venda
        // continua aberta: o operador tenta de novo ou troca para NFC-e.
        final emitter = nfce;
        if (emitter == null || !nfeAvailable) throw const PosException('FA784');
        final outcome = await emitter.emitNfe(saleId: saleId, cart: cart);
        if (outcome.blocked) {
          notice = ErrorDisplay.fromCode(outcome.blockCode!);
          if (outcome.blockCode == 'FA782' && outcome.detail != null) notice = notice!.withDetail('Sefaz: ${outcome.detail}');
          return;
        }
        database.saveSale(draft.payload, code: draft.code, itemRows: draft.itemRows, now: now);
        document = outcome.nfe;
        noticeCode = outcome.noticeCode;
      } else {
        database.saveSale(draft.payload, code: draft.code, itemRows: draft.itemRows, now: now);
        // NFC-e: emitida direto na Sefaz depois de a venda estar guardada. O que der errado vira
        // aviso, e a venda fica com a nota pendente.
        final emitted = await nfce?.emit(saleId: saleId, cart: cart);
        document = emitted?.nfce;
        noticeCode = emitted?.noticeCode;
      }
      if (document != null) database.saveNfce(document, now: now);
      final lines = buildReceipt(
        fiscal: database.fiscal,
        saleCode: draft.code,
        soldAt: now,
        customer: cart.customer,
        operatorName: current.name,
        cart: cart,
        terminalNumber: terminalNumber() ?? 0,
        cashbackEarnedCents: cashbackEarnEstimateCents,
        pbm: cart.pbm == null ? null : (programName: cart.pbm!.programName, beneficiary: cart.pbm!.beneficiaryMasked,
            externalId: cart.pbm!.externalId, benefitCents: cart.pbmBenefitCents),
        cashbackWaitingDays: saleCashback?.waitingDays ?? 0,
        nfce: document,
      );
      saleCashback = null;
      lastSale = CompletedSale(
        code: draft.code,
        totalCents: cart.totalCents,
        changeCents: cart.changeCents,
        lines: lines,
        saleId: saleId,
      );
      lastSaleCanceled = false;
      logger?.info('Venda concluída', fields: {'sale_code': draft.code, 'items': cart.lines.length});
      cart.clear();
      _lockForNextSeller();
      paying = false;
      info = document?.authorized ?? false
          ? 'Venda ${draft.code} concluída. ${document!.isNfe ? 'NF-e' : 'NFC-e'} ${document.number} autorizada.'
          : 'Venda ${draft.code} concluída.';
      if (noticeCode != null) notice = ErrorDisplay.fromCode(noticeCode);
      onSaleSaved?.call();
      await _print(lastSale!);
      if (document != null && document.isNfe && document.authorized) await printDanfe(document);
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
    if (linesNeedingStockRelease.isNotEmpty) {
      _fail('FA760');
      return false;
    }
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
      _lockForNextSeller();
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

  /// Tela do terminal para as permissões do PDV: orçamento, caixa ou autoatendimento.
  String get screen => quoteMode ? 'quote' : (database.terminalProfile == 'self_service' ? 'self_service' : 'cashier');

  /// Permissão de descartar a venda em andamento nesta tela.
  String get discardPermission => switch (screen) {
    'quote' => 'pdv.quote_clear',
    'self_service' => 'pdv.self_service_cancel',
    _ => 'pdv.sale_cancel',
  };

  /// Nome do botão de descartar: "Limpar tela" no orçamento, "Cancelar venda" no caixa e no autoatendimento.
  String get discardLabel => quoteMode ? 'Limpar tela' : 'Cancelar venda';

  /// Quem está no terminal (operador ou vendedor) pode fazer sozinho?
  bool can(String permission) => actor?.can(permission) ?? false;

  /// O descarte pede código e PIN? No autoatendimento, sempre: quem está na tela é o cliente, não
  /// quem abriu o turno. Nas outras telas, só quando quem está no terminal não tem a permissão.
  bool get discardNeedsRelease => screen == 'self_service' || !can(discardPermission);

  /// Supervisor libera o que quem está no terminal não pode: código e PIN, a permissão e outra
  /// pessoa. Devolve quem liberou, ou null com o aviso.
  /// [allowSelf]: no autoatendimento quem abriu o turno pode liberar (quem pediu foi o cliente).
  Future<LocalUser?> authorize(String permission, String code, String pin, {bool allowSelf = false}) async {
    try {
      final supervisor = await auth.verify(code, pin);
      if (!supervisor.can(permission)) throw const PosException('FA757');
      if (!allowSelf && supervisor.id == actor?.id) throw const PosException('FA982');
      return supervisor;
    } on PosException catch (error) {
      _fail(error.code);
      return null;
    }
  }

  /// Descarta a venda (ou o orçamento) em andamento: itens, cliente, pagamentos e orçamento puxado;
  /// a reserva de cashback volta. Quem está no terminal sem a permissão da tela precisa do
  /// supervisor. Fica registrado para a central (sem dados do cliente). Devolve true quando descartou.
  Future<bool> discardCart({String supervisorCode = '', String supervisorPin = ''}) async {
    if (busy || cart.isEmpty) return false;
    final user = actor;
    LocalUser? supervisor;
    if (discardNeedsRelease) {
      supervisor = await authorize(discardPermission, supervisorCode, supervisorPin, allowSelf: screen == 'self_service');
      if (supervisor == null) return false;
    }
    final responsible = user ?? supervisor!;
    final items = cart.lines.length;
    final totalCents = cart.totalCents;
    database.enqueue('cart_discard', {
      'id': const Uuid().v7(),
      'screen': screen,
      'user_id': responsible.id,
      // Quem liberou, quando não é quem estava no terminal.
      'authorized_by': user == null || supervisor?.id == user.id ? null : supervisor?.id,
      'items_count': items,
      'total': totalCents / 100,
      'discarded_at': _clock().toUtc().toIso8601String(),
    }, now: _clock());
    pendingControlled = null;
    _payAfterControlled = false;
    pendingZeroStock = null;
    _releaseCashback(cart.payments.where((payment) => payment.method == PaymentMethod.cashback));
    _undoPbm('Venda cancelada no caixa');
    saleCashback = null;
    cart.clear();
    _applyFixedSeller();
    paying = false;
    results = const [];
    notice = null;
    info = quoteMode ? 'Tela limpa.' : 'Venda cancelada.';
    logger?.info('Venda descartada no PDV', fields: {
      'screen': screen,
      'items': items,
      if (supervisor != null) 'supervisor_code': supervisor.code,
    });
    onSaleSaved?.call();
    notifyListeners();
    return true;
  }

  /// O que dizer ao operador depois do cancelamento. Sempre lembra de devolver o que foi pago.
  static String cancelMessage(String code, Map<String, dynamic> result) {
    const others = 'Cartão ou PIX: estorne na maquininha ou pelo banco.';
    if (result['already'] == true) {
      return 'A venda $code já estava cancelada na central. Confira se o cliente recebeu de volta o que pagou '
          '(dinheiro pela gaveta; cartão ou PIX, estorno na maquininha ou pelo banco).';
    }
    if (result['sale_kept'] != null) return 'NFC-e cancelada, mas a venda não foi desfeita: acerte pela devolução.';
    return switch (result['cash_refund'] as String?) {
      'same_session' => 'Venda $code cancelada. Devolva o dinheiro ao cliente pela gaveta. $others',
      'open_session' => 'Venda $code cancelada. A devolução do dinheiro foi registrada como sangria. $others',
      'no_session' => 'Venda $code cancelada. Devolva o dinheiro e registre a saída à mão. $others',
      _ => 'Venda $code cancelada. Devolva ao cliente o que foi pago. $others',
    };
  }

  /// A última venda foi cancelada neste caixa (o botão some).
  bool lastSaleCanceled = false;

  /// Prazo do cancelamento da NFC-e (o mesmo da central).
  static const cancelWindow = Duration(minutes: 30);

  /// Prazo do cancelamento da NF-e de venda (o mesmo da central).
  static const nfeCancelWindow = Duration(hours: 24);

  /// Nota autorizada da última venda (NFC-e ou NF-e), ainda no prazo de cancelar. Null quando não dá.
  LocalNfce? get cancelableNfce {
    final sale = lastSale;
    if (quoteMode || sale == null || sale.saleId == null || lastSaleCanceled || cancelNfce == null) return null;
    final document = database.nfceOfSale(sale.saleId!);
    final authorizedAt = document?.authorizedAt;
    if (document == null || document.status != 'authorized' || authorizedAt == null) return null;
    final window = document.isNfe ? nfeCancelWindow : cancelWindow;
    return _clock().difference(authorizedAt) < window ? document : null;
  }

  /// Cancela a última venda: o supervisor (outra pessoa, com "Cancelar NFC-e") libera no caixa e a
  /// central cancela a NFC-e na Sefaz e desfaz a venda. Antes, a fila sobe: a central precisa ter a
  /// venda e a nota. Devolve true quando a central confirmou.
  Future<bool> cancelLastSale({required String reason, required String supervisorCode, required String supervisorPin}) async {
    final current = operator;
    final document = cancelableNfce;
    final request = cancelNfce;
    final sale = lastSale;
    if (current == null || document == null || request == null || sale == null) return false;
    busy = true;
    notice = null;
    notifyListeners();
    try {
      final text = reason.trim();
      if (text.length < 15 || text.length > 255) throw const PosException('FA005');
      final supervisor = await auth.verify(supervisorCode, supervisorPin);
      if (!supervisor.can('fiscal.cancel')) throw const PosException('FA757');
      if (supervisor.id == current.id) throw const PosException('FA982');
      await syncNow?.call();
      if (database.outboxHasSale(sale.saleId!)) throw const PosException('FA756');
      final Map<String, dynamic> result;
      try {
        result = await request(document.id, text, supervisor.id);
      } on ApiException catch (error) {
        if (error.code == 'FA001') {
          // Sem resposta: a central pode ter cancelado ou nem ter recebido. Pedir de novo é seguro:
          // já cancelada, ela responde que está feito; na Sefaz, o pedido repetido é conferido pela chave.
          notice = ErrorDisplay.fromCode('FA001');
          info = 'Sem resposta da central. Tente de novo: se a venda já tiver sido cancelada, o caixa avisa.';
          return false;
        }
        throw PosException(error.code);
      }
      database.updateNfce(document.copyWith(status: 'canceled', reason: text), now: _clock());
      lastSaleCanceled = true;
      info = cancelMessage(sale.code, result);
      logger?.info('Venda cancelada no caixa', fields: {'sale_code': sale.code, 'supervisor_code': supervisor.code});
      onSaleSaved?.call();
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

  /// DANFE A4 da NF-e autorizada: guarda o PDF e manda à impressora padrão pelo programa de PDF do
  /// Windows; se não der, abre o PDF para imprimir à mão. Falha não desfaz a venda.
  Future<void> printDanfe(LocalNfce nfe) async {
    final printer = danfePrinter;
    if (printer == null) return;
    try {
      final printed = await printer.print(nfe.accessKey, await buildDanfeA4(nfe.xml));
      lastDanfePath = printed.file.path;
      if (printed.result != DanfeResult.printed) notice = ErrorDisplay.fromCode('FA783');
    } catch (error, stack) {
      logger?.error('Falha ao gerar ou imprimir o DANFE', errorCode: 'FA783', error: error, stackTrace: stack, fields: {'number': nfe.number});
      notice = ErrorDisplay.fromCode('FA783');
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
