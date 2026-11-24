import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/money.dart';
import 'package:farmaerp_pdv/pos/pin.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/pos/receipt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Hash gerado pela API (Node) para o PIN 2468 do seed: o PDV precisa conferir o mesmo formato.
const nodeHash2468 = r'pbkdf2-sha256$210000$DAwMDAwMDAwMDAwMDAwMDA==$0Y+4ZaPrEpWxpjCyiyQsgVU97GA29jxTLVuoyG8WNgc=';

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const clerkId = '019a0000-0000-7000-8000-000000000010';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const caixa10 = '019a0000-0000-7000-8000-000000000031';
const controlled = '019a0000-0000-7000-8000-000000000041';
const noPrice = '019a0000-0000-7000-8000-000000000051';

late String fastHash;

/// Hash com o mínimo de rodadas que o PDV aceita, para os testes andarem rápido.
Future<String> hashFor(String pin) async {
  final salt = List.filled(16, 9);
  final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 100000, bits: 256).deriveKeyFromPassword(password: pin, nonce: salt);
  return 'pbkdf2-sha256\$100000\$${base64.encode(salt)}\$${base64.encode(await key.extractBytes())}';
}

PullItem user(String id, int code, String name, {String? pin, List<String> permissions = const ['sales.sell'], bool admin = false}) => PullItem(
  type: 'user',
  id: id,
  data: {'code': code, 'name': name, 'is_admin': admin, 'roles': const [], 'permissions': permissions, 'limits': const {}, 'pin_hash': pin},
);

PullItem product(String id, int code, String name, {num? price = 12.9, String? controlledClass, String? barcode, String barcodeId = '', num? fraction, String? ingredient, String? manufacturer}) =>
    PullItem(
      type: 'product',
      id: id,
      data: {
        'code': code,
        'name': name,
        'manufacturer': manufacturer,
        'active_ingredient': ingredient,
        'controlled_class': controlledClass,
        'status': 'active',
        'price': price,
        'fraction_quantity': 1,
        'batch_required': false,
        'barcodes': [
          if (barcode != null) {'id': barcodeId, 'code': barcode, 'is_primary': true, 'fraction_quantity': fraction},
        ],
        'taxes': const [],
      },
    );

LocalDatabase seeded() {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 2, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181', 'street': 'Rua A', 'street_number': '10', 'city': 'São Paulo', 'state': 'SP'},
        'company': {'trade_name': 'Farmácia Demonstração', 'legal_name': 'Farmácia Demonstração Ltda'},
        'series': const [],
        'last_sale_number': 7,
        'fixed_seller_id': operatorId,
      }),
      user(operatorId, 3, 'Operador Centro', pin: fastHash),
      user(managerId, 5, 'Gerente Centro', pin: fastHash, permissions: const ['sales.sell', 'sales.view']),
      user(clerkId, 6, 'Balconista', pin: fastHash, permissions: const ['stock.view']),
      user('019a0000-0000-7000-8000-000000000011', 7, 'Sem PIN'),
      product(dipirona, 1, 'Dipirona Sódica 500 mg', barcode: '7890000000017', barcodeId: '019a0000-0000-7000-8000-000000000028',
          ingredient: 'Dipirona', manufacturer: 'Laboratório Demonstração'),
      product(caixa10, 2, 'Soro Fisiológico caixa', price: 2.5, barcode: '7890000000024', barcodeId: '019a0000-0000-7000-8000-000000000032', fraction: 10),
      product(controlled, 3, 'Clonazepam 2 mg', controlledClass: 'B1', barcode: '7890000000031', barcodeId: '019a0000-0000-7000-8000-000000000042'),
      product(noPrice, 4, 'Produto sem preço', price: null, barcode: '7890000000048', barcodeId: '019a0000-0000-7000-8000-000000000052'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 3, 'batches': []}),
      const PullItem(type: 'stock', id: caixa10, data: {'quantity': 50, 'batches': []}),
    ]),
    now: DateTime.utc(2026, 11, 23),
  );
  return database;
}

class FakePrinter implements ReceiptPrinter {
  final printed = <String, List<ReceiptLine>>{};
  Object? failure;

  @override
  String get description => 'teste';

  @override
  Future<void> print(String saleCode, List<ReceiptLine> lines) async {
    if (failure != null) throw failure!;
    printed[saleCode] = lines;
  }
}

void main() {
  setUpAll(() async {
    fastHash = await hashFor('2468');
  });

  group('dinheiro', () {
    test('formata e lê valores e quantidades', () {
      expect([formatCents(0), formatCents(1290), formatCents(123456789), formatCents(-50)], ['R\$ 0,00', 'R\$ 12,90', 'R\$ 1.234.567,89', '-R\$ 0,50']);
      expect([parseCents('12,90'), parseCents('12.9'), parseCents('1.234,56'), parseCents('R\$ 5'), parseCents('5,'), parseCents('abc'), parseCents('')],
          [1290, 1290, 123456, 500, null, null, null]);
      expect([parseMilli('1'), parseMilli('2,5'), parseMilli('0,25'), parseMilli('0'), parseMilli('-1')], [1000, 2500, 250, null, null]);
      expect([formatMilli(1000), formatMilli(2500), formatMilli(250)], ['1', '2,5', '0,25']);
      // Meio centavo arredonda para cima, como a central.
      expect([lineGrossCents(1290, 2000), lineGrossCents(1001, 500), lineGrossCents(333, 333)], [2580, 501, 111]);
    });
  });

  group('PIN', () {
    test('confere o hash gerado pela API e recusa formatos estranhos', () async {
      expect(await verifyPin('2468', nodeHash2468), isTrue);
      expect(await verifyPin('2469', nodeHash2468), isFalse);
      for (final hash in ['', 'md5\$1\$a\$b', nodeHash2468.replaceFirst('210000', '10'), 'pbkdf2-sha256\$210000\$!!!\$abc']) {
        expect(await verifyPin('2468', hash), isFalse);
      }
    });

    test('código e PIN: erro igual para código desconhecido, bloqueio depois de 5 erros', () async {
      final database = seeded();
      addTearDown(database.close);
      var now = DateTime.utc(2026, 11, 23, 10);
      final auth = PosAuth(database: database, clock: () => now);
      Future<String?> codeOf(Future<Object?> call) async {
        try {
          await call;
          return null;
        } on PosException catch (error) {
          return error.code;
        }
      }

      expect((await auth.verify('3', '2468', permission: 'sales.sell')).name, 'Operador Centro');
      expect(await codeOf(auth.verify('99', '2468')), 'FA966');
      expect(await codeOf(auth.verify('abc', '2468')), 'FA966');
      expect(await codeOf(auth.verify('7', '2468')), 'FA968');
      expect(await codeOf(auth.verify('6', '2468', permission: 'sales.sell')), 'FA969');

      for (var i = 0; i < 4; i += 1) {
        expect(await codeOf(auth.verify('3', '0000')), 'FA966');
      }
      expect(await codeOf(auth.verify('3', '0000')), 'FA967');
      // Bloqueado: nem o PIN certo entra.
      expect(await codeOf(auth.verify('3', '2468')), 'FA967');
      now = now.add(const Duration(minutes: 6));
      expect(await codeOf(auth.verify('3', '2468')), isNull);
      // Acerto zera a contagem.
      expect(database.pinAttempts(operatorId).failures, 0);
    });
  });

  group('produtos no caixa', () {
    test('acha pelo código de barras, pelo código e pelo nome sem acento', () {
      final database = seeded();
      addTearDown(database.close);
      expect(database.saleProductByCode('7890000000017')?.id, dipirona);
      expect(database.saleProductByCode('7890000000017')?.stockMilli, 3000);
      expect(database.saleProductByCode('2')?.id, caixa10);
      expect(database.saleProductByCode('999'), isNull);
      List<String> ids(String query) => database.searchSaleProducts(query).map((p) => p.id).toList();
      expect(ids('sodica'), [dipirona]);
      expect(ids('dipi 500'), [dipirona]);
      expect(ids('laborat'), [dipirona]);
      expect(ids('soro fisio'), [caixa10]);
      expect(ids('"; DROP'), isEmpty);
      expect(ids('   '), isEmpty);
      // Produto retirado sai da busca.
      database.applyPage(const PullPage(format: 2, until: '11', items: [PullItem(type: 'product', id: dipirona)]), now: DateTime.utc(2026));
      expect(ids('dipirona'), isEmpty);
    });
  });

  group('venda', () {
    test('carrinho: soma igual, fracionamento, controlado e sem preço', () {
      final database = seeded();
      addTearDown(database.close);
      final cart = Cart();
      cart.add(database.saleProductByCode('7890000000017')!);
      cart.add(database.saleProductByCode('7890000000017')!);
      expect(cart.lines.single.quantityMilli, 2000);
      cart.add(database.saleProductByCode('7890000000024')!);
      expect(cart.lines[1].quantityMilli, 10000);
      expect(cart.totalCents, 2580 + 2500);
      expect(() => cart.add(database.saleProductByCode('7890000000031')!), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA986')));
      expect(() => cart.add(database.saleProductByCode('7890000000048')!), throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA974')));
    });

    test('pagamento: troco só do dinheiro; cartão a mais não fecha', () {
      final database = seeded();
      addTearDown(database.close);
      final cart = Cart()..add(database.saleProductByCode('7890000000017')!);
      cart.payments.add(Payment(method: PaymentMethod.pix, amountCents: 1000));
      expect([cart.remainingCents, cart.changeCents], [290, 0]);
      cart.payments.add(Payment(method: PaymentMethod.cash, amountCents: 500));
      expect([cart.remainingCents, cart.changeCents, cart.overpaidWithoutCash], [0, 210, false]);
      cart.payments
        ..clear()
        ..add(Payment(method: PaymentMethod.creditCard, amountCents: 2000));
      expect(cart.overpaidWithoutCash, isTrue);
    });

    test('a venda sai no formato da central, com número que nunca repete', () {
      final database = seeded();
      addTearDown(database.close);
      final operator = database.userByCode(3)!;
      final session = database.openSession(operator: operator, openingFloatCents: 15000, now: DateTime.utc(2026, 11, 23, 9));
      expect(database.openCashSession?.id, session.id);
      final cart = Cart()
        ..add(database.saleProductByCode('7890000000017')!, quantityMilli: 2000)
        ..add(database.saleProductByCode('7890000000024')!);
      cart.payments
        ..add(Payment(method: PaymentMethod.debitCard, amountCents: 3000, cardBrand: 'Visa', authorizationCode: '123'))
        ..add(Payment(method: PaymentMethod.cash, amountCents: 2500));
      // A central já recebeu a venda 7 deste terminal: a próxima é a 8.
      expect(database.nextSaleNumber, 8);
      final draft = buildSale(cart: cart, session: session, operator: operator, number: database.nextSaleNumber, terminalNumber: 1, now: DateTime.utc(2026, 11, 23, 10));
      expect(draft.code, '1-000008');
      final payload = draft.payload;
      expect(payload['subtotal'], 50.8);
      expect(payload['total'], 50.8);
      expect(payload['fiscal_model'], '65');
      final items = (payload['items']! as List).cast<Map<String, Object?>>();
      expect(items.map((i) => [i['line'], i['quantity'], i['unit_price'], i['total']]).toList(), [
        [1, 2.0, 12.9, 25.8],
        [2, 10.0, 2.5, 25.0],
      ]);
      expect(items[0]['barcode_id'], '019a0000-0000-7000-8000-000000000028');
      final payments = (payload['payments']! as List).cast<Map<String, Object?>>();
      expect(payments.map((p) => [p['method'], p['amount'], p['change']]).toList(), [
        ['debit_card', 30.0, 0.0],
        ['cash', 25.0, 4.2],
      ]);
      expect((payload['id']! as String)[14], '7');

      database.saveSale(payload, code: draft.code, itemRows: draft.itemRows, now: DateTime.utc(2026, 11, 23, 10));
      expect(database.nextSaleNumber, 9);
      final outbox = database.nextOutboxBatch();
      expect(outbox.map((item) => item.kind).toList(), ['cash_session_open', 'sale']);
      expect(outbox[0].payload, {'id': session.id, 'operator_id': operatorId, 'opened_at': '2026-11-23T09:00:00.000Z', 'opening_float': 150.0});
      expect(jsonEncode(outbox[1].payload), jsonEncode(payload));
      expect(database.debugSelect('SELECT count(*) AS n FROM sale_item').first['n'], 2);

      // Sem pagamento suficiente, não monta.
      final short = Cart()..add(database.saleProductByCode('7890000000017')!);
      expect(() => buildSale(cart: short, session: session, operator: operator, number: 9, terminalNumber: 1, now: DateTime.utc(2026)),
          throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA972')));
    });
  });

  group('comprovante', () {
    List<ReceiptLine> receipt(LocalDatabase database) {
      final cart = Cart()..add(database.saleProductByCode('7890000000017')!);
      cart.payments.add(Payment(method: PaymentMethod.cash, amountCents: 2000));
      return buildReceipt(fiscal: database.fiscal, saleCode: '1-000008', soldAt: DateTime(2026, 11, 23, 10, 5), operatorName: 'Operador Centro', cart: cart, terminalNumber: 1);
    }

    test('cabe na bobina e diz que não é fiscal', () {
      final database = seeded();
      addTearDown(database.close);
      final lines = receipt(database);
      final text = lines.map((line) => line.text).join('\n');
      expect(lines.every((line) => line.text.length <= receiptWidth), isTrue);
      expect(text, contains('Farmácia Demonstração'));
      expect(text, contains('CNPJ 11.222.333/0001-81'));
      expect(text, contains('NÃO É DOCUMENTO FISCAL'));
      expect(text, contains('Venda 1-000008'));
      expect(text, contains('23/11/2026 10:05'));
      expect(text, contains('Troco'));
      expect(text, contains('Nota fiscal pendente de emissão.'));
    });

    test('ESC/POS com acentos da página 860 e corte; PDF gravado', () async {
      final bytes = encodeEscPos(const [ReceiptLine('Ação é ÇÃO', bold: true, center: true)]);
      expect(bytes.sublist(0, 5), [0x1B, 0x40, 0x1B, 0x74, 0x03]);
      expect(bytes, containsAllInOrder([0x41, 0x87, 0x84, 0x6F, 0x20, 0x82, 0x20, 0x80, 0x8E, 0x4F]));
      expect(bytes.sublist(bytes.length - 4), [0x1D, 0x56, 0x42, 0x00]);
      // Caractere fora da página vira "?".
      expect(encodeEscPos(const [ReceiptLine('€')]), contains(0x3F));

      final directory = Directory.systemTemp.createTempSync('comprovante');
      addTearDown(() => directory.deleteSync(recursive: true));
      final database = seeded();
      addTearDown(database.close);
      final printer = PdfReceiptPrinter(directory);
      await printer.print('1-000008', receipt(database));
      final file = File('${directory.path}/venda-1-000008.pdf');
      expect(file.existsSync(), isTrue);
      expect(String.fromCharCodes(file.readAsBytesSync().take(5)), '%PDF-');
    });
  });

  group('tela do caixa', () {
    late LocalDatabase database;
    late FakePrinter printer;
    late PosController controller;
    var saved = 0;

    setUp(() {
      database = seeded();
      printer = FakePrinter();
      saved = 0;
      controller = PosController(
        database: database,
        auth: PosAuth(database: database),
        printer: () => printer,
        terminalNumber: () => 1,
        onSaleSaved: () => saved += 1,
        clock: () => DateTime.utc(2026, 11, 23, 13),
      );
    });
    tearDown(() => database.close());

    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    }

    testWidgets('entra, abre o caixa, vende com troco e imprime', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const Key('login-code')), '3');
      await tester.enterText(find.byKey(const Key('login-pin')), '2468');
      await tester.runAsync(() => controller.login('3', '2468'));
      await tester.pump();
      expect(find.text('Abrir o caixa'), findsWidgets);

      await tester.enterText(find.byKey(const Key('opening-float')), '150,00');
      await tester.tap(find.byKey(const Key('open-shift')));
      await tester.pump();
      expect(controller.session, isNotNull);

      await tester.enterText(find.byKey(const Key('scan-field')), '7890000000017');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.tap(find.byKey(const Key('more-0')));
      await tester.pump();
      expect(find.text('R\$ 25,80'), findsWidgets);

      // Busca por nome e escolha na lista.
      await tester.enterText(find.byKey(const Key('scan-field')), 'soro');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.tap(find.byKey(const Key('result-2')));
      await tester.pump();
      // Pela busca por nome entra uma unidade; só o código de barras da caixa traz a fração.
      expect(controller.cart.totalCents, 2580 + 250);

      await tester.tap(find.byKey(const Key('pay')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('payment-amount')), '60,00');
      await tester.tap(find.byKey(const Key('add-payment')));
      await tester.pump();
      expect(find.text('Troco: R\$ 31,70'), findsOneWidget);
      await tester.runAsync(() => controller.finish());
      await tester.pump();

      expect(find.byKey(const Key('pos-info')), findsOneWidget);
      expect(find.text('Venda 1-000008 concluída.'), findsOneWidget);
      expect(find.byKey(const Key('last-change')), findsOneWidget);
      expect(printer.printed.keys, ['1-000008']);
      expect(saved, 2);
      expect(database.outboxPending, 2);
      expect(controller.cart.isEmpty, isTrue);
    });

    testWidgets('produto desconhecido avisa com o código do catálogo; controlado pede a receita', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await pump(tester);
      controller.scan('123456789');
      await tester.pump();
      expect(find.text('Produto não encontrado.'), findsOneWidget);
      controller.scan('7890000000031');
      await tester.pump();
      expect(find.byKey(const Key('controlled-panel')), findsOneWidget);
      expect(find.textContaining('é controlado (lista B1)'), findsOneWidget);
      expect(controller.cart.isEmpty, isTrue);
    });

    testWidgets('impressora com problema: a venda fica salva e dá para reimprimir', (tester) async {
      await tester.runAsync(() => controller.login('3', '2468'));
      controller.openShift(0);
      await pump(tester);
      controller.scan('7890000000017');
      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: 1290));
      printer.failure = StateError('sem papel');
      await tester.runAsync(() => controller.finish());
      await tester.pump();
      expect(find.text('Não foi possível imprimir o comprovante.'), findsOneWidget);
      expect(database.debugSelect('SELECT count(*) AS n FROM sale').first['n'], 1);
      printer.failure = null;
      await tester.tap(find.byKey(const Key('reprint')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(printer.printed.keys, ['1-000008']);
    });

    testWidgets('PIN errado mostra a mensagem e não entra', (tester) async {
      await pump(tester);
      await tester.runAsync(() => controller.login('3', '1111'));
      await tester.pump();
      expect(find.text('Código ou PIN incorreto.'), findsOneWidget);
      expect(controller.operator, isNull);
    });
  });
}
