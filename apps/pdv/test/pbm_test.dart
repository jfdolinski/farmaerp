import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/discount.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show FakeApi;
import 'pos_test.dart' show FakePrinter, hashFor;

// PBM no caixa (com o programa de teste da central simulado): aplica o preço do programa nos itens
// aceitos, confirma com a venda antes de gravar e desfaz quando a venda não acontece.

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const soro = '019a0000-0000-7000-8000-000000000033';
const programId = '019a0000-0000-7000-8000-0000000007a1';

final synced = DateTime.utc(2026, 11, 28, 13);
late String pin;

PullItem user(String id, int code, String name, {List<String> extra = const []}) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': ['sales.sell', ...extra],
  'limits': const {'sale_discount': 10}, 'pin_hash': pin,
});

PullItem product(String id, int code, String name, num price, String barcode) => PullItem(type: 'product', id: id, data: {
  'code': code, 'name': name, 'status': 'active', 'price': price, 'fraction_quantity': 1, 'batch_required': false,
  'barcodes': [
    {'id': '${id.substring(0, 30)}1${id.substring(31)}', 'code': barcode, 'is_primary': true, 'fraction_quantity': null},
  ],
  'taxes': const [],
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
      product(dipirona, 1, 'Dipirona 500 mg', 25.9, '7890000000017'),
      product(soro, 2, 'Soro fisiológico', 10, '7890000000055'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
      const PullItem(type: 'stock', id: soro, data: {'quantity': 50, 'batches': []}),
    ]),
    now: synced,
  );
  return database;
}

void main() {
  late FakeApi api;
  late LocalDatabase database;
  late FakePrinter printer;
  late PosController controller;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() {
    api = FakeApi()
      ..pbmProgramList = [
        {'id': programId, 'name': 'Programa de teste'},
      ]
      ..pbmPercent[dipirona] = 40;
    database = seeded();
    printer = FakePrinter();
    final now = synced.add(const Duration(minutes: 5));
    controller = PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => printer,
      terminalNumber: () => 1,
      pbmPrograms: () => api.pbmPrograms(accessToken: 't'),
      pbmAuthorize: (program, beneficiary, items) => api.pbmAuthorize(accessToken: 't', programId: program, beneficiary: beneficiary, items: items),
      pbmConfirm: (id, saleId) => api.pbmConfirm(accessToken: 't', authorizationId: id, saleId: saleId),
      pbmUndo: (id, reason) => api.pbmUndo(accessToken: 't', authorizationId: id, reason: reason),
      clock: () => now,
    );
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');
  List<Map<String, Object?>> outbox(String kind) =>
      database.nextOutboxBatch().where((item) => item.kind == kind).map((item) => item.payload).toList();

  /// Duas dipironas e um soro na venda.
  Future<void> cart() async {
    await controller.login('3', '2468');
    controller.openShift(10000);
    controller.scan('7890000000017');
    controller.setQuantity(controller.cart.lines.single, 2000);
    controller.scan('7890000000055');
  }

  Future<bool> apply([String document = '529.982.247-25']) =>
      controller.applyPbm(programId: programId, programName: 'Programa de teste', beneficiary: document);

  test('aplica o preço do programa só nos itens aceitos; manda o PBM no item e confirma antes de gravar; o comprovante mostra a economia', () async {
    await cart();
    final dipironaLine = controller.cart.lines.first;
    // Desconto manual (dentro do limite) sai quando o PBM entra.
    expect(controller.applyDiscount(dipironaLine, 100), DiscountNeed.none);
    expect(dipironaLine.discountCents, 100);
    expect(await apply(), isTrue);
    expect(api.pbmRequests.single, {
      'programId': programId,
      'beneficiary': '52998224725',
      'items': [
        {'productId': dipirona, 'quantity': 2.0, 'unitPrice': 25.9},
        {'productId': soro, 'quantity': 1.0, 'unitPrice': 10.0},
      ],
    });
    // 40% em cada dipirona: R$ 15,54 por unidade, economia de R$ 20,72; o soro fica como estava.
    expect(dipironaLine.pbm!.pbmPriceCents, 1554);
    expect(dipironaLine.discountCents, 2072);
    expect(controller.cart.lines.last.pbm, isNull);
    expect(controller.cart.totalCents, 5180 - 2072 + 1000);
    expect(controller.cart.pbm!.beneficiaryMasked, '********725');
    expect(controller.info, contains('economia de R\$ 20,72'));
    // O item do PBM não aceita outro desconto.
    expect(controller.applyDiscount(dipironaLine, 100), DiscountNeed.none);
    expect(noticeCode(), 'FA800');
    expect(dipironaLine.discountCents, 2072);

    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: controller.cart.totalCents));
    await controller.finish();
    final sale = outbox('sale').single;
    final items = (sale['items']! as List).cast<Map<String, dynamic>>();
    expect(items.first, containsPair('pbm', {'authorization_id': api.pbmConfirmed.keys.single, 'discount': 20.72}));
    expect(items.first, containsPair('discount', 20.72));
    expect(items.first, containsPair('auto_discount', 0.0));
    expect(items.last['pbm'], isNull);
    expect(api.pbmConfirmed.values.single, sale['id']);
    expect(api.pbmUndone, isEmpty);
    final printed = printer.printed[controller.lastSale!.code]!.map((line) => line.text).join('\n');
    expect(printed, contains('PBM Programa de teste'));
    expect(printed, contains('20,72'));
    expect(printed, contains('Autorização TESTE-1'));
    expect(printed, contains('********725'));
    expect(printed, isNot(contains('52998224725')));
  });

  test('sem internet, sem direito ou sem item do programa: aviso, e a venda segue pelo preço normal', () async {
    await cart();
    api.pbmFailure = const ApiException('FA001');
    expect(await controller.loadPbmPrograms(), isNull);
    expect(noticeCode(), 'FA797');
    expect(await apply(), isFalse);
    expect(noticeCode(), 'FA797');
    api.pbmFailure = null;
    expect(await apply('11144477730'), isFalse);
    expect(noticeCode(), 'FA794');
    api.pbmPercent.clear();
    expect(await apply(), isFalse);
    expect(noticeCode(), 'FA796');
    expect(await apply('12'), isFalse);
    expect(noticeCode(), 'FA005');
    expect(controller.cart.pbm, isNull);
    expect(controller.cart.lines.every((line) => line.pbm == null), isTrue);
  });

  test('mudar o item do programa, tirar o PBM ou cancelar a venda desfaz a autorização', () async {
    await cart();
    expect(await apply(), isTrue);
    final first = controller.cart.pbm!.authorizationId;
    // Mudar o soro (fora do programa) não mexe no PBM.
    controller.setQuantity(controller.cart.lines.last, 2000);
    expect(controller.cart.pbm, isNotNull);
    // Mudar a dipirona desfaz.
    controller.setQuantity(controller.cart.lines.first, 3000);
    await Future<void>.delayed(Duration.zero);
    expect(controller.cart.pbm, isNull);
    expect(controller.cart.lines.first.pbm, isNull);
    expect(controller.info, contains('O PBM foi desfeito'));
    expect(api.pbmUndone, [first]);

    expect(await apply(), isTrue);
    final second = controller.cart.pbm!.authorizationId;
    controller.removePbm();
    await Future<void>.delayed(Duration.zero);
    expect(api.pbmUndone, [first, second]);
    expect(controller.cart.totalCents, 7770 + 2000);

    expect(await apply(), isTrue);
    final third = controller.cart.pbm!.authorizationId;
    // Tirar o item do programa também desfaz.
    controller.remove(controller.cart.lines.first);
    await Future<void>.delayed(Duration.zero);
    expect(api.pbmUndone, [first, second, third]);

    controller.scan('7890000000017');
    expect(await apply(), isTrue);
    final fourth = controller.cart.pbm!.authorizationId;
    expect(await controller.discardCart(supervisorCode: '2', supervisorPin: '2468'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(api.pbmUndone, [first, second, third, fourth]);
  });

  test('confirmação sem internet deixa a venda aberta; a nova tentativa grava com a mesma venda', () async {
    await cart();
    expect(await apply(), isTrue);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: controller.cart.totalCents));
    api.pbmConfirmFailure = const ApiException('FA001');
    await controller.finish();
    expect(noticeCode(), 'FA797');
    expect(controller.lastSale, isNull);
    expect(outbox('sale'), isEmpty);
    expect(controller.cart.pbm!.confirmedSaleId, isNull);
    api.pbmConfirmFailure = null;
    await controller.finish();
    final sale = outbox('sale').single;
    expect(api.pbmConfirmed.values.single, sale['id']);
    expect(controller.cart.pbm, isNull);
  });

  testWidgets('tela: F12 abre o PBM, escolhe o programa, consulta e mostra a economia', (tester) async {
    await tester.runAsync(cart);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.tap(find.byKey(const Key('pbm-open')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pbm-program')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pbm-document')), '52998224725');
    await tester.tap(find.byKey(const Key('pbm-consult')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pbm-applied')), findsOneWidget);
    expect(find.textContaining('20,72'), findsWidgets);
    await tester.binding.setSurfaceSize(null);
  });
}
