import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show FakeApi;
import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const dipirona = '019a0000-0000-7000-8000-000000000027';

final synced = DateTime(2026, 11, 24, 10);
late String pin;

PullItem user(String id, int code, String name, List<String> permissions) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions,
  'limits': const {'cash_withdrawal': 1000}, 'pin_hash': pin,
});

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'return_days': 7,
        'fixed_seller_id': operatorId,
      }),
      user(operatorId, 3, 'Operador Centro', const ['sales.sell']),
      user(managerId, 2, 'Gerente Centro', const ['sales.sell', 'sales.return']),
      PullItem(type: 'product', id: dipirona, data: {
        'code': 1, 'name': 'Dipirona 500 mg', 'status': 'active', 'price': 10, 'fraction_quantity': 1, 'batch_required': false,
        'barcodes': [
          {'id': '019a0000-0000-7001-8000-000000000027', 'code': '7890000000017', 'is_primary': true, 'fraction_quantity': null},
        ],
        'taxes': const [],
      }),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
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
      saleForReturn: (code) => api.saleForReturn(accessToken: 't', code: code),
      returnDocument: (code) => api.returnDocument(accessToken: 't', code: code),
      returnCredit: (code) => api.returnCredit(accessToken: 't', code: code),
      clock: () => now,
    );
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  /// Turno aberto e uma venda de 3 Dipironas a R\$ 10 em dinheiro, código 1-000001.
  Future<String> sold({String code = '3'}) async {
    await controller.login(code, '2468');
    controller.openShift(10000);
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, 3000);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 3000));
    await controller.finish();
    // A central fake está sem internet para esta venda: a busca cai na cópia do terminal.
    api.saleForReturnResponse[controller.lastSale!.code] = const ApiException('FA001');
    return controller.lastSale!.code;
  }

  List<Map<String, Object?>> outbox(String kind) =>
      database.nextOutboxBatch().where((item) => item.kind == kind).map((item) => item.payload).toList();

  test('sem internet, acha a venda deste terminal; devolve com a liberação e grava o documento', () async {
    final code = await sold();
    api.saleForReturnResponse[code] = const ApiException('FA001');
    final sale = (await controller.findSaleForReturn(code))!;
    expect(sale['late'], isFalse);
    expect((sale['items'] as List).single, containsPair('returned_quantity', 0.0));
    final itemId = (sale['items'] as List).single['id'] as String;
    // O operador não tem a permissão: precisa de quem libere.
    expect(controller.returnNeedsAuthorization(sale), isTrue);
    expect(await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Defeito', destination: 'credit'), isNull);
    expect(noticeCode(), 'FA966');
    expect(await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Defeito', destination: 'credit', code: '3', pin: '2468'), isNull);
    expect(noticeCode(), 'FA895');
    final done = (await controller.makeReturn(
      sale: sale, quantities: {itemId: 1000}, reason: ' Defeito ', destination: 'credit', code: '2', pin: '2468',
    ))!;
    expect([done.code, done.totalCents, done.destination], ['D1-000001', 1000, 'credit']);
    final payload = outbox('sale_return').single;
    expect(payload, containsPair('sale_id', sale['id']));
    expect(payload, containsPair('operator_id', operatorId));
    expect(payload, containsPair('authorized_by', managerId));
    expect(payload, containsPair('reason', 'Defeito'));
    expect(payload, containsPair('total', 10.0));
    expect(payload['items'], [containsPair('quantity', 1.0)]);
    final receipt = printer.printed['D1-000001']!;
    expect(receipt.map((l) => l.text).join('\n'), contains('Crédito para nova compra'));
    expect(receipt.where((l) => l.barcode).single.text, 'D1-000001');
    // O resto do item fecha no centavo; mais do que sobrou, não.
    final again = (await controller.findSaleForReturn(code))!;
    expect((again['items'] as List).single, containsPair('returned_quantity', 1.0));
    expect(await controller.makeReturn(sale: again, quantities: {itemId: 3000}, reason: 'x', destination: 'cash', code: '2', pin: '2468'), isNull);
    expect(noticeCode(), 'FA892');
    final rest = (await controller.makeReturn(sale: again, quantities: {itemId: 2000}, reason: 'x', destination: 'cash', code: '2', pin: '2468'))!;
    expect(rest.totalCents, 2000);
  });

  test('regras: quantidade, motivo, convênio, controlado e fora do prazo', () async {
    final code = await sold(code: '2');
    final sale = (await controller.findSaleForReturn(code))!;
    final itemId = (sale['items'] as List).single['id'] as String;
    // O gerente tem a permissão: no prazo, faz sozinho.
    expect(controller.returnNeedsAuthorization(sale), isFalse);
    expect(await controller.makeReturn(sale: sale, quantities: {itemId: 0}, reason: 'x', destination: 'cash'), isNull);
    expect(noticeCode(), 'FA871');
    expect(await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: '  ', destination: 'cash'), isNull);
    expect(noticeCode(), 'FA870');
    expect(await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'x', destination: 'agreement'), isNull);
    expect(noticeCode(), 'FA897');
    final controlled = {
      ...sale,
      'items': [
        {...(sale['items'] as List).single as Map<String, dynamic>, 'controlled': true},
      ],
    };
    expect(await controller.makeReturn(sale: controlled, quantities: {itemId: 1000}, reason: 'x', destination: 'cash'), isNull);
    expect(noticeCode(), 'FA893');
    final late = {...sale, 'late': true};
    expect(controller.returnNeedsAuthorization(late), isTrue);
    expect(await controller.makeReturn(sale: late, quantities: {itemId: 1000}, reason: 'x', destination: 'cash'), isNull);
    expect(noticeCode(), 'FA898');
    expect(await controller.makeReturn(sale: late, quantities: {itemId: 1000}, reason: 'x', destination: 'cash', code: '2', pin: '2468'), isNull);
    expect(noticeCode(), 'FA895');
    expect(outbox('sale_return'), isEmpty);
  });

  test('com internet, a venda vem da central (de qualquer caixa da loja)', () async {
    await sold();
    api.saleForReturnResponse['2-000009'] = {
      'id': '019a0000-0000-7000-8000-0000000000aa', 'code': '2-000009', 'total': 20, 'late': false, 'return_days': 7, 'has_agreement': true,
      'items': [
        {'id': '019a0000-0000-7000-8000-0000000000ab', 'line': 1, 'product_code': 1, 'product_name': 'Dipirona', 'quantity': 2, 'total': 20,
         'returned_quantity': 0, 'returned_amount': 0, 'controlled': false},
      ],
    };
    expect((await controller.findSaleForReturn('2-000009'))!['has_agreement'], isTrue);
    expect(await controller.findSaleForReturn('9-999999'), isNull);
    expect(noticeCode(), 'FA891');
  });

  test('sangria de devolução: o documento paga e não paga duas vezes', () async {
    final code = await sold(code: '2');
    final sale = (await controller.findSaleForReturn(code))!;
    final itemId = (sale['items'] as List).single['id'] as String;
    final done = (await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Defeito', destination: 'cash'))!;
    final document = (await controller.findReturnDocument(done.code.toLowerCase()))!;
    expect(document, containsPair('total', 10.0));
    expect(await controller.withdraw(1000, 'Devolução ${done.code}', returnId: document['id'] as String), isTrue);
    expect(outbox('cash_movement').single, containsPair('return_id', done.id));
    // Já pago aqui: a central também diz que não está disponível.
    expect(await controller.findReturnDocument(done.code), isNull);
    expect(noticeCode(), 'FA896');
  });

  testWidgets('F9: devolução em dinheiro e, em seguida, a sangria com o documento', (tester) async {
    final code = await tester.runAsync(() => sold(code: '2'));
    api.saleForReturnResponse[code!] = const ApiException('FA001');
    await tester.binding.setSurfaceSize(const Size(1500, 1100));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('return-dialog')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('return-sale')), code);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('return-item-1')), findsOneWidget);
    expect(find.byKey(const Key('return-authorization')), findsNothing);
    await tester.enterText(find.byKey(const Key('return-qty-1')), '2');
    await tester.pump();
    expect(find.text('Total da devolução: R\$ 20,00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('return-reason')), 'Produto com defeito');
    await tester.tap(find.byKey(const Key('return-destination-cash')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('return-confirm')));
    for (var i = 0; i < 20 && find.byKey(const Key('cash-movement-dialog')).evaluate().isEmpty; i += 1) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // A sangria abre com o documento e o valor dele.
    expect(find.byKey(const Key('cash-movement-dialog')), findsOneWidget);
    final amount = tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('cash-amount')), matching: find.byType(EditableText)));
    expect(amount.controller.text, '20,00');
    await tester.tap(find.byKey(const Key('cash-confirm')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cash-movement-dialog')), findsNothing);
    final movement = outbox('cash_movement').single;
    expect(movement, containsPair('amount', 20.0));
    expect(movement['return_id'], isNotNull);
    expect(movement['reason'], startsWith('Devolução D1-000001'));
  });

  /// Nova venda de [quantity] Dipironas, pronta para pagar.
  void newSale(int quantity) {
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, quantity * 1000);
    controller.startPayment();
  }

  Payment credit(({String id, String code, int balanceCents}) found, int cents) => Payment(
    method: PaymentMethod.returnCredit, amountCents: cents, returnId: found.id, returnCode: found.code,
    creditBalanceCents: found.balanceCents,
  );

  test('troca sem internet: o crédito feito aqui paga a nova compra até o saldo', () async {
    final code = await sold(code: '2');
    final sale = (await controller.findSaleForReturn(code))!;
    final itemId = (sale['items'] as List).single['id'] as String;
    await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Troca', destination: 'credit');
    api.returnCreditResponse['D1-000001'] = const ApiException('FA001');
    // Devolução em dinheiro não é crédito.
    newSale(2);
    final found = (await controller.findReturnCredit(' d1-000001 '))!;
    expect([found.code, found.balanceCents], ['D1-000001', 1000]);
    controller.addPayment(credit(found, 1500));
    expect(noticeCode(), 'FA873');
    expect(controller.cart.payments, isEmpty);
    controller.addPayment(credit(found, 600));
    controller.addPayment(credit(found, 500));
    expect(noticeCode(), 'FA873');
    controller.addPayment(credit(found, 400));
    // Já lançado por inteiro nesta venda: não acha mais saldo.
    expect(await controller.findReturnCredit('D1-000001'), isNull);
    expect(noticeCode(), 'FA872');
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 1000));
    await controller.finish();
    final payload = outbox('sale').last;
    final payments = (payload['payments']! as List).cast<Map<String, Object?>>();
    expect(payments.where((p) => p['method'] == 'return_credit').map((p) => [p['return_id'], p['amount']]), [
      [found.id, 6.0],
      [found.id, 4.0],
    ]);
    expect(payments.where((p) => p['method'] == 'cash').single['return_id'], isNull);
    final receipt = printer.printed[controller.lastSale!.code]!.map((l) => l.text).join('\n');
    expect(receipt, contains('Crédito D1-000001'));
    // Usado na venda gravada: a cópia local não tem mais saldo.
    expect(database.localReturnCredit('D1-000001'), containsPair('balance', 0.0));
    newSale(1);
    expect(await controller.findReturnCredit('D1-000001'), isNull);
    expect(noticeCode(), 'FA872');
  });

  test('crédito sem internet: só os créditos deste terminal; em dinheiro ou desconhecido, FA872', () async {
    final code = await sold(code: '2');
    final sale = (await controller.findSaleForReturn(code))!;
    final itemId = (sale['items'] as List).single['id'] as String;
    await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'x', destination: 'cash');
    for (final key in ['D1-000001', 'D7-000003']) {
      api.returnCreditResponse[key] = const ApiException('FA008');
      expect(await controller.findReturnCredit(key), isNull, reason: key);
      expect(noticeCode(), 'FA872');
    }
    expect(await controller.findReturnCredit('   '), isNull);
    // Sem a busca, não lança.
    controller.addPayment(Payment(method: PaymentMethod.returnCredit, amountCents: 100));
    expect(noticeCode(), 'FA872');
  });

  test('crédito com internet: saldo da central menos o que este terminal usou e não enviou', () async {
    const otherId = '019a0000-0000-7000-8000-0000000000aa';
    await controller.login('3', '2468');
    controller.openShift(10000);
    api.returnCreditResponse['D9-000001'] = {'id': otherId, 'code': 'D9-000001', 'total': 15, 'used': 5, 'balance': 10};
    newSale(1);
    final found = (await controller.findReturnCredit('D9-000001'))!;
    expect(found.balanceCents, 1000);
    controller.addPayment(credit(found, 400));
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 600));
    await controller.finish();
    newSale(1);
    expect((await controller.findReturnCredit('D9-000001'))!.balanceCents, 600);
    // Depois de enviada, a central já conta o uso.
    final batch = database.nextOutboxBatch();
    database.markSent(batch, [for (final item in batch) PushResult(id: item.id, status: 'applied')], now: now);
    expect((await controller.findReturnCredit('D9-000001'))!.balanceCents, 1000);
    // Recusa da central (sem saldo ou de outra loja) aparece ao operador, sem cair na cópia local.
    api.returnCreditResponse['D9-000001'] = const ApiException('FA872');
    expect(await controller.findReturnCredit('D9-000001'), isNull);
    expect(noticeCode(), 'FA872');
  });

  testWidgets('tela: escolhe o crédito, busca o documento e sugere o menor entre o saldo e o que falta', (tester) async {
    late String code;
    await tester.runAsync(() async {
      code = await sold(code: '2');
      final sale = (await controller.findSaleForReturn(code))!;
      final itemId = (sale['items'] as List).single['id'] as String;
      await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Troca', destination: 'credit');
    });
    api.returnCreditResponse['D1-000001'] = const ApiException('FA001');
    newSale(2);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('method-return_credit')));
    await tester.pump();
    // Sem a busca, avisa e não lança.
    await tester.tap(find.byKey(const Key('add-payment')));
    await tester.pump();
    expect(find.textContaining('busque o crédito'), findsOneWidget);
    expect(controller.cart.payments, isEmpty);
    await tester.enterText(find.byKey(const Key('credit-code')), 'd1-000001');
    await tester.tap(find.byKey(const Key('find-credit')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Crédito D1-000001: saldo de R\$ 10,00'), findsOneWidget);
    expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('payment-amount')), matching: find.byType(EditableText))).controller.text, '10,00');
    await tester.tap(find.byKey(const Key('add-payment')));
    await tester.pump();
    expect(controller.cart.payments.single.returnCode, 'D1-000001');
    expect(find.text('Crédito de devolução D1-000001'), findsOneWidget);
    expect(find.text('Falta: R\$ 10,00'), findsOneWidget);
    expect(find.byKey(const Key('credit-balance')), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });
}
