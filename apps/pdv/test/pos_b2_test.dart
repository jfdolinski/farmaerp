import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/discount.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';

import 'app_test.dart' show FakeApi;
import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const adminId = '019a0000-0000-7000-8000-000000000008';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const semEstoque = '019a0000-0000-7000-8000-000000000061';
const encomenda = '019a0000-0000-7000-8000-000000000071';
const customerId = '019a0000-0000-7000-8000-000000000032';
const agreementId = '019a0000-0000-7000-8000-0000000000a9';

final synced = DateTime.utc(2026, 11, 23, 12);
late String pin;

PullItem user(String id, int code, String name, {List<String> permissions = const ['sales.sell'], Map<String, Object?> limits = const {}, bool admin = false}) =>
    PullItem(type: 'user', id: id, data: {
      'code': code, 'name': name, 'is_admin': admin, 'roles': const [], 'permissions': permissions, 'limits': limits, 'pin_hash': pin,
    });

PullItem product(String id, int code, String name, String barcode, {num price = 10, num? maxDiscount, String? until, String status = 'active'}) => PullItem(
  type: 'product',
  id: id,
  data: {
    'code': code, 'name': name, 'status': status, 'price': price, 'fraction_quantity': 1, 'batch_required': false,
    'max_discount': maxDiscount, 'max_discount_until': until,
    'barcodes': [
      {'id': id.replaceFirst('7000', '7001'), 'code': barcode, 'is_primary': true, 'fraction_quantity': null},
    ],
    'taxes': const [],
  },
);

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'fixed_seller_id': operatorId,
        'offline_zero_stock_minutes': 45,
      }),
      user(operatorId, 3, 'Operador Centro', limits: const {'sale_discount': 5}),
      user(managerId, 5, 'Gerente Centro', permissions: const ['sales.sell', 'sales.zero_stock_release'], limits: const {'sale_discount': 10}),
      user(adminId, 1, 'Administrador', admin: true),
      product(dipirona, 1, 'Dipirona Sódica 500 mg', '7890000000017', maxDiscount: 8),
      product(semEstoque, 2, 'Soro Fisiológico', '7890000000024'),
      product(encomenda, 3, 'Fralda Geriátrica', '7890000000031', status: 'on_order'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 10, 'batches': []}),
    ]),
    now: synced,
  );
  return database;
}

void main() {
  late FakeApi api;
  late LocalDatabase database;
  late FakePrinter printer;
  late DateTime now;
  late PosController controller;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() {
    api = FakeApi();
    database = seeded();
    printer = FakePrinter();
    now = synced.add(const Duration(minutes: 5));
    controller = PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => printer,
      terminalNumber: () => 1,
      customers: CustomerService(api: api, database: database, accessToken: () async => 't'),
      networkStock: (productId) => api.networkStock(accessToken: 't', productId: productId),
      clock: () => now,
    );
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  Future<void> ready({String login = '3'}) async {
    await controller.login(login, '2468');
    controller.openShift(0);
  }

  group('desconto', () {
    test('dentro do limite do operador e da regra vale na hora', () async {
      await ready();
      controller.scan('7890000000017');
      final line = controller.cart.lines.single;
      expect(controller.applyDiscount(line, 50), DiscountNeed.none);
      expect([line.discountCents, line.totalCents, line.release], [50, 950, null]);
      expect(() => checkDiscount(line: line, discountCents: 1001, operator: controller.operator!, now: now), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA980')));
    });

    test('acima do limite: supervisor com limite libera e o motivo vai para a central', () async {
      await ready();
      controller.scan('7890000000017');
      final line = controller.cart.lines.single;
      expect(controller.applyDiscount(line, 70), DiscountNeed.release);
      expect(line.discountCents, 0);

      // A própria pessoa não libera; sem motivo não libera.
      expect(await controller.releaseDiscount(line, 70, '3', '2468', 'Cliente fiel'), isFalse);
      expect(controller.notice?.message, 'A liberação precisa ser de outra pessoa.');
      expect(await controller.releaseDiscount(line, 70, '5', '2468', ' '), isFalse);
      expect(await controller.releaseDiscount(line, 70, '5', '2468', 'Cliente fiel'), isTrue);
      expect([line.discountCents, line.release?.supervisorId, line.release?.reason], [70, managerId, 'Cliente fiel']);

      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 930));
      await controller.finish();
      final sale = database.nextOutboxBatch().last.payload;
      expect((sale['items'] as List).single, containsPair('release', {'supervisor_id': managerId, 'reason': 'Cliente fiel'}));
      expect(sale['discount_total'], 0.7);
    });

    test('acima da regra do produto só passa com quem pode passar dela', () async {
      await ready();
      controller.scan('7890000000017');
      final line = controller.cart.lines.single;
      // 9% passa da regra (8%) e do limite do operador (5%). O Gerente (10%) não pode passar da regra.
      expect(controller.applyDiscount(line, 90), DiscountNeed.release);
      expect(await controller.releaseDiscount(line, 90, '5', '2468', 'Teste'), isFalse);
      expect(controller.notice?.message, 'Este supervisor não pode liberar esse desconto.');
      // O Administrador pode.
      expect(await controller.releaseDiscount(line, 90, '1', '2468', 'Teste'), isTrue);
      // Acima do limite do Gerente também não passa com ele.
      expect(() => checkSupervisor(line: line, discountCents: 110, operator: controller.operator!, supervisor: database.userByCode(5)!, now: now),
          throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA979')));
    });

    test('regra vencida não vale mais', () {
      final expired = SaleProduct(
        id: dipirona, code: 1, name: 'x', status: 'active', priceCents: 1000, stockMilli: 1000, fractionMilli: 1000,
        maxDiscountBp: 100, maxDiscountUntil: DateTime.utc(2026, 1, 1),
      );
      expect(expired.maxDiscountAt(now), isNull);
      expect(expired.copyWithUntil(DateTime.utc(2030)).maxDiscountAt(now), 100);
    });
  });

  group('venda sem estoque', () {
    test('com internet: o operador sem a permissão pede quem libera; liberado, vai com o saldo e sem os minutos', () async {
      await ready();
      controller.scan('7890000000024');
      expect(controller.notice, isNull);
      expect(controller.cart.isEmpty, isTrue);
      expect(controller.pendingZeroStock?.minutesOffline, isNull);
      await controller.approveZeroStock('5', '2468');
      final line = controller.cart.lines.single;
      expect(line.zeroStockRelease?.supervisorId, managerId);
      expect(line.warnings.join(), contains('Estoque negativo liberado por Gerente Centro'));
      expect(line.warnings.join(), isNot(contains('sem internet')));
      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: line.totalCents));
      await controller.finish();
      final item = ((database.nextOutboxBatch().last.payload['items']) as List).single as Map;
      expect(item['zero_stock_release'], {'supervisor_id': managerId, 'minutes_offline': null, 'stock': line.product.stockMilli / 1000});
    });

    test('aumentar a quantidade além do estoque: sem a permissão, o item espera a liberação antes de pagar', () async {
      await ready();
      controller.scan('7890000000017');
      final line = controller.cart.lines.single;
      controller.setQuantity(line, 30000);
      expect([line.quantityMilli, line.needsStockRelease, line.zeroStockRelease], [30000, true, null]);
      expect(line.warnings.join(), contains('precisa de liberação'));
      controller.startPayment();
      expect([noticeCode(), controller.paying], ['FA760', false]);
      expect(await controller.releasePendingStock('5', '2468'), isTrue);
      expect([line.needsStockRelease, line.zeroStockRelease?.supervisorId], [false, managerId]);
      // Diminuir não pede nada, nem quando ainda fica acima do estoque.
      controller.setQuantity(line, 20000);
      expect([line.needsStockRelease, line.zeroStockRelease?.supervisorId], [false, managerId]);
      controller.setQuantity(line, 1000);
      expect(line.needsStockRelease, isFalse);
    });

    test('quem tem a permissão aumenta a quantidade e o item fica liberado por ele; leituras seguidas somam no mesmo item', () async {
      await ready(login: '5');
      controller.scan('7890000000017');
      final line = controller.cart.lines.single;
      controller.setQuantity(line, 30000);
      expect([line.needsStockRelease, line.zeroStockRelease?.supervisorId], [false, managerId]);
      controller.scan('7890000000024');
      controller.scan('7890000000024');
      expect(controller.cart.lines.map((l) => [l.product.code, l.quantityMilli]).toList(), [[line.product.code, 30000], [2, 2000]]);
    });

    test('quem tem "Vender com estoque negativo" vende direto, sem painel', () async {
      await ready(login: '5');
      controller.scan('7890000000024');
      expect(controller.pendingZeroStock, isNull);
      final line = controller.cart.lines.single;
      expect(line.zeroStockRelease?.supervisorId, managerId);
    });

    test('sem internet há mais que o tempo da filial: só com o gerente, e fica registrado', () async {
      await ready();
      now = synced.add(const Duration(minutes: 50));
      controller.scan('7890000000024');
      expect(controller.pendingZeroStock?.minutesOffline, 50);
      expect(controller.cart.isEmpty, isTrue);

      await controller.approveZeroStock('3', '2468');
      expect(controller.notice?.message, 'Esta pessoa não pode autorizar venda sem estoque.');
      await controller.approveZeroStock('5', '2468');
      final line = controller.cart.lines.single;
      expect(line.zeroStockRelease?.supervisorId, managerId);
      expect(line.warnings.join(), contains('liberado por Gerente Centro (50 min sem internet)'));
      expect(controller.pendingZeroStock, isNull);

      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: 1000));
      await controller.finish();
      final item = ((database.nextOutboxBatch().last.payload['items']) as List).single as Map;
      expect(item['zero_stock_release'], {'supervisor_id': managerId, 'minutes_offline': 50, 'stock': line.product.stockMilli / 1000});
    });

    test('o que já está na venda conta; encomenda só avisa', () async {
      await ready();
      controller.add(database.saleProductByCode('7890000000017')!, quantityMilli: 10000);
      controller.scan('7890000000017');
      expect(controller.pendingZeroStock?.product.code, database.saleProductByCode('7890000000017')!.code);
      controller.cancelZeroStock();
      controller.scan('7890000000031');
      expect(controller.cart.lines.last.product.id, encomenda);
      expect(controller.cart.lines.last.warnings, contains('Produto por encomenda'));
    });
  });

  group('cliente e convênio', () {
    test('cliente escolhido vai na venda e no comprovante; convênio dele vira pagamento', () async {
      await ready();
      api.customerData[customerId] = {
        'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735',
        'agreements': [
          {'agreement_id': agreementId, 'name': 'Convênio Prefeitura', 'registration': 'M-1', 'credit_limit': 300},
        ],
      };
      controller.scan('7890000000017');
      // Sem cliente, convênio não entra.
      controller.addPayment(Payment(method: PaymentMethod.agreement, amountCents: 1000, agreementId: agreementId));
      expect(controller.notice?.message, 'Para pagar com convênio, identifique um cliente que tenha o convênio.');
      await controller.selectCustomer(customerId);
      expect(controller.cart.customer?.documentMasked, '111.***.***-35');
      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.agreement, amountCents: 1000, agreementId: agreementId, agreementName: 'Convênio Prefeitura', agreementRegistration: 'M-1'));
      await controller.finish();
      final sale = database.nextOutboxBatch().last.payload;
      expect(sale['customer_id'], customerId);
      expect((sale['payments'] as List).single, allOf(containsPair('method', 'agreement'), containsPair('agreement_id', agreementId), containsPair('agreement_registration', 'M-1')));
      final text = printer.printed.values.single.map((line) => line.text).join('\n');
      expect(text, contains('Cliente: Cliente Demonstração · 111.***.***-35'));
      expect(text, contains('Convênio Convênio Prefeitura'));
      expect(text, contains('Matrícula M-1'));
      expect(controller.cart.customer, isNull);
    });

    test('limite do convênio: usado da central, vendas ainda não enviadas e o carrinho', () async {
      await ready();
      api.customerData[customerId] = {
        'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735',
        'agreements': [
          {'agreement_id': agreementId, 'name': 'Convênio Prefeitura', 'registration': 'M-1', 'credit_limit': 30, 'used': 15},
        ],
      };
      Payment agreement(int cents) =>
          Payment(method: PaymentMethod.agreement, amountCents: cents, agreementId: agreementId, agreementName: 'Convênio Prefeitura', agreementRegistration: 'M-1');
      controller.scan('7890000000017');
      controller.scan('7890000000017');
      await controller.selectCustomer(customerId);
      expect(controller.agreementAvailableCents(agreementId), 1500);
      expect(controller.agreementAvailableCents('019a0000-0000-7000-8000-0000000000ff'), isNull);
      controller.startPayment();
      controller.addPayment(agreement(1600));
      expect(controller.notice?.message, 'O valor passa do limite do convênio do cliente.');
      expect(controller.cart.payments, isEmpty);
      controller.addPayment(agreement(1000));
      expect(controller.agreementAvailableCents(agreementId), 500);
      controller.addPayment(agreement(600));
      expect(controller.notice?.message, 'O valor passa do limite do convênio do cliente.');
      controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 1000));
      await controller.finish();
      expect(controller.cart.customer, isNull);

      // A venda ainda não subiu: o disponível já desconta os R$ 10 dela.
      controller.scan('7890000000017');
      await controller.selectCustomer(customerId);
      expect(controller.agreementAvailableCents(agreementId), 500);
    });
  });

  group('estoque nas filiais', () {
    test('mostra a lista; sem internet, avisa', () async {
      await ready();
      api.networkResponse = [
        {'branch_id': branchId, 'branch_name': 'Loja Centro', 'own': true, 'quantity': 10},
        {'branch_id': 'b2', 'branch_name': 'Loja Sul', 'own': false, 'quantity': 4},
      ];
      final product = database.saleProductByCode('7890000000017')!;
      expect((await controller.stockElsewhere(product))?.length, 2);
      api.networkResponse = const ApiException('FA001');
      expect(await controller.stockElsewhere(product), isNull);
      expect(controller.notice?.message, 'A consulta precisa de internet.');
    });
  });

  group('telas', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    }

    testWidgets('desconto pede o supervisor quando passa do limite', (tester) async {
      await tester.runAsync(ready);
      controller.scan('7890000000017');
      await pump(tester);
      await tester.tap(find.byKey(const Key('discount-0')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('discount-value')), '7');
      await tester.tap(find.byKey(const Key('discount-apply')));
      await tester.pumpAndSettle();
      expect(findText('Este desconto passa do seu limite.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('supervisor-code')), '5');
      await tester.enterText(find.byKey(const Key('supervisor-pin')), '2468');
      await tester.enterText(find.byKey(const Key('release-reason')), 'Cliente fiel');
      await tester.runAsync(() => controller.releaseDiscount(controller.cart.lines.single, 70, '5', '2468', 'Cliente fiel'));
      await tester.pump();
      expect(controller.cart.lines.single.discountCents, 70);
      expect(controller.cart.totalCents, 930);
    });

    testWidgets('painel de venda sem estoque aparece e o gerente autoriza', (tester) async {
      await tester.runAsync(ready);
      now = synced.add(const Duration(hours: 2));
      controller.scan('7890000000024');
      await pump(tester);
      expect(find.byKey(const Key('zero-stock-panel')), findsOneWidget);
      expect(findTextContaining('sem sincronizar há 2 h 0 min'), findsOneWidget);
      await tester.runAsync(() => controller.approveZeroStock('5', '2468'));
      await tester.pump();
      expect(find.byKey(const Key('zero-stock-panel')), findsNothing);
      expect(findTextContaining('liberado por Gerente Centro'), findsOneWidget);
    });

    testWidgets('cliente aparece no painel e o convênio vira forma de pagamento', (tester) async {
      await tester.runAsync(ready);
      api.customerData[customerId] = {
        'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735',
        'agreements': [
          {'agreement_id': agreementId, 'name': 'Convênio Prefeitura', 'registration': 'M-1', 'credit_limit': 300},
        ],
      };
      controller.scan('7890000000017');
      await pump(tester);
      expect(find.byKey(const Key('identify-customer')), findsOneWidget);
      await tester.runAsync(() => controller.selectCustomer(customerId));
      await tester.pump();
      expect(findText('Cliente Demonstração'), findsOneWidget);
      await tester.tap(find.byKey(const Key('pay')));
      await tester.pump();
      expect(find.byKey(const Key('method-agreement')), findsOneWidget);
    });
  });
}

extension on SaleProduct {
  SaleProduct copyWithUntil(DateTime until) => SaleProduct(
    id: id, code: code, name: name, status: status, priceCents: priceCents, stockMilli: stockMilli, fractionMilli: fractionMilli,
    maxDiscountBp: maxDiscountBp, maxDiscountUntil: until,
  );
}
