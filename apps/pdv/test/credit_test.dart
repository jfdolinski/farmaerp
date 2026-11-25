import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/credit.dart';
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
const dependentId = '019a0000-0000-7000-8000-000000000033';

// Venda em 24/11/2026 às 10h05 (horário de Brasília): fatura que fecha dia 25, vence 10/12.
final synced = DateTime.utc(2026, 11, 24, 13);
late String pin;

PullItem user(String id, int code, String name, Map<String, Object?> limits) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell', 'sales.return'],
  'limits': limits, 'pin_hash': pin,
});

Map<String, Object?> credit({String status = 'active', List<Map<String, Object?>> installments = const []}) => {
  'account_id': '019a0000-0000-7000-8000-000000000040',
  'status': status,
  'credit_limit': 100,
  'terms': {'due_mode': 'closing', 'closing_day': 25, 'due_day': 10, 'interval_days': 30, 'own': false},
  'policy': {'late_fee_percent': 2, 'monthly_interest_percent': 1, 'max_installments': 3, 'block_after_days': 30},
  'installments': installments,
  'dependents': [
    {'id': dependentId, 'name': 'Filha', 'relationship': 'child'},
  ],
};

PullItem customer(Map<String, Object?>? creditData) => PullItem(type: 'customer', id: customerId, data: {
  'code': 1, 'person_type': 'individual', 'name': 'Cliente Demonstração', 'document': '11144477735', 'agreements': const [],
  'credit': creditData,
});

LocalDatabase seeded(Map<String, Object?>? creditData) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 5, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'return_days': 7,
        'fixed_seller_id': operatorId,
      }),
      user(operatorId, 3, 'Operador Centro', const {'cash_withdrawal': 1000, 'credit_sale': 50}),
      user(managerId, 2, 'Gerente Centro', const {'cash_withdrawal': 1000, 'credit_sale': 500}),
      PullItem(type: 'product', id: dipirona, data: {
        'code': 1, 'name': 'Dipirona 500 mg', 'status': 'active', 'price': 10, 'fraction_quantity': 1, 'batch_required': false,
        'barcodes': [
          {'id': '019a0000-0000-7001-8000-000000000027', 'code': '7890000000017', 'is_primary': true, 'fraction_quantity': null},
        ],
        'taxes': const [],
      }),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
      customer(creditData),
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

  PosController controllerFor(LocalDatabase db) => PosController(
    database: db,
    auth: PosAuth(database: db, clock: () => now),
    printer: () => printer,
    terminalNumber: () => 1,
    saleForReturn: (code) => api.saleForReturn(accessToken: 't', code: code),
    clock: () => now,
  );

  void start(Map<String, Object?>? creditData) {
    api = FakeApi();
    database = seeded(creditData);
    printer = FakePrinter();
    now = synced.add(const Duration(minutes: 5));
    controller = controllerFor(database);
  }

  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  void identify() {
    final row = database.customerById(customerId)!;
    controller.cart.customer = SaleCustomer(
      id: customerId,
      name: row['name']! as String,
      code: row['code']! as int,
      credit: CreditAccount.fromJson(row['credit']),
    );
  }

  Future<void> sellItems(int quantity) async {
    if (controller.operator == null) {
      await controller.login('3', '2468');
      controller.openShift(10000);
    }
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, quantity * 1000);
    identify();
    controller.startPayment();
  }

  List<Map<String, Object?>> outbox(String kind) =>
      database.nextOutboxBatch().where((item) => item.kind == kind).map((item) => item.payload).toList();

  test('venda no crediário: parcelas, liberação acima do limite do operador, payload e comprovante', () async {
    start(credit());
    await sellItems(6);
    expect(controller.saleCredit!.availableCents, 10000);
    expect(controller.checkCreditPayment(6000, 4), isFalse);
    expect(noticeCode(), 'FA843');
    // R$ 60 passa do limite de crediário do operador (R$ 50): precisa de quem libere.
    expect(controller.creditNeedsRelease(6000), isTrue);
    controller.addPayment(Payment(method: PaymentMethod.storeCredit, amountCents: 6000, installments: controller.creditPlan(6000, 2)));
    expect(noticeCode(), 'FA845');
    expect(await controller.releaseCredit(6000, '3', '2468', ''), isNull);
    expect(noticeCode(), 'FA845');
    final release = await controller.releaseCredit(6000, '2', '2468', 'Cliente antigo');
    expect(release?.supervisorName, 'Gerente Centro');
    final plan = controller.creditPlan(6000, 2);
    expect([for (final i in plan) '${i.dueDate} ${i.amountCents}'], ['2026-12-10 3000', '2027-01-10 3000']);
    controller.addPayment(Payment(
      method: PaymentMethod.storeCredit, amountCents: 6000, installments: plan, dependentId: dependentId, dependentName: 'Filha',
      creditRelease: release,
    ));
    expect(controller.notice, isNull);
    await controller.finish();
    final payment = (outbox('sale').single['payments'] as List).single as Map<String, dynamic>;
    expect(payment['method'], 'store_credit');
    expect(payment['installments'], [
      {'number': 1, 'due_date': '2026-12-10', 'amount': 30.0},
      {'number': 2, 'due_date': '2027-01-10', 'amount': 30.0},
    ]);
    expect(payment['dependent_id'], dependentId);
    expect(payment['release'], {'supervisor_id': managerId, 'reason': 'Cliente antigo'});
    final printed = printer.printed[controller.lastSale!.code]!.map((line) => line.text).join('\n');
    expect(printed, contains('Crediário 2x'));
    expect(printed, contains('1/2 vence 10/12/2026'));
    expect(printed, contains('Comprado por Filha'));
    expect(printed, contains('Reconheço a compra no crediário.'));

    // A venda ainda não subiu: o disponível já desconta.
    await sellItems(5);
    expect(controller.saleCredit!.availableCents, 4000);
    expect(controller.checkCreditPayment(5000, 1), isFalse);
    expect(noticeCode(), 'FA842');
    // Outras formas de pagamento não levam as parcelas.
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 5000));
    await controller.finish();
    expect((outbox('sale').last['payments'] as List).single, isNot(contains('installments')));
  });

  test('crediário bloqueado ou com atraso além do prazo não vende; sem conta, também não', () async {
    start(credit(status: 'blocked'));
    await sellItems(1);
    expect(controller.checkCreditPayment(1000, 1), isFalse);
    expect(noticeCode(), 'FA840');
    database.close();

    start(credit(installments: [
      {'id': '019a0000-0000-7000-8000-000000000041', 'number': 1, 'due_date': '2026-10-10', 'amount': 20, 'principal_open': 20,
       'fee_base': 20, 'fee_paid': 0, 'interest_open': 0, 'accrued_until': '2026-10-10'},
    ]));
    await sellItems(1);
    expect(controller.saleCredit!.overdueDays, 45);
    expect(controller.checkCreditPayment(1000, 1), isFalse);
    expect(noticeCode(), 'FA841');
    database.close();

    start(null);
    await sellItems(1);
    expect(controller.cart.customer!.credit, isNull);
    expect(controller.checkCreditPayment(1000, 1), isFalse);
    expect(noticeCode(), 'FA834');
  });

  test('recebimento: abate encargos e parcela, vai para a gaveta e para a outbox; acima do devido, recusa', () async {
    start(credit(installments: [
      {'id': '019a0000-0000-7000-8000-000000000041', 'number': 1, 'due_date': '2026-11-14', 'amount': 50, 'principal_open': 50,
       'fee_base': 50, 'fee_paid': 0, 'interest_open': 0, 'accrued_until': '2026-11-14'},
    ]));
    await controller.login('3', '2468');
    controller.openShift(10000);
    expect(controller.creditCustomers('demonstra').map((c) => c.code), [1]);
    final found = controller.creditForReceipt(customerId)!;
    // 10 dias de atraso: multa de R$ 1,00 e juros de R$ 0,17.
    expect(found.account.summary(controller.creditToday).totalOpenCents, 5117);
    expect(await controller.receiveCredit(customerId: customerId, amountCents: 5118, method: 'cash'), isFalse);
    expect(noticeCode(), 'FA844');
    final drawer = database.cashInDrawerCents(controller.session!.id);
    expect(await controller.receiveCredit(customerId: customerId, amountCents: 2000, method: 'cash'), isTrue);
    expect(outbox('credit_payment').single, containsPair('amount', 20.0));
    expect(outbox('credit_payment').single, containsPair('customer_id', customerId));
    expect(database.cashInDrawerCents(controller.session!.id) - drawer, 2000);
    final receipt = printer.printed['crediario']!.map((line) => line.text).join('\n');
    expect(receipt, contains('RECEBIMENTO DO CREDIÁRIO'));
    expect(receipt, contains('Multa e juros'));
    // O que ainda não subiu já abate: sobram R$ 31,17 (os R$ 20 cobriram R$ 1,17 de encargos e R$ 18,83 da parcela).
    expect(controller.creditForReceipt(customerId)!.account.summary(controller.creditToday).totalOpenCents, 3117);
    // Pix não entra na gaveta.
    expect(await controller.receiveCredit(customerId: customerId, amountCents: 100, method: 'pix'), isTrue);
    expect(database.cashInDrawerCents(controller.session!.id) - drawer, 2000);
    // Com venda em andamento, não recebe.
    controller.scan('7890000000017');
    expect(await controller.receiveCredit(customerId: customerId, amountCents: 100, method: 'cash'), isFalse);
    expect(noticeCode(), 'FA998');
  });

  test('devolução de venda no crediário pode abater o crediário; de venda em dinheiro, não', () async {
    start(credit());
    await sellItems(2);
    final plan = controller.creditPlan(2000, 1);
    controller.addPayment(Payment(method: PaymentMethod.storeCredit, amountCents: 2000, installments: plan));
    await controller.finish();
    final creditSale = controller.lastSale!.code;
    await sellItems(1);
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 1000));
    await controller.finish();
    final cashSale = controller.lastSale!.code;
    api.saleForReturnResponse[creditSale] = const ApiException('FA001');
    api.saleForReturnResponse[cashSale] = const ApiException('FA001');

    await controller.login('2', '2468');
    final sale = (await controller.findSaleForReturn(creditSale))!;
    expect(sale['has_store_credit'], isTrue);
    final itemId = (sale['items'] as List).single['id'] as String;
    final done = await controller.makeReturn(sale: sale, quantities: {itemId: 1000}, reason: 'Defeito', destination: 'store_credit');
    expect(done?.destination, 'store_credit');
    // O abatimento já conta no crediário do terminal: R$ 20 menos R$ 10.
    expect(controller.creditForReceipt(customerId)!.account.summary(controller.creditToday).principalOpenCents, 1000);

    final other = (await controller.findSaleForReturn(cashSale))!;
    final otherItem = (other['items'] as List).single['id'] as String;
    expect(await controller.makeReturn(sale: other, quantities: {otherItem: 1000}, reason: 'Defeito', destination: 'store_credit'), isNull);
    expect(noticeCode(), 'FA846');
  });

  testWidgets('tela: crediário só com conta; parcelas na tela; liberação pedida acima do limite', (tester) async {
    start(credit());
    await tester.runAsync(() => sellItems(2));
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('method-store_credit')));
    await tester.pump();
    expect(findText(r'Crediário: disponível R$ 100,00 de R$ 100,00'), findsOneWidget);
    expect(findText(r'1/1 vence 10/12/2026: R$ 20,00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('payment-amount')), '20,00');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('add-payment')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('add-payment')));
    await tester.pump();
    expect(controller.cart.payments.single.method, PaymentMethod.storeCredit);
    expect(findText('Crediário 1x'), findsOneWidget);
    controller.cart.payments.clear();
    // Acima do limite do operador (R$ 50): abre a liberação.
    controller.setQuantity(controller.cart.lines.single, 6000);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('payment-amount')), '60,00');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('add-payment')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('add-payment')));
    await tester.pump();
    expect(find.byKey(const Key('credit-release-dialog')), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('tela: sem crediário, a forma não aparece', (tester) async {
    start(null);
    await tester.runAsync(() => sellItems(1));
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    expect(find.byKey(const Key('method-store_credit')), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('tela: receber crediário pela busca do cliente', (tester) async {
    start(credit(installments: [
      {'id': '019a0000-0000-7000-8000-000000000041', 'number': 1, 'due_date': '2026-12-10', 'amount': 50, 'principal_open': 50,
       'fee_base': 50, 'fee_paid': 0, 'interest_open': 0, 'accrued_until': '2026-12-10'},
    ]));
    await tester.runAsync(() async {
      await controller.login('3', '2468');
      controller.openShift(10000);
    });
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('credit-receipt-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('credit-search')), 'demonstra');
    await tester.pump();
    await tester.tap(find.byKey(const Key('credit-customer-1')));
    await tester.pump();
    expect(findText(r'Total em aberto hoje: R$ 50,00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('credit-amount')), '30,00');
    await tester.tap(find.byKey(const Key('credit-confirm')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('credit-receipt-dialog')), findsNothing);
    expect(outbox('credit_payment').single, containsPair('amount', 30.0));
    await tester.binding.setSurfaceSize(null);
  });
}
