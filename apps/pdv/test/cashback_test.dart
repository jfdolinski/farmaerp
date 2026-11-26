import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show FakeApi;
import 'caps_finders.dart';
import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const customerId = '019a0000-0000-7000-8000-000000000032';

final synced = DateTime.utc(2026, 11, 24, 13);
late String pin;

PullItem user(String id, int code, String name, {List<String> extra = const []}) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': ['sales.sell', 'sales.return', ...extra],
  'limits': const {'cash_withdrawal': 1000}, 'pin_hash': pin,
});

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 6, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'return_days': 7,
        'fixed_seller_id': operatorId,
      }),
      user(operatorId, 3, 'Operador Centro'),
      user(managerId, 2, 'Gerente Centro', extra: const ['pdv.sale_cancel']),
      PullItem(type: 'product', id: dipirona, data: {
        'code': 1, 'name': 'Dipirona 500 mg', 'status': 'active', 'price': 10, 'fraction_quantity': 1, 'batch_required': false,
        'cashback': 5,
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
      cashbackBalance: (id) => api.cashback(accessToken: 't', customerId: id),
      cashbackReserve: (id, amount, total) => api.cashbackReserve(accessToken: 't', customerId: id, amount: amount, saleTotal: total),
      cashbackRelease: (id) => api.cashbackRelease(accessToken: 't', reservationId: id),
      clock: () => now,
    );
    api.cashbackBalances[customerId] = {
      'available': 20, 'waiting': 0, 'consent': true, 'policy': {'max_use_percent': 50, 'waiting_days': 0, 'validity_days': 90},
    };
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  Future<void> sell(int quantity) async {
    if (controller.operator == null) {
      await controller.login('3', '2468');
      controller.openShift(10000);
    }
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, quantity * 1000);
    controller.cart.customer = const SaleCustomer(id: customerId, name: 'Cliente Demonstração', code: 1);
    controller.startPayment();
    await controller.loadCashback();
  }

  List<Map<String, Object?>> outbox(String kind) =>
      database.nextOutboxBatch().where((item) => item.kind == kind).map((item) => item.payload).toList();

  test('uso com reserva até o máximo da rede; o comprovante mostra o ganho sobre o pago sem cashback', () async {
    await sell(3);
    // Compra de R$ 30: o cashback paga até 50% (R$ 15), e o saldo é R$ 20.
    expect(controller.cashbackUsableCents, 1500);
    expect(await controller.addCashback(1600), isFalse);
    expect(noticeCode(), 'FA851');
    expect(await controller.addCashback(1000), isTrue);
    expect(controller.cashbackUsableCents, 500);
    final payment = controller.cart.payments.single;
    expect([payment.method, payment.amountCents, payment.reservationId], [PaymentMethod.cashback, 1000, isNotNull]);
    // Ganho: 5% sobre os R$ 20 pagos sem cashback.
    expect(controller.cashbackEarnEstimateCents, 100);
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2000));
    await controller.finish();
    final sold = (outbox('sale').single['payments'] as List).cast<Map<String, dynamic>>();
    expect(sold.first, containsPair('reservation_id', payment.reservationId));
    expect(sold.first['method'], 'cashback');
    final printed = printer.printed[controller.lastSale!.code]!.map((line) => line.text).join('\n');
    expect(printed, contains('Cashback ganho'));
    expect(printed, contains('1,00'));
    expect(api.released, isEmpty);
  });

  test('desistência libera a reserva: tirar o pagamento, voltar aos itens ou trocar o cliente', () async {
    await sell(3);
    await controller.addCashback(500);
    final first = controller.cart.payments.single.reservationId!;
    controller.removePayment(controller.cart.payments.single);
    await Future<void>.delayed(Duration.zero);
    expect(api.released, [first]);
    expect(controller.cashbackUsableCents, 1500);
    await controller.addCashback(500);
    final second = controller.cart.payments.single.reservationId!;
    controller.backToItems();
    await Future<void>.delayed(Duration.zero);
    expect(api.released, [first, second]);
  });

  test('venda cancelada no caixa (descartada) libera a reserva do cashback', () async {
    await sell(3);
    await controller.addCashback(500);
    final reservation = controller.cart.payments.single.reservationId!;
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '2468'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(api.released, [reservation]);
    expect(controller.cashbackUsableCents, 0);
  });

  test('sem internet ou sem consentimento, não usa', () async {
    api.cashbackFailure = const ApiException('FA001');
    await sell(3);
    expect(controller.cashbackOffline, isTrue);
    expect(await controller.addCashback(500), isFalse);
    expect(noticeCode(), 'FA855');
    expect(controller.cart.payments, isEmpty);
    api.cashbackFailure = null;
    api.cashbackBalances[customerId]!['consent'] = false;
    await controller.loadCashback();
    expect(controller.cashbackUsableCents, 0);
    expect(controller.cashbackEarnEstimateCents, 0);
    expect(await controller.addCashback(500), isFalse);
    expect(noticeCode(), 'FA849');
  });

  test('devolução: a parte do cashback volta como cashback, fechando no centavo; o destino recebe o resto', () async {
    await sell(3);
    await controller.addCashback(1000);
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2000));
    await controller.finish();
    final code = controller.lastSale!.code;
    api.saleForReturnResponse[code] = const ApiException('FA001');
    await controller.login('2', '2468');
    final refunded = <int>[];
    for (var n = 0; n < 3; n += 1) {
      final sale = (await controller.findSaleForReturn(code))!;
      final itemId = (sale['items'] as List).single['id'] as String;
      final done = (await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Troca', destination: 'cash'))!;
      // O resultado traz o que vai para o destino (para a sangria): R$ 10 menos a parte do cashback.
      refunded.add(1000 - done.totalCents);
      final document = database.localCashReturn(done.code)!;
      expect(((document['total'] as num) * 100).round(), done.totalCents);
      final printed = printer.printed[done.code]!.map((line) => line.text).join('\n');
      expect(printed, contains('Volta como cashback'));
    }
    expect(refunded, [333, 334, 333]);
  });

  testWidgets('tela: cashback só com cliente; mostra o saldo e o máximo, e lança com a reserva', (tester) async {
    await tester.runAsync(() => sell(3));
    controller.saleCashback = null;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('method-cashback')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(findText(r'Cashback: saldo R$ 20,00 · pode usar até R$ 15,00 nesta compra'), findsOneWidget);
    expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('payment-amount')), matching: find.byType(EditableText))).controller.text, '15,00');
    await tester.ensureVisible(find.byKey(const Key('add-payment')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('add-payment')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(controller.cart.payments.single.method, PaymentMethod.cashback);
    controller.clearCustomer();
    await tester.pump();
    expect(find.byKey(const Key('method-cashback')), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });
}
