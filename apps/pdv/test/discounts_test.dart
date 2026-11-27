import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const soro = '019a0000-0000-7000-8000-000000000028';

late String pin;

Map<String, dynamic> rule(String id, String name, Map<String, dynamic> fields) => {
  'id': id, 'name': name, 'kind': 'product', 'level': 'store_default', 'target_id': null, 'branch_id': null,
  'percent': null, 'buy_quantity': null, 'pay_quantity': null, 'min_quantity': null, 'payment_method': null,
  'customer_group_id': null, 'agreement_id': null, 'min_total': null, 'coupon': null, 'stacking': 'cumulative',
  'valid_from': '2026-01-01T00:00:00Z', 'valid_to': null, ...fields,
};

PullItem product(String id, int code, String name, String barcode, num price, Map<String, Object?> subject) => PullItem(
  type: 'product', id: id, data: {
    'code': code, 'name': name, 'status': 'active', 'price': price, 'fraction_quantity': 1, 'batch_required': false,
    'barcodes': [{'id': '${id.substring(0, 33)}${code}99', 'code': barcode, 'is_primary': true, 'fraction_quantity': null}],
    'taxes': const [], 'discount_subject': subject,
  },
);

LocalDatabase seeded({String profile = 'cashier'}) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 4, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'fixed_seller_id': operatorId,
        'terminal_profile': profile,
      }),
      PullItem(type: 'user', id: operatorId, data: {
        'code': 3, 'name': 'Operador Centro', 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell'],
        'limits': const {'sale_discount': 5}, 'pin_hash': pin,
      }),
      product(dipirona, 1, 'Dipirona 500 mg', '7890000000017', 10, {'id': dipirona, 'manufacturer_id': 'M1', 'category_id': 'C1'}),
      product(soro, 2, 'Soro Fisiológico', '7890000000024', 5, {'id': soro, 'manufacturer_id': 'M2', 'category_id': 'C2'}),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
      const PullItem(type: 'stock', id: soro, data: {'quantity': 50, 'batches': []}),
      PullItem(type: 'discount_rule', id: '019b0000-0000-7000-8000-000000000001', data: rule(
        '019b0000-0000-7000-8000-000000000001', 'Fabricante M1 10%', {'level': 'manufacturer', 'target_id': 'M1', 'percent': 10})),
      PullItem(type: 'discount_rule', id: '019b0000-0000-7000-8000-000000000002', data: rule(
        '019b0000-0000-7000-8000-000000000002', 'PIX 5%', {'kind': 'payment_method', 'payment_method': 'pix', 'percent': 5})),
      PullItem(type: 'discount_rule', id: '019b0000-0000-7000-8000-000000000003', data: rule(
        '019b0000-0000-7000-8000-000000000003', 'Cupom VERAO10', {'kind': 'coupon', 'coupon': 'VERAO10', 'percent': 10, 'level': 'category', 'target_id': 'C2'})),
      PullItem(type: 'discount_rule', id: '019b0000-0000-7000-8000-000000000004', data: rule(
        '019b0000-0000-7000-8000-000000000004', 'Idosos 20%', {'kind': 'customer_group', 'customer_group_id': 'G1', 'percent': 20, 'stacking': 'exclusive'})),
      PullItem(type: 'discount_rule', id: '019b0000-0000-7000-8000-000000000005', data: rule(
        '019b0000-0000-7000-8000-000000000005', 'Outra loja 50%', {'branch_id': '019a0000-0000-7000-8000-000000000006', 'percent': 50})),
    ]),
    now: DateTime.utc(2026, 11, 24, 12),
  );
  return database;
}

void main() {
  late LocalDatabase database;
  late PosController controller;
  late FakePrinter printer;
  final now = DateTime.utc(2026, 11, 24, 13);

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() async {
    database = seeded();
    printer = FakePrinter();
    controller = PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => printer,
      terminalNumber: () => 1,
      clock: () => now,
    );
    await controller.login('3', '2468');
    controller.openShift(0);
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  test('o desconto automático entra sozinho, com a explicação; o de outra loja não', () {
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, 3000);
    final line = controller.cart.lines.single;
    expect([line.grossCents, line.autoDiscountCents, line.manualDiscountCents, line.discountCents, line.totalCents], [3000, 300, 0, 300, 2700]);
    expect(line.autoApplied.map((a) => a.name), ['Fabricante M1 10%']);
    expect(line.warnings, contains('Fabricante M1 10%: -R\$ 3,00'));
    controller.scan('7890000000024');
    expect(controller.cart.lines.last.autoDiscountCents, 0);
    expect(controller.cart.discountCents, 300);
  });

  test('orçamento: o desconto automático entra ao incluir o item, como no caixa', () async {
    database.close();
    database = seeded(profile: 'quote');
    controller = PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => printer,
      terminalNumber: () => 1,
      clock: () => now,
    );
    expect(controller.quoteMode, isTrue);
    controller.scan('7890000000017');
    final line = controller.cart.lines.single;
    expect([line.grossCents, line.autoDiscountCents, line.totalCents], [1000, 100, 900]);
    expect(line.autoApplied.map((a) => a.name), ['Fabricante M1 10%']);
  });

  test('PIX: o valor sugerido já tem o desconto; com o PIX lançado, a venda fecha e leva as regras', () async {
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, 2000);
    controller.startPayment();
    // 20,00 - 10% (fabricante) - 5% (PIX) = 17,00; em dinheiro, 18,00.
    expect(controller.remainingIfPaidWith(PaymentMethod.pix), 1700);
    expect(controller.remainingIfPaidWith(PaymentMethod.cash), 1800);
    controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: 1700));
    expect(controller.cart.totalCents, 1700);
    expect(controller.cart.remainingCents, 0);
    await controller.finish();
    final payload = database.nextOutboxBatch().where((item) => item.kind == 'sale').single.payload;
    final item = (payload['items']! as List).single as Map<String, Object?>;
    expect(item, containsPair('discount', 3.0));
    expect(item, containsPair('auto_discount', 3.0));
    expect(item['discount_rules'], [
      {'rule_id': '019b0000-0000-7000-8000-000000000001', 'amount': 2.0},
      {'rule_id': '019b0000-0000-7000-8000-000000000002', 'amount': 1.0},
    ]);
    expect(payload, containsPair('discount_total', 3.0));
    final receipt = printer.printed[controller.lastSale!.code]!.map((l) => l.text).join('\n');
    expect(receipt, contains('Fabricante M1 10%'));
    expect(receipt, contains('PIX 5%'));
  });

  test('pagamento misto tira o desconto do PIX; tirar o pagamento refaz a conta', () {
    controller.scan('7890000000017');
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: 500));
    // Até aqui só PIX: o desconto do PIX vale (10,00 - 1,00 - 0,50).
    expect(controller.cart.totalCents, 850);
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 400));
    expect(controller.cart.totalCents, 900);
    expect(controller.cart.lines.single.autoApplied.map((a) => a.name), ['Fabricante M1 10%']);
    controller.removePayment(controller.cart.payments.last);
    expect(controller.cart.lines.single.autoApplied.map((a) => a.name), ['Fabricante M1 10%', 'PIX 5%']);
  });

  test('cupom: o certo vale (em minúscula); o errado avisa FA832 e não fica', () async {
    controller.scan('7890000000024');
    expect(controller.applyCoupon('nada'), isFalse);
    expect(noticeCode(), 'FA832');
    expect(controller.cart.coupon, isNull);
    expect(controller.applyCoupon(' verao10 '), isTrue);
    expect(controller.cart.coupon, 'VERAO10');
    expect(controller.cart.lines.single.autoDiscountCents, 50);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 450));
    await controller.finish();
    final payload = database.nextOutboxBatch().where((item) => item.kind == 'sale').single.payload;
    expect(payload, containsPair('coupon', 'VERAO10'));
  });

  test('cliente do grupo: a exclusiva maior vale sozinha; o manual vai por cima, dentro do que sobra', () {
    controller.scan('7890000000017');
    controller.cart.customer = const SaleCustomer(id: '019a0000-0000-7000-8000-0000000000c1', name: 'Cliente', code: 1, groupId: 'G1');
    controller.reprice();
    final line = controller.cart.lines.single;
    expect([line.autoDiscountCents, line.autoApplied.single.name], [200, 'Idosos 20%']);
    // Manual de 5% (limite do operador) por cima: 20% + 5%.
    controller.applyDiscount(line, 50);
    expect([line.manualDiscountCents, line.discountCents, line.totalCents], [50, 250, 750]);
    // Mais do que sobra do item depois do automático: FA980.
    controller.applyDiscount(line, 900);
    expect(noticeCode(), 'FA980');
    controller.cart.customer = null;
    controller.reprice();
    expect(line.autoApplied.single.name, 'Fabricante M1 10%');
  });

  test('regra que sai na descida some do caixa', () {
    database.applyPage(
      const PullPage(format: 4, until: '11', items: [PullItem(type: 'discount_rule', id: '019b0000-0000-7000-8000-000000000001', data: null)]),
      now: now,
    );
    controller.scan('7890000000017');
    expect(controller.cart.lines.single.autoDiscountCents, 0);
  });
}
