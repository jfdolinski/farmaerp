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

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'terminal_profile': 'cashier',
      }),
      user(operatorId, 3, 'Operador Centro', const ['sales.sell', 'sales.quote'], const {'sale_discount': 5}),
      user(clerkId, 6, 'Balconista Ana', const ['sales.quote'], const {'sale_discount': 5}),
      user(supervisorId, 2, 'Gerente Centro', const ['sales.sell'], const {'sale_discount': 15}),
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

  test('puxa o orçamento: vendedor, cliente, preço de agora, desconto na mesma fração e o que ficou de fora', () async {
    await ready();
    api.customerData[customerId] = {'code': 7, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735'};
    api.quoteResponse['15'] = quoteData(customer: customerId);
    expect(await controller.loadQuote('15'), isTrue);
    expect(controller.seller?.id, clerkId);
    expect(controller.cart.customer?.name, 'Cliente Demonstração');
    expect([controller.cart.quoteId, controller.cart.quoteCode], [quoteId, 'O1-000004']);
    final line = controller.cart.lines.single;
    // Orçado a R$ 12 com 10% (liberado); hoje custa R$ 10: 2 x 10 = 20, desconto 10% = 2.
    expect([line.unitPriceCents, line.quantityMilli, line.discountCents, line.totalCents], [1000, 2000, 200, 1800]);
    expect(line.release?.supervisorName, 'Gerente Centro');
    expect(controller.info, contains('Ficou de fora: Soro Fisiológico, sem estoque; item 3, que não está neste terminal.'));

    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: 1800));
    await controller.finish();
    expect(controller.notice, isNull);
    final sale = database.nextOutboxBatch().last.payload;
    expect(sale['quote_id'], quoteId);
    expect(sale['seller_id'], clerkId);
    expect(sale['customer_id'], customerId);
    expect((sale['items'] as List).single, containsPair('release', {'supervisor_id': supervisorId, 'reason': 'Cliente fiel'}));
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

  test('controlados do orçamento abrem a receita um por vez', () async {
    await ready();
    api.quoteResponse['15'] = quoteData(items: [
      {'line': 1, 'product_id': clonazepam, 'quantity': 1, 'unit_price': 24.5, 'discount': 0, 'total': 24.5, 'release': null},
      {'line': 2, 'product_id': diazepam, 'quantity': 2, 'unit_price': 18, 'discount': 0, 'total': 36, 'release': null},
      {'line': 3, 'product_id': dipirona, 'quantity': 1, 'unit_price': 10, 'discount': 0, 'total': 10, 'release': null},
    ]);
    await controller.loadQuote('15');
    expect(controller.cart.lines.single.product.id, dipirona);
    expect(controller.pendingControlled?.product.id, clonazepam);
    controller.cancelControlled();
    expect([controller.pendingControlled?.product.id, controller.pendingControlled?.quantityMilli], [diazepam, 2000]);
    controller.cancelControlled();
    expect(controller.pendingControlled, isNull);
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
}
