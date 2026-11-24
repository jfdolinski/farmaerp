import 'package:uuid/uuid.dart';

import '../local/local_database.dart';
import 'controlled.dart';
import 'discount_engine.dart';
import 'money.dart';
import 'pos_auth.dart';

/// Meios de pagamento desta etapa. Cartão e PIX são registrados à mão (maquininha à parte).
enum PaymentMethod {
  cash('cash', 'Dinheiro'),
  creditCard('credit_card', 'Cartão de crédito'),
  debitCard('debit_card', 'Cartão de débito'),
  pix('pix', 'PIX'),
  agreement('agreement', 'Convênio'),
  returnCredit('return_credit', 'Crédito de devolução');

  const PaymentMethod(this.code, this.label);

  final String code;
  final String label;
}

class CartLine {
  CartLine({required this.product, required this.quantityMilli, required this.unitPriceCents});

  SaleProduct product;
  int quantityMilli;

  /// Preço atual da loja: muda no recálculo.
  int unitPriceCents;

  /// Desconto manual (operador ou supervisor), por cima dos automáticos.
  int manualDiscountCents = 0;

  /// Descontos automáticos do motor de regras, refeitos a cada mudança na venda.
  int autoDiscountCents = 0;
  List<AppliedDiscount> autoApplied = const [];

  /// Desconto do item: automáticos mais o manual, nunca acima do item.
  int get discountCents {
    final sum = autoDiscountCents + manualDiscountCents;
    return sum > grossCents ? grossCents : sum;
  }

  /// Desconto manual como fração do bruto: é ele que o recálculo mantém quando preço ou quantidade mudam.
  double? discountRate;

  /// Grava o desconto manual em centavos e a fração que o recálculo mantém.
  void setDiscount(int cents) {
    manualDiscountCents = cents;
    discountRate = cents <= 0 || grossCents == 0 ? null : cents / grossCents;
  }

  /// Liberação do desconto feita no PDV por outra pessoa (supervisor).
  ({String supervisorId, String supervisorName, String reason})? release;

  /// Controlado: receita, comprador e lote (ou a liberação pendente), com o farmacêutico que liberou.
  ControlledRelease? controlled;

  /// Venda sem estoque autorizada com o PDV sem internet.
  ({String supervisorId, String supervisorName, int minutesOffline})? zeroStockRelease;

  /// Desconto manual em centésimos de ponto percentual (850 = 8,5%).
  int get discountBp => grossCents == 0 ? 0 : (manualDiscountCents * 10000 / grossCents).ceil();

  int get grossCents => lineGrossCents(unitPriceCents, quantityMilli);
  int get totalCents => grossCents - discountCents;

  /// Avisos do item, para a tela.
  List<String> get warnings => [
    for (final applied in autoApplied) '${applied.name}: -${formatCents(applied.amountCents)}',
    if (product.status == 'on_order') 'Produto por encomenda',
    if (product.status == 'blocked') 'Produto bloqueado para compra: vende só o que há em estoque',
    if (zeroStockRelease != null)
      'Sem estoque: autorizado por ${zeroStockRelease!.supervisorName} (${zeroStockRelease!.minutesOffline} min sem internet)'
    else if (product.stockMilli <= 0)
      'Sem estoque na cópia local',
    if (release != null) 'Desconto liberado por ${release!.supervisorName}',
    if (controlled != null && controlled!.isPending)
      'Controlado sem saldo em lote: liberado por ${controlled!.pharmacistName}, dados do SNGPC pendentes'
    else if (controlled != null)
      'Controlado · lote ${controlled!.batch!.number} · ${controlled!.form!.type.label} · liberado por ${controlled!.pharmacistName}',
  ];
}

class Payment {
  Payment({
    required this.method,
    required this.amountCents,
    this.cardBrand,
    this.authorizationCode,
    this.agreementId,
    this.agreementName,
    this.agreementRegistration,
    this.returnId,
    this.returnCode,
    this.creditBalanceCents,
  });

  final PaymentMethod method;
  final int amountCents;
  final String? cardBrand;
  final String? authorizationCode;
  final String? agreementId;
  final String? agreementName;
  final String? agreementRegistration;

  /// Crédito de devolução usado (documento D) e o saldo dele na hora da busca.
  final String? returnId;
  final String? returnCode;
  final int? creditBalanceCents;
}

/// Cliente identificado na venda (com os convênios dele).
class SaleCustomer {
  const SaleCustomer({
    required this.id,
    required this.name,
    required this.code,
    this.documentMasked,
    this.agreements = const [],
    this.groupId,
    this.birthDate,
  });

  final String id;
  final String name;
  final int code;
  final String? documentMasked;
  final List<Map<String, dynamic>> agreements;

  /// Grupo de clientes e nascimento, para os descontos por grupo e de aniversariante.
  final String? groupId;
  final String? birthDate;
}

/// Venda em montagem.
class Cart {
  final lines = <CartLine>[];
  final payments = <Payment>[];
  SaleCustomer? customer;

  /// Vendedor que atende (pedido a cada venda ou orçamento novo).
  LocalUser? seller;

  /// Cupom de desconto digitado no caixa.
  String? coupon;

  /// Orçamento que esta venda fecha.
  String? quoteId;
  String? quoteCode;

  /// Quanto deste produto já está na venda.
  int quantityOf(String productId) =>
      lines.where((line) => line.product.id == productId).fold(0, (sum, line) => sum + line.quantityMilli);

  bool get isEmpty => lines.isEmpty;
  int get subtotalCents => lines.fold(0, (sum, line) => sum + line.grossCents);
  int get discountCents => lines.fold(0, (sum, line) => sum + line.discountCents);
  int get totalCents => subtotalCents - discountCents;
  int get paidCents => payments.fold(0, (sum, payment) => sum + payment.amountCents);
  int get remainingCents => totalCents - paidCents > 0 ? totalCents - paidCents : 0;

  /// Troco: só sai do dinheiro, e nunca passa do que foi pago em dinheiro.
  int get changeCents {
    final over = paidCents - totalCents;
    if (over <= 0) return 0;
    final cash = payments.where((p) => p.method == PaymentMethod.cash).fold(0, (sum, p) => sum + p.amountCents);
    return over < cash ? over : cash;
  }

  /// O que foi pago a mais em cartão ou PIX não vira troco: precisa ser corrigido.
  bool get overpaidWithoutCash => paidCents - totalCents > changeCents;

  /// Quanto deste crédito de devolução já está lançado nesta venda.
  int creditInCart(String returnId) =>
      payments.where((p) => p.returnId == returnId).fold(0, (sum, p) => sum + p.amountCents);

  /// Quanto deste lote já está na venda (itens de controlado).
  int quantityOfBatch(String batchId) => lines
      .where((line) => line.controlled?.batch?.id == batchId)
      .fold(0, (sum, line) => sum + line.quantityMilli);

  /// Acrescenta o produto (ou soma no item igual que já está na venda). Controlado só entra com a
  /// liberação do farmacêutico, e cada um fica no seu item (receita e lote próprios).
  /// No orçamento, o controlado entra sem a receita (ela é do caixa) ([quote]).
  /// [merge] falso mantém o item separado (desconto próprio vindo do orçamento, por exemplo).
  CartLine add(SaleProduct product, {int quantityMilli = 1000, ControlledRelease? controlled, bool quote = false, bool merge = true}) {
    if (!quote && (product.controlledClass != null) != (controlled != null)) throw const PosException('FA986');
    if (product.priceCents == null) throw const PosException('FA974');
    if (quantityMilli <= 0) throw const PosException('FA975');
    // Código lido com fracionamento (caixa com 10, por exemplo) vale a fração. No controlado, a
    // quantidade já vem contada da janela da receita.
    final quantity = product.barcodeFractionMilli == null || controlled != null
        ? quantityMilli
        : (quantityMilli * product.barcodeFractionMilli! / 1000).round();
    for (final line in lines) {
      if (merge && controlled == null && line.product.id == product.id && line.manualDiscountCents == 0 && line.zeroStockRelease == null) {
        line.quantityMilli += quantity;
        return line;
      }
    }
    final line = CartLine(product: product, quantityMilli: quantity, unitPriceCents: product.priceCents!)..controlled = controlled;
    lines.add(line);
    return line;
  }

  void clear() {
    lines.clear();
    payments.clear();
    customer = null;
    seller = null;
    quoteId = null;
    quoteCode = null;
  }
}

/// Venda pronta para gravar: o que vai para a central e o que fica no comprovante.
class SaleDraft {
  SaleDraft({required this.payload, required this.code, required this.itemRows});

  final Map<String, Object?> payload;
  final String code;
  final List<Map<String, Object?>> itemRows;
}

/// Monta a venda no formato que a central confere (as contas batem centavo a centavo).
SaleDraft buildSale({
  required Cart cart,
  required LocalCashSession session,
  required LocalUser operator,
  required int number,
  required int terminalNumber,
  required DateTime now,
}) {
  if (cart.isEmpty) throw const PosException('FA975');
  if (cart.payments.any((p) => p.method == PaymentMethod.agreement) && cart.customer == null) throw const PosException('FA983');
  if (cart.paidCents < cart.totalCents || cart.overpaidWithoutCash) throw const PosException('FA972');
  const uuid = Uuid();
  double money(int cents) => cents / 100;
  double quantity(int milli) => milli / 1000;

  final items = <Map<String, Object?>>[];
  final rows = <Map<String, Object?>>[];
  for (var index = 0; index < cart.lines.length; index += 1) {
    final line = cart.lines[index];
    final id = uuid.v7();
    items.add({
      'id': id,
      'line': index + 1,
      'product_id': line.product.id,
      'barcode_id': line.product.barcodeId,
      'quantity': quantity(line.quantityMilli),
      'unit_price': money(line.unitPriceCents),
      'discount': money(line.discountCents),
      'auto_discount': money(line.autoDiscountCents),
      'discount_rules': line.autoApplied.isEmpty
          ? null
          : [for (final applied in line.autoApplied) {'rule_id': applied.ruleId, 'amount': money(applied.amountCents)}],
      'total': money(line.totalCents),
      'batch_id': line.controlled?.batch?.id,
      'release': line.release == null ? null : {'supervisor_id': line.release!.supervisorId, 'reason': line.release!.reason},
      'zero_stock_release': line.zeroStockRelease == null
          ? null
          : {'supervisor_id': line.zeroStockRelease!.supervisorId, 'minutes_offline': line.zeroStockRelease!.minutesOffline},
      'controlled': line.controlled?.toJson(),
    });
    rows.add({
      'id': id,
      'line': index + 1,
      'product_id': line.product.id,
      'product_code': line.product.code,
      'product_name': line.product.name,
      'quantity_milli': line.quantityMilli,
      'unit_price_cents': line.unitPriceCents,
      'discount_cents': line.discountCents,
      'total_cents': line.totalCents,
    });
  }

  // O troco sai do primeiro pagamento em dinheiro.
  var change = cart.changeCents;
  final payments = <Map<String, Object?>>[];
  for (final payment in cart.payments) {
    final changeHere = payment.method == PaymentMethod.cash && change > 0 && change < payment.amountCents ? change : 0;
    change -= changeHere;
    payments.add({
      'id': uuid.v7(),
      'method': payment.method.code,
      'amount': money(payment.amountCents),
      'change': money(changeHere),
      'card_brand': payment.cardBrand,
      'authorization_code': payment.authorizationCode,
      'agreement_id': payment.agreementId,
      'agreement_registration': payment.agreementRegistration,
      'return_id': payment.returnId,
    });
  }
  if (change > 0) throw const PosException('FA972');

  return SaleDraft(
    code: '$terminalNumber-${number.toString().padLeft(6, '0')}',
    itemRows: rows,
    payload: {
      'id': uuid.v7(),
      'number': number,
      'cash_session_id': session.id,
      'operator_id': operator.id,
      'customer_id': cart.customer?.id,
      'seller_id': cart.seller?.id,
      'quote_id': cart.quoteId,
      'sold_at': now.toUtc().toIso8601String(),
      'fiscal_model': '65',
      'items': items,
      'payments': payments,
      'subtotal': money(cart.subtotalCents),
      'discount_total': money(cart.discountCents),
      'coupon': cart.coupon,
      'total': money(cart.totalCents),
    },
  );
}

/// Orçamento pronto para gravar e subir. As contas batem como as da venda.
SaleDraft buildQuote({
  required Cart cart,
  required int number,
  required int terminalNumber,
  required DateTime now,
  int? cardNumber,
}) {
  if (cart.isEmpty) throw const PosException('FA975');
  final seller = cart.seller;
  if (seller == null) throw const PosException('FA881');
  if (cardNumber != null && (cardNumber < 1 || cardNumber > 9999)) throw const PosException('FA882');
  const uuid = Uuid();
  double money(int cents) => cents / 100;
  final items = [
    for (var index = 0; index < cart.lines.length; index += 1)
      {
        'id': uuid.v7(),
        'line': index + 1,
        'product_id': cart.lines[index].product.id,
        'quantity': cart.lines[index].quantityMilli / 1000,
        'unit_price': money(cart.lines[index].unitPriceCents),
        'discount': money(cart.lines[index].discountCents),
        'total': money(cart.lines[index].totalCents),
        'release': cart.lines[index].release == null
            ? null
            : {'supervisor_id': cart.lines[index].release!.supervisorId, 'reason': cart.lines[index].release!.reason},
      },
  ];
  return SaleDraft(
    code: 'O$terminalNumber-${number.toString().padLeft(6, '0')}',
    itemRows: const [],
    payload: {
      'id': uuid.v7(),
      'number': number,
      'seller_id': seller.id,
      'customer_id': cart.customer?.id,
      'card_number': cardNumber,
      'quoted_at': now.toUtc().toIso8601String(),
      'items': items,
      'subtotal': money(cart.subtotalCents),
      'discount_total': money(cart.discountCents),
      'total': money(cart.totalCents),
    },
  );
}
