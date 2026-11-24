import 'dart:io';

import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/pos/receipt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const clerkId = '019a0000-0000-7000-8000-0000000000c1';
const stockistId = '019a0000-0000-7000-8000-0000000000c2';
const supervisorId = '019a0000-0000-7000-8000-00000000000d';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const clonazepam = '019a0000-0000-7000-8000-000000000033';

final synced = DateTime(2026, 11, 24, 10);
late String pin;

PullItem user(String id, int code, String name, List<String> permissions, {Map<String, Object?> limits = const {}}) =>
    PullItem(type: 'user', id: id, data: {
      'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions, 'limits': limits, 'pin_hash': pin,
    });

PullItem product(String id, int code, String name, String barcode, {String? controlledClass}) => PullItem(
  type: 'product',
  id: id,
  data: {
    'code': code, 'name': name, 'status': 'active', 'price': 10, 'fraction_quantity': 1, 'batch_required': false,
    'controlled_class': controlledClass, 'max_discount': 20,
    'barcodes': [
      {'id': id.replaceFirst('7000', '7001'), 'code': barcode, 'is_primary': true, 'fraction_quantity': null},
    ],
    'taxes': const [],
  },
);

LocalDatabase seeded({String profile = 'cashier', bool pinRequired = false, int validity = 0}) {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 3, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181'},
        'company': {'trade_name': 'Farmácia Demonstração'},
        'series': const [],
        'last_sale_number': null,
        'last_quote_number': 3,
        'terminal_profile': profile,
        'seller_pin_required': pinRequired,
        'quote_validity_days': validity,
      }),
      user(operatorId, 3, 'Operador Centro', const ['sales.sell', 'sales.quote']),
      user(clerkId, 6, 'Balconista Ana', const ['sales.quote'], limits: const {'sale_discount': 5}),
      user(stockistId, 7, 'Estoquista', const ['stock.view']),
      user(supervisorId, 2, 'Gerente Centro', const ['sales.sell', 'sales.quote'], limits: const {'sale_discount': 15}),
      product(dipirona, 1, 'Dipirona 500 mg', '7890000000017'),
      product(clonazepam, 4, 'Clonazepam 2 mg', '7890000000055', controlledClass: 'B1'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 1, 'batches': []}),
    ]),
    now: synced,
  );
  return database;
}

void main() {
  late LocalDatabase database;
  late FakePrinter printer;
  late DateTime now;
  late PosController controller;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  PosController build(LocalDatabase db) => PosController(
    database: db,
    auth: PosAuth(database: db, clock: () => now),
    printer: () => printer,
    terminalNumber: () => 1,
    clock: () => now,
  );

  setUp(() {
    printer = FakePrinter();
    now = synced.add(const Duration(minutes: 5));
  });
  tearDown(() => database.close());

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  group('vendedor no caixa', () {
    setUp(() {
      database = seeded();
      controller = build(database);
    });

    test('cada venda pede o código; quem não orça nem vende não é vendedor', () async {
      await controller.login('3', '2468');
      controller.openShift(0);
      expect(controller.quoteMode, isFalse);
      controller.scan('7890000000017');
      expect([noticeCode(), controller.cart.isEmpty], ['FA881', true]);
      expect(await controller.identifySeller('99'), isFalse);
      expect(noticeCode(), 'FA880');
      expect(await controller.identifySeller('7'), isFalse);
      expect(noticeCode(), 'FA880');
      expect(await controller.identifySeller('6'), isTrue);
      expect(controller.seller?.name, 'Balconista Ana');
      controller.scan('7890000000017');
      expect(controller.cart.lines, hasLength(1));
      // Trocar o vendedor mantém os itens.
      controller.changeSeller();
      expect([controller.seller, controller.cart.lines.length], [null, 1]);
      await controller.identifySeller('6');

      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 1000));
      await controller.finish();
      final sale = database.nextOutboxBatch().last.payload;
      expect(sale['seller_id'], clerkId);
      expect(printer.printed.values.last.map((line) => line.text), contains('Vendedor: Balconista Ana'));
      // Nova venda: pede de novo.
      expect(controller.seller, isNull);
      controller.scan('7890000000017');
      expect(noticeCode(), 'FA881');
    });

    test('com o parâmetro da filial, o vendedor digita o PIN', () async {
      database.close();
      database = seeded(pinRequired: true);
      controller = build(database);
      await controller.login('3', '2468');
      controller.openShift(0);
      expect(await controller.identifySeller('6'), isFalse);
      expect(noticeCode(), 'FA966');
      expect(await controller.identifySeller('6', '1111'), isFalse);
      expect(noticeCode(), 'FA966');
      expect(await controller.identifySeller('6', '2468'), isTrue);
    });

    test('vendedor fixo do terminal entra sozinho e não pede o código', () async {
      database.close();
      database = seeded();
      database.applyPage(
        PullPage(format: 3, until: '11', items: [
          PullItem(type: 'fiscal', id: branchId, data: {
            'branch': {'id': branchId, 'name': 'Loja Centro'}, 'company': const {}, 'series': const [],
            'terminal_profile': 'self_service', 'fixed_seller_id': clerkId,
          }),
        ]),
        now: synced,
      );
      controller = build(database);
      await controller.login('3', '2468');
      controller.openShift(0);
      controller.scan('7890000000017');
      expect(controller.cart.lines, hasLength(1));
      expect(controller.seller?.id, clerkId);
    });
  });

  group('terminal de orçamento', () {
    setUp(() {
      database = seeded(profile: 'quote', validity: 2);
      controller = build(database);
    });

    test('sem entrada nem turno; controlado e falta de estoque só avisam; desconto pelo limite do vendedor', () async {
      expect(controller.quoteMode, isTrue);
      expect(controller.operator, isNull);
      await controller.identifySeller('6');
      controller.scan('7890000000055');
      expect(controller.pendingControlled, isNull);
      controller.scan('7890000000017');
      controller.scan('7890000000017');
      expect(controller.cart.lines.map((l) => [l.product.code, l.quantityMilli]), [[4, 1000], [1, 2000]]);
      expect(controller.notice, isNull);
      // Limite da balconista: 5%.
      final line = controller.cart.lines.last;
      expect(controller.applyDiscount(line, 100).name, 'none');
      expect(line.discountCents, 100);
      expect(controller.applyDiscount(line, 200).name, 'release');
      expect(await controller.releaseDiscount(line, 200, '2', '2468', 'Cliente antigo'), isTrue);
      expect(line.release?.supervisorName, 'Gerente Centro');
    });

    test('conclui com plaquinha e cupom; sobe com o vendedor e volta a pedir o código', () async {
      await controller.identifySeller('6');
      controller.scan('7890000000017');
      expect(await controller.finishQuote(cardNumber: 0), isFalse);
      expect(noticeCode(), 'FA882');
      expect(await controller.finishQuote(cardNumber: 10000), isFalse);
      expect(noticeCode(), 'FA882');
      expect(await controller.finishQuote(cardNumber: 15), isTrue);
      expect(controller.info, 'Orçamento O1-000004 concluído na plaquinha 15.');
      expect(controller.cart.isEmpty, isTrue);
      expect(controller.seller, isNull);
      final quote = database.nextOutboxBatch().last;
      expect(quote.kind, 'quote');
      expect(quote.payload, containsPair('number', 4));
      expect(quote.payload, containsPair('seller_id', clerkId));
      expect(quote.payload, containsPair('card_number', 15));
      expect(quote.payload['items'], [
        containsPair('quantity', 1.0),
      ]);
      expect(quote.payload['total'], 10.0);
      final coupon = printer.printed['O1-000004']!;
      final text = coupon.map((line) => line.text).join('\n');
      expect(text, contains('ORÇAMENTO'));
      expect(text, contains('Plaquinha 15'));
      expect(text, contains('Vendedor: Balconista Ana'));
      expect(text, contains('Válido até 26/11/2026'));
      expect(coupon.last.barcode, isTrue);
      expect(coupon.last.text, 'O1-000004');
      expect(database.nextQuoteNumber, 5);

      // Plaquinha sem cupom: não imprime. Sem plaquinha: o cupom sai sempre.
      await controller.identifySeller('6');
      controller.scan('7890000000017');
      expect(await controller.finishQuote(cardNumber: 16, printCoupon: false), isTrue);
      expect(printer.printed.containsKey('O1-000005'), isFalse);
      await controller.identifySeller('6');
      controller.scan('7890000000017');
      expect(await controller.finishQuote(printCoupon: false), isTrue);
      expect(printer.printed.containsKey('O1-000006'), isTrue);
      expect(database.nextOutboxBatch().where((item) => item.kind == 'quote').map((item) => item.payload['card_number']), [15, 16, null]);
      // Reimprime o último.
      printer.printed.clear();
      await controller.reprint();
      expect(printer.printed.keys, ['O1-000006']);
    });

    test('o código de barras do cupom sai em Code 128 na térmica', () {
      final bytes = encodeEscPos(const [ReceiptLine.barcode('O1-000004')]);
      final data = 'O1-000004'.codeUnits;
      final start = List.generate(bytes.length - 5, (i) => i).firstWhere((i) => bytes[i] == 0x1D && bytes[i + 1] == 0x6B);
      expect(bytes.sublist(start, start + 6 + data.length), [0x1D, 0x6B, 73, data.length + 2, 0x7B, 0x42, ...data]);
    });

    test('sem impressora, o cupom com o código de barras sai em PDF', () async {
      final directory = Directory.systemTemp.createTempSync('pdv-quote-pdf');
      addTearDown(() => directory.deleteSync(recursive: true));
      final pdf = PdfReceiptPrinter(directory);
      await pdf.print('O1-000004', const [ReceiptLine('ORÇAMENTO', center: true), ReceiptLine.barcode('O1-000004')]);
      expect(pdf.lastFile!.lengthSync(), greaterThan(1000));
    });

    testWidgets('tela: pede o vendedor, monta e conclui com a plaquinha', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
      expect(find.text('Orçamento'), findsOneWidget);
      expect(find.byKey(const Key('login-code')), findsNothing);
      expect(find.byKey(const Key('seller-panel')), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('scan-field'))).enabled, isFalse);
      expect(find.byKey(const Key('seller-pin')), findsNothing);
      await tester.enterText(find.byKey(const Key('seller-code')), '6');
      await tester.tap(find.byKey(const Key('seller-confirm')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Vendedor: Balconista Ana'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('scan-field')), '7890000000017');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(controller.cart.lines, hasLength(1));
      await tester.enterText(find.byKey(const Key('quote-card')), '15');
      await tester.pump();
      await tester.tap(find.byKey(const Key('quote-finish')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.text('Orçamento O1-000004 concluído na plaquinha 15.'), findsOneWidget);
      expect(find.byKey(const Key('seller-panel')), findsOneWidget);
      expect(find.textContaining('Último orçamento: O1-000004'), findsOneWidget);
    });
  });
}
