import 'package:uuid/uuid.dart';

import '../local/local_database.dart';
import 'money.dart';
import 'pos_auth.dart';

/// Meios de pagamento desta etapa. Cartão e PIX são registrados à mão (maquininha à parte).
enum PaymentMethod {
  cash('cash', 'Dinheiro'),
  creditCard('credit_card', 'Cartão de crédito'),
  debitCard('debit_card', 'Cartão de débito'),
  pix('pix', 'PIX');

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

  int get grossCents => lineGrossCents(unitPriceCents, quantityMilli);
  int get totalCents => grossCents - discountCents;

  /// Avisos do item, para a tela.
  List<String> get warnings => [
    if (product.status == 'on_order') 'Produto por encomenda',
    if (product.status == 'blocked') 'Produto bloqueado para compra: vende só o que há em estoque',
    if (product.stockMilli <= 0) 'Sem estoque na cópia local',
  ];
}

class Payment {
  Payment({required this.method, required this.amountCents, this.cardBrand, this.authorizationCode});

  final PaymentMethod method;
  final int amountCents;
  final String? cardBrand;
  final String? authorizationCode;
}

/// Venda em montagem.
class Cart {
  final lines = <CartLine>[];
  final payments = <Payment>[];

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

  /// Acrescenta o produto (ou soma no item igual que já está na venda).
  CartLine add(SaleProduct product, {int quantityMilli = 1000}) {
    if (product.controlledClass != null) throw const PosException('FA971');
    if (product.priceCents == null) throw const PosException('FA974');
    if (quantityMilli <= 0) throw const PosException('FA975');
    // Código lido com fracionamento (caixa com 10, por exemplo) vale a fração.
    final quantity = product.barcodeFractionMilli == null
        ? quantityMilli
        : (quantityMilli * product.barcodeFractionMilli! / 1000).round();
    for (final line in lines) {
      if (line.product.id == product.id && line.discountCents == 0) {
        line.quantityMilli += quantity;
        return line;
      }
    }
    final line = CartLine(product: product, quantityMilli: quantity, unitPriceCents: product.priceCents!);
    lines.add(line);
    return line;
  }

  void clear() {
    lines.clear();
    payments.clear();
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
  String? customerId,
}) {
  if (cart.isEmpty) throw const PosException('FA975');
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
      'batch_id': null,
      'release': null,
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
      'customer_id': customerId,
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
