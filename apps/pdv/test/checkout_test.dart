import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/ui/caps.dart' show caps;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';

import 'app_test.dart' show FakeApi;
import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const clerkId = '019a0000-0000-7000-8000-0000000000c1';
const supervisorId = '019a0000-0000-7000-8000-00000000000d';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const soro = '019a0000-0000-7000-8000-000000000061';
const clonazepam = '019a0000-0000-7000-8000-000000000033';
const diazepam = '019a0000-0000-7000-8000-000000000034';
const customerId = '019a0000-0000-7000-8000-000000000032';
const quoteId = '019a0000-0000-7000-8000-0000000000f9';

final synced = DateTime(2026, 11, 24, 10);
late String pin;

PullItem user(String id, int code, String name, List<String> permissions, Map<String, Object?> limits) =>
    PullItem(type: 'user', id: id, data: {
      'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions, 'limits': limits, 'pin_hash': pin,
    });

PullItem product(String id, int code, String name, String barcode, num price, {String? controlledClass, num? maxDiscount = 20}) => PullItem(
  type: 'product',
  id: id,
  data: {
    'code': code, 'name': name, 'status': 'active', 'price': price, 'fraction_quantity': 1, 'batch_required': false,
    'controlled_class': controlledClass, 'max_discount': maxDiscount,
    'barcodes': [
      {'id': id.replaceFirst('7000', '7001'), 'code': barcode, 'is_primary': true, 'fraction_quantity': null},
    ],
    'taxes': const [],
  },
);

LocalDatabase seeded({String profile = 'cashier'}) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'terminal_profile': profile,
      }),
      user(operatorId, 3, 'Operador Centro', const ['sales.sell', 'sales.quote'], const {'sale_discount': 5}),
      user(clerkId, 6, 'Balconista Ana', const ['sales.quote'], const {'sale_discount': 5}),
      user(supervisorId, 2, 'Gerente Centro', const ['sales.sell', 'sales.zero_stock_release'], const {'sale_discount': 15}),
      product(dipirona, 1, 'Dipirona 500 mg', '7890000000017', 10),
      product(soro, 2, 'Soro Fisiológico', '7890000000024', 5),
      product(clonazepam, 4, 'Clonazepam 2 mg', '7890000000055', 24.5, controlledClass: 'B1'),
      product(diazepam, 5, 'Diazepam 10 mg', '7890000000062', 18, controlledClass: 'B1'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 10, 'batches': []}),
    ]),
    now: synced,
  );
  return database;
}

Map<String, dynamic> quoteData({List<Map<String, dynamic>>? items, String? customer}) => {
  'id': quoteId,
  'code': 'O1-000004',
  'card_number': 15,
  'seller_id': clerkId,
  'customer_id': customer,
  'total': 20,
  'items': items ??
      [
        {'line': 1, 'product_id': dipirona, 'quantity': 2, 'unit_price': 12, 'discount': 2.4, 'total': 21.6,
         'release': {'supervisor_id': supervisorId, 'reason': 'Cliente fiel'}},
        {'line': 2, 'product_id': soro, 'quantity': 1, 'unit_price': 5, 'discount': 0, 'total': 5, 'release': null},
        {'line': 3, 'product_id': '019a0000-0000-7000-8000-0000000000ee', 'quantity': 1, 'unit_price': 3, 'discount': 0, 'total': 3, 'release': null},
      ],
};

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
      openQuotes: () => api.openQuotes(accessToken: 't'),
      findQuote: (key) => api.quote(accessToken: 't', key: key),
      clock: () => now,
    );
  });
  tearDown(() => database.close());

  Future<void> ready() async {
    await controller.login('3', '2468');
    controller.openShift(0);
  }

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  test('puxa o orçamento: vendedor, cliente, preço de agora, desconto na mesma fração; sem estoque espera a liberação', () async {
    await ready();
    api.customerData[customerId] = {'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735'};
    api.quoteResponse['15'] = quoteData(customer: customerId);
    expect(await controller.loadQuote('15'), isTrue);
    expect(controller.seller?.id, clerkId);
    expect(controller.cart.customer?.name, 'Cliente Demonstração');
    expect([controller.cart.quoteId, controller.cart.quoteCode], [quoteId, 'O1-000004']);
    final line = controller.cart.lines.first;
    // Orçado a R$ 12 com 10% (liberado); hoje custa R$ 10: 2 x 10 = 20, desconto 10% = 2.
    expect([line.unitPriceCents, line.quantityMilli, line.discountCents, line.totalCents], [1000, 2000, 200, 1800]);
    expect(line.release?.supervisorName, 'Gerente Centro');
    // O soro sem estoque entra e espera a liberação; o item que não está no terminal fica de fora.
    final soro = controller.cart.lines.last;
    expect([soro.product.name, soro.needsStockRelease, soro.zeroStockRelease], ['Soro Fisiológico', true, null]);
    expect(controller.info, contains('Ficou de fora: item 3, que não está neste terminal.'));
    expect(controller.info, contains('1 item sem estoque precisa de liberação.'));
    controller.startPayment();
    expect([noticeCode(), controller.paying], ['FA760', false]);
    // O operador não tem a permissão; o gerente libera.
    expect(await controller.releasePendingStock('3', '2468'), isFalse);
    expect(noticeCode(), 'FA757');
    expect(await controller.releasePendingStock('2', '2468'), isTrue);
    expect([soro.needsStockRelease, soro.zeroStockRelease?.supervisorId], [false, supervisorId]);

    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: controller.cart.totalCents));
    await controller.finish();
    expect(controller.notice, isNull);
    final sale = database.nextOutboxBatch().last.payload;
    expect(sale['quote_id'], quoteId);
    expect(sale['seller_id'], clerkId);
    expect(sale['customer_id'], customerId);
    expect((sale['items'] as List).first, containsPair('release', {'supervisor_id': supervisorId, 'reason': 'Cliente fiel'}));
    expect((sale['items'] as List).last, containsPair('zero_stock_release', containsPair('supervisor_id', supervisorId)));
    expect((sale['items'] as List).map((item) => (item as Map)['quote_id']), [quoteId, quoteId]);
    expect(printer.printed.values.last.map((l) => l.text), contains('Orçamento O1-000004'));
    expect(controller.cart.quoteId, isNull);
  });

  test('sem liberação, o desconto fica no que o operador dá sozinho', () async {
    await ready();
    api.quoteResponse['O1-000004'] = quoteData(items: [
      {'line': 1, 'product_id': dipirona, 'quantity': 1, 'unit_price': 10, 'discount': 1.5, 'total': 8.5, 'release': null},
    ]);
    expect(await controller.loadQuote('O1-000004'), isTrue);
    // 15% pedidos; o operador dá até 5%.
    expect(controller.cart.lines.single.discountCents, 50);
  });

  test('controlados do orçamento entram na venda; a receita é pedida ao finalizar, um por vez', () async {
    await ready();
    api.quoteResponse['15'] = quoteData(items: [
      {'line': 1, 'product_id': clonazepam, 'quantity': 1, 'unit_price': 24.5, 'discount': 0, 'total': 24.5, 'release': null},
      {'line': 2, 'product_id': diazepam, 'quantity': 2, 'unit_price': 18, 'discount': 0, 'total': 36, 'release': null},
      {'line': 3, 'product_id': dipirona, 'quantity': 1, 'unit_price': 10, 'discount': 0, 'total': 10, 'release': null},
    ]);
    await controller.loadQuote('15');
    expect(controller.cart.lines.map((line) => line.product.id), [clonazepam, diazepam, dipirona]);
    expect(controller.pendingControlled, isNull);
    controller.startPayment();
    expect(controller.paying, isFalse);
    expect(controller.pendingControlled?.product.id, clonazepam);
    // Não vender tira o item e passa ao próximo controlado.
    controller.dropControlled();
    expect([controller.pendingControlled?.product.id, controller.pendingControlled?.quantityMilli], [diazepam, 2000]);
    // Voltar aos itens mantém o controlado na venda, ainda sem receita.
    controller.cancelControlled();
    expect([controller.pendingControlled, controller.paying], [null, false]);
    expect(controller.cart.lines.map((line) => line.product.id), [diazepam, dipirona]);
  });

  test('erros: venda em andamento, sem internet, orçamento que já virou venda', () async {
    await ready();
    controller.scan('7890000000017');
    expect(noticeCode(), 'FA881');
    await controller.identifySeller('3');
    controller.scan('7890000000017');
    expect(await controller.loadQuote('15'), isFalse);
    expect(noticeCode(), 'FA889');
    controller.remove(controller.cart.lines.single);
    api.quoteResponse['15'] = const ApiException('FA886');
    expect(await controller.loadQuote('15'), isFalse);
    expect([noticeCode(), controller.cart.quoteId], ['FA886', null]);
    api.quoteResponse['15'] = const ApiException('FA001');
    expect(await controller.loadQuote('15'), isFalse);
    expect(noticeCode(), 'FA890');
    expect(await controller.loadQuote('99'), isFalse);
    expect(noticeCode(), 'FA885');
  });

  test('ler o cupom no campo de leitura puxa o orçamento, mesmo antes do vendedor', () async {
    await ready();
    api.quoteResponse['O1-000004'] = quoteData();
    controller.scan('o1-000004');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.quoteKeys, ['O1-000004']);
    expect(controller.cart.quoteCode, 'O1-000004');
    expect(controller.seller?.id, clerkId);
  });

  test('recalcula a cada mudança: preço novo da loja, desconto na mesma fração, pagamento refeito', () async {
    await ready();
    await controller.identifySeller('3');
    controller.scan('7890000000017');
    final line = controller.cart.lines.single;
    controller.applyDiscount(line, 50);
    expect(line.totalCents, 950);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 950));
    // O preço muda na central e desce.
    database.applyPage(PullPage(format: 3, until: '11', items: [product(dipirona, 1, 'Dipirona 500 mg', '7890000000017', 12)]), now: synced);
    controller.setQuantity(line, 2000);
    expect([line.unitPriceCents, line.discountCents, line.totalCents], [1200, 120, 2280]);
    expect(controller.cart.payments, isEmpty);
    expect(controller.info, 'O total mudou: refaça o pagamento.');
  });

  testWidgets('F3: lista dos pendentes e puxa com um toque', (tester) async {
    await tester.runAsync(ready);
    api.openQuoteList = [
      {'id': quoteId, 'code': 'O1-000004', 'card_number': 15, 'seller_name': 'Balconista Ana', 'customer_name': null, 'total': 20, 'item_count': 3,
       'quoted_at': '2026-11-24T12:00:00Z', 'expires_at': '2026-11-25T03:00:00Z'},
      {'id': '019a0000-0000-7000-8000-0000000000fa', 'code': 'O1-000005', 'card_number': 16, 'seller_name': 'Gerente Centro', 'customer_name': 'Maria', 'total': 10,
       'item_count': 1, 'quoted_at': '2026-11-24T12:10:00Z', 'expires_at': '2026-11-25T03:00:00Z'},
    ];
    api.quoteResponse['O1-000004'] = quoteData();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('scan-field')));
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quote-lookup')), findsOneWidget);
    expect(findTextContaining('Vendedor: Balconista Ana'), findsOneWidget);
    expect(find.byKey(const Key('quote-O1-000005')), findsOneWidget);
    // Filtra enquanto digita (vendedor, cliente, plaquinha ou código).
    await tester.enterText(find.byKey(const Key('quote-key')), 'ana');
    await tester.pump();
    expect(find.byKey(const Key('quote-O1-000005')), findsNothing);
    expect(tester.widget<ListTile>(find.byKey(const Key('quote-O1-000004'))).selected, isTrue);
    await tester.enterText(find.byKey(const Key('quote-key')), 'maria');
    await tester.pump();
    expect(find.byKey(const Key('quote-O1-000004')), findsNothing);
    await tester.enterText(find.byKey(const Key('quote-key')), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('quote-O1-000004')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quote-lookup')), findsNothing);
    expect(find.byKey(const Key('cart-quote')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('seller-name'))).data, caps('Vendedor: Balconista Ana'));
  });

  group('parte C: orçamentos juntados e estoque negativo', () {
    const secondQuote = '019a0000-0000-7000-8000-0000000000fa';
    Map<String, dynamic> second({String? customer = customerId}) => {
      'id': secondQuote, 'code': 'O1-000005', 'card_number': 16, 'seller_id': supervisorId, 'customer_id': customer, 'total': 10,
      'items': [
        {'line': 1, 'product_id': dipirona, 'quantity': 1, 'unit_price': 10, 'discount': 0, 'total': 10, 'release': null},
      ],
    };
    final simple = [
      {'line': 1, 'product_id': dipirona, 'quantity': 2, 'unit_price': 10, 'discount': 0, 'total': 20, 'release': null},
    ];

    test('junta dois orçamentos: cada item com o vendedor e o orçamento dele; o cliente do primeiro que tem cliente', () async {
      await ready();
      api.customerData[customerId] = {'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735'};
      api.quoteResponse['O1-000004'] = quoteData(items: simple);
      api.quoteResponse['O1-000005'] = second();
      // O mesmo orçamento duas vezes (plaquinha e código) conta uma vez.
      api.quoteResponse['15'] = quoteData(items: simple);
      expect(await controller.loadQuotes(['O1-000004', '15', 'O1-000005']), isTrue);
      expect(controller.seller?.id, clerkId);
      expect(controller.cart.customer?.name, 'Cliente Demonstração');
      expect([controller.cart.quoteId, controller.cart.quoteCode], [quoteId, 'O1-000004, O1-000005']);
      expect(controller.info, startsWith('Orçamentos O1-000004, O1-000005 carregados.'));
      final lines = controller.cart.lines;
      expect(lines.map((line) => [line.quantityMilli, line.sellerId, line.quoteId]).toList(), [
        [2000, clerkId, quoteId],
        [1000, supervisorId, secondQuote],
      ]);
      expect(lines.last.warnings, contains('Vendedor: Gerente Centro'));
      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: controller.cart.totalCents));
      await controller.finish();
      final sale = database.nextOutboxBatch().last.payload;
      expect([sale['quote_id'], sale['seller_id'], sale['customer_id']], [quoteId, clerkId, customerId]);
      expect((sale['items'] as List).map((item) => [(item as Map)['seller_id'], item['quote_id']]).toList(), [
        [clerkId, quoteId],
        [supervisorId, secondQuote],
      ]);
    });

    test('um orçamento só: o vendedor do item é o do orçamento, sem repetir na tela', () async {
      await ready();
      api.quoteResponse['O1-000004'] = quoteData(items: simple);
      expect(await controller.loadQuote('O1-000004'), isTrue);
      expect(controller.cart.lines.single.sellerId, clerkId);
      expect(controller.cart.lines.single.warnings.where((w) => w.startsWith('Vendedor')), isEmpty);
    });

    test('produto lido no caixa depois de puxar o orçamento fica num item próprio (não soma no do orçamento)', () async {
      await ready();
      api.quoteResponse['O1-000004'] = quoteData(items: simple);
      expect(await controller.loadQuote('O1-000004'), isTrue);
      controller.scan('7890000000017');
      expect(controller.cart.lines.map((line) => [line.quantityMilli, line.quoteId]).toList(), [[2000, quoteId], [1000, null]]);
    });

    test('liberação feita no orçamento vale no caixa: não pede de novo', () async {
      await ready();
      api.quoteResponse['O1-000004'] = quoteData(items: [
        {'line': 1, 'product_id': soro, 'quantity': 1, 'unit_price': 5, 'discount': 0, 'total': 5, 'release': null,
         'zero_stock_release': {'supervisor_id': supervisorId, 'stock': 0}},
      ]);
      expect(await controller.loadQuote('O1-000004'), isTrue);
      final line = controller.cart.lines.single;
      expect([line.needsStockRelease, line.zeroStockRelease?.supervisorId, line.zeroStockRelease?.stockMilli], [false, supervisorId, 0]);
      expect(controller.linesNeedingStockRelease, isEmpty);
      controller.startPayment();
      expect(controller.paying, isTrue);
    });

    test('quem tem a permissão puxa o orçamento e libera na hora', () async {
      await controller.login('2', '2468');
      controller.openShift(0);
      api.quoteResponse['O1-000004'] = quoteData(items: [
        {'line': 1, 'product_id': soro, 'quantity': 1, 'unit_price': 5, 'discount': 0, 'total': 5, 'release': null},
      ]);
      expect(await controller.loadQuote('O1-000004'), isTrue);
      expect(controller.cart.lines.single.zeroStockRelease?.supervisorId, supervisorId);
      expect(controller.linesNeedingStockRelease, isEmpty);
    });

    test('autoatendimento: o estoque negativo pede sempre o código e o PIN, mesmo de quem abriu o turno', () async {
      database.close();
      database = seeded(profile: 'self_service');
      controller = PosController(
        database: database,
        auth: PosAuth(database: database, clock: () => now),
        printer: () => printer,
        terminalNumber: () => 1,
        clock: () => now,
      );
      await controller.login('2', '2468');
      controller.openShift(0);
      await controller.identifySeller('2');
      controller.scan('7890000000024');
      expect(controller.cart.isEmpty, isTrue);
      expect(controller.pendingZeroStock, isNotNull);
      await controller.approveZeroStock('2', '2468');
      expect(controller.cart.lines.single.zeroStockRelease?.supervisorId, supervisorId);
    });

    test('orçamento: sem a permissão, o vendedor chama quem libera; a liberação vai no orçamento com o saldo', () async {
      database.close();
      database = seeded(profile: 'quote');
      controller = PosController(
        database: database,
        auth: PosAuth(database: database, clock: () => now),
        printer: () => printer,
        terminalNumber: () => 1,
        clock: () => now,
      );
      await controller.identifySeller('6');
      controller.scan('7890000000024');
      expect(controller.pendingZeroStock, isNotNull);
      await controller.approveZeroStock('6', '2468');
      expect(noticeCode(), 'FA981');
      await controller.approveZeroStock('2', '2468');
      final line = controller.cart.lines.single;
      expect(line.zeroStockRelease?.supervisorId, supervisorId);
      expect(await controller.finishQuote(printCoupon: false), isTrue);
      final quote = database.nextOutboxBatch().where((item) => item.kind == 'quote').last.payload;
      expect((quote['items'] as List).single, containsPair('zero_stock_release', {'supervisor_id': supervisorId, 'stock': 0.0}));
    });

    test('orçamento: quantidade além do estoque espera a liberação; sem ela, não conclui', () async {
      database.close();
      database = seeded(profile: 'quote');
      controller = PosController(
        database: database,
        auth: PosAuth(database: database, clock: () => now),
        printer: () => printer,
        terminalNumber: () => 1,
        clock: () => now,
      );
      await controller.identifySeller('6');
      controller.scan('7890000000017');
      controller.setQuantity(controller.cart.lines.single, 50000);
      expect(await controller.finishQuote(printCoupon: false), isFalse);
      expect(noticeCode(), 'FA760');
      expect(await controller.releasePendingStock('2', '2468'), isTrue);
      expect(await controller.finishQuote(printCoupon: false), isTrue);
    });

    testWidgets('tela do orçamento: o item sem estoque mostra o painel de liberação; o cliente tem o histórico', (tester) async {
      database.close();
      database = seeded(profile: 'quote');
      api.customerData[customerId] = {'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735'};
      controller = PosController(
        database: database,
        auth: PosAuth(database: database, clock: () => now),
        printer: () => printer,
        terminalNumber: () => 1,
        customers: CustomerService(api: api, database: database, accessToken: () async => 't'),
        clock: () => now,
      );
      await tester.runAsync(() => controller.identifySeller('6'));
      await tester.runAsync(() => controller.selectCustomer(customerId));
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      expect(find.byKey(const Key('customer-history-open')), findsOneWidget);
      controller.scan('7890000000024');
      await tester.pump();
      expect(find.byKey(const Key('zero-stock-panel')), findsOneWidget);
      await tester.runAsync(() => controller.approveZeroStock('2', '2468'));
      await tester.pump();
      expect(find.byKey(const Key('zero-stock-panel')), findsNothing);
      expect(controller.cart.lines.single.zeroStockRelease?.supervisorId, supervisorId);
    });

    testWidgets('tela: marca dois orçamentos e junta; o que espera liberação tem o botão', (tester) async {
      await tester.runAsync(ready);
      api.openQuoteList = [
        {'id': quoteId, 'code': 'O1-000004', 'card_number': 15, 'seller_name': 'Balconista Ana', 'customer_name': null, 'total': 20, 'item_count': 1,
         'quoted_at': '2026-11-24T12:00:00Z', 'expires_at': '2026-11-25T03:00:00Z'},
        {'id': secondQuote, 'code': 'O1-000005', 'card_number': 16, 'seller_name': 'Gerente Centro', 'customer_name': null, 'total': 10,
         'item_count': 1, 'quoted_at': '2026-11-24T12:10:00Z', 'expires_at': '2026-11-25T03:00:00Z'},
      ];
      api.quoteResponse['O1-000004'] = quoteData(items: [
        {'line': 1, 'product_id': soro, 'quantity': 1, 'unit_price': 5, 'discount': 0, 'total': 5, 'release': null},
      ]);
      api.quoteResponse['O1-000005'] = second(customer: null);
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      await tester.tap(find.byKey(const Key('scan-field')));
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('quote-merge'))).onPressed, isNull);
      await tester.tap(find.byKey(const Key('quote-pick-O1-000004')));
      await tester.tap(find.byKey(const Key('quote-pick-O1-000005')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('quote-merge')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quote-lookup')), findsNothing);
      expect(controller.cart.lines, hasLength(2));
      // O soro veio sem estoque e sem liberação: o botão aparece; o gerente libera.
      expect(find.byKey(const Key('stock-release-open')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stock-release-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('release-code')), '2');
      await tester.enterText(find.byKey(const Key('release-pin')), '2468');
      await tester.tap(find.byKey(const Key('release-confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-release-open')), findsNothing);
      expect(controller.linesNeedingStockRelease, isEmpty);
    });
  });
}
