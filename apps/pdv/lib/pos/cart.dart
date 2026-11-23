import 'package:uuid/uuid.dart';

import '../local/local_database.dart';
import 'controlled.dart';
import 'money.dart';
import 'pos_auth.dart';

/// Meios de pagamento desta etapa. Cartão e PIX são registrados à mão (maquininha à parte).
enum PaymentMethod {
  cash('cash', 'Dinheiro'),
  creditCard('credit_card', 'Cartão de crédito'),
  debitCard('debit_card', 'Cartão de débito'),
  pix('pix', 'PIX'),
  agreement('agreement', 'Convênio');

  const PaymentMethod(this.code, this.label);

  final String code;
  final String label;
}

class CartLine {
  CartLine({required this.product, required this.quantityMilli, required this.unitPriceCents});

  final SaleProduct product;
  int quantityMilli;
  final int unitPriceCents;
  int discountCents = 0;

  /// Liberação do desconto feita no PDV por outra pessoa (supervisor).
  ({String supervisorId, String supervisorName, String reason})? release;

  /// Controlado: receita, comprador e lote (ou a liberação pendente), com o farmacêutico que liberou.
  ControlledRelease? controlled;

  /// Venda sem estoque autorizada com o PDV sem internet.
  ({String supervisorId, String supervisorName, int minutesOffline})? zeroStockRelease;

  /// Desconto em centésimos de ponto percentual (850 = 8,5%).
  int get discountBp => grossCents == 0 ? 0 : (discountCents * 10000 / grossCents).ceil();

  int get grossCents => lineGrossCents(unitPriceCents, quantityMilli);
  int get totalCents => grossCents - discountCents;

  /// Avisos do item, para a tela.
  List<String> get warnings => [
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
  });

  final PaymentMethod method;
  final int amountCents;
  final String? cardBrand;
  final String? authorizationCode;
  final String? agreementId;
  final String? agreementName;
  final String? agreementRegistration;
}

/// Cliente identificado na venda (com os convênios dele).
class SaleCustomer {
  const SaleCustomer({required this.id, required this.name, required this.code, this.documentMasked, this.agreements = const []});

  final String id;
  final String name;
  final int code;
  final String? documentMasked;
  final List<Map<String, dynamic>> agreements;
}

/// Venda em montagem.
class Cart {
  final lines = <CartLine>[];
  final payments = <Payment>[];
  SaleCustomer? customer;

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

  /// Quanto deste lote já está na venda (itens de controlado).
  int quantityOfBatch(String batchId) => lines
      .where((line) => line.controlled?.batch?.id == batchId)
      .fold(0, (sum, line) => sum + line.quantityMilli);

  /// Acrescenta o produto (ou soma no item igual que já está na venda). Controlado só entra com a
  /// liberação do farmacêutico, e cada um fica no seu item (receita e lote próprios).
  CartLine add(SaleProduct product, {int quantityMilli = 1000, ControlledRelease? controlled}) {
    if ((product.controlledClass != null) != (controlled != null)) throw const PosException('FA986');
    if (product.priceCents == null) throw const PosException('FA974');
    if (quantityMilli <= 0) throw const PosException('FA975');
    // Código lido com fracionamento (caixa com 10, por exemplo) vale a fração. No controlado, a
    // quantidade já vem contada da janela da receita.
    final quantity = product.barcodeFractionMilli == null || controlled != null
        ? quantityMilli
        : (quantityMilli * product.barcodeFractionMilli! / 1000).round();
    for (final line in lines) {
      if (controlled == null && line.product.id == product.id && line.discountCents == 0 && line.zeroStockRelease == null) {
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
      'sold_at': now.toUtc().toIso8601String(),
      'fiscal_model': '65',
      'items': items,
      'payments': payments,
      'subtotal': money(cart.subtotalCents),
      'discount_total': money(cart.discountCents),
      'total': money(cart.totalCents),
    },
  );
}
