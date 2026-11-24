import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/core/local_logger.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/controlled.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const pharmacistId = '019a0000-0000-7000-8000-0000000000f1';
const clonazepam = '019a0000-0000-7000-8000-000000000033';
const amoxicilina = '019a0000-0000-7000-8000-000000000043';
const batchOld = '019a0000-0000-7000-8000-000000000036';
const batchNew = '019a0000-0000-7000-8000-000000000038';
const batchExpired = '019a0000-0000-7000-8000-000000000039';

final synced = DateTime(2026, 11, 23, 12);
late String pin;

PullItem user(String id, int code, String name, List<String> permissions) => PullItem(type: 'user', id: id, data: {
  'code': code, 'name': name, 'is_admin': false, 'roles': const [], 'permissions': permissions, 'limits': const {}, 'pin_hash': pin,
});

PullItem product(String id, int code, String name, String controlledClass, String barcode) => PullItem(
  type: 'product',
  id: id,
  data: {
    'code': code, 'name': name, 'status': 'active', 'price': 24.5, 'fraction_quantity': 1, 'batch_required': true,
    'controlled_class': controlledClass,
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
      }),
      user(operatorId, 3, 'Operador Centro', const ['sales.sell']),
      user(managerId, 5, 'Gerente Centro', const ['sales.sell', 'controlled.view']),
      user(pharmacistId, 7, 'Farmacêutica Ana', const ['sales.sell', 'controlled.dispense']),
      product(clonazepam, 4, 'Clonazepam 2 mg', 'B1', '7890000000055'),
      product(amoxicilina, 5, 'Amoxicilina 500 mg', 'antimicrobial', '7890000000048'),
      const PullItem(type: 'stock', id: clonazepam, data: {
        'quantity': 5,
        'batches': [
          {'id': batchNew, 'number': 'CLZ02', 'expires_on': '2031-01-31', 'quantity': 3},
          {'id': batchOld, 'number': 'CLZ01', 'expires_on': '2030-03-31', 'quantity': 2},
          {'id': batchExpired, 'number': 'CLZ00', 'expires_on': '2026-01-31', 'quantity': 4},
        ],
      }),
      const PullItem(type: 'stock', id: amoxicilina, data: {'quantity': -1, 'batches': []}),
    ]),
    now: synced,
  );
  return database;
}

PrescriptionForm filled({PrescriptionType type = PrescriptionType.notificationB, DateTime? date}) => PrescriptionForm(
  type: type,
  number: 'SP-123456',
  date: date ?? DateTime(2026, 11, 20),
  prescriberName: 'Dra. Fictícia',
  prescriberNumber: '123456',
  prescriberState: 'SP',
  buyerName: 'Comprador Fictício',
  buyerDocument: '123456789',
  buyerIssuer: 'SSP',
  buyerState: 'SP',
);

void main() {
  late LocalDatabase database;
  late FakePrinter printer;
  late DateTime now;
  late PosController controller;

  setUpAll(() async {
    pin = await hashFor('2468');
  });

  setUp(() {
    database = seeded();
    printer = FakePrinter();
    now = synced.add(const Duration(minutes: 5));
    controller = PosController(
      database: database,
      auth: PosAuth(database: database, clock: () => now),
      printer: () => printer,
      terminalNumber: () => 1,
      clock: () => now,
    );
  });
  tearDown(() => database.close());

  Future<void> ready() async {
    await controller.login('3', '2468');
    controller.openShift(0);
  }

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  group('regras da receita', () {
    test('tipo de receita e validade iguais aos da central', () {
      expect(
        ['A1', 'A3', 'B1', 'B2', 'C1', 'C2', 'C3', 'C5', 'antimicrobial'].map((c) => PrescriptionType.forClass(c).code),
        ['notification_a', 'notification_a', 'notification_b', 'notification_b2', 'special_control', 'notification_retinoid',
         'notification_thalidomide', 'special_control', 'antimicrobial'],
      );
      expect(PrescriptionType.antimicrobial.validDays, 10);
      expect(PrescriptionType.specialControl.validDays, 30);
      expect(PrescriptionType.notificationB.isNotification, isTrue);
      expect(PrescriptionType.specialControl.isNotification, isFalse);
    });

    test('campos obrigatórios, formatos e datas', () {
      final today = DateTime(2026, 11, 23, 18);
      expect(prescriptionErrors(filled(), today), isEmpty);
      expect(prescriptionErrors(PrescriptionForm(type: PrescriptionType.notificationB), today).keys.toSet(), {
        'number', 'date', 'prescriberName', 'prescriberNumber', 'prescriberState', 'buyerName', 'buyerDocument', 'buyerIssuer',
        'buyerState',
      });
      // Controle especial não exige número; se vier, precisa do formato.
      expect(prescriptionErrors(filled(type: PrescriptionType.specialControl)..number = '', today), isEmpty);
      expect(prescriptionErrors(filled(type: PrescriptionType.specialControl)..number = 'nº 12', today).keys, ['number']);
      // Validade: 30 dias conta o próprio dia 30; 31 já venceu. Antimicrobiano: 10.
      expect(prescriptionErrors(filled(date: DateTime(2026, 10, 24)), today), isEmpty);
      expect(prescriptionErrors(filled(date: DateTime(2026, 10, 23)), today).keys, ['date']);
      expect(prescriptionErrors(filled(date: DateTime(2026, 11, 24)), today)['date'], contains('futuro'));
      final antimicrobial = filled(type: PrescriptionType.antimicrobial, date: DateTime(2026, 11, 13));
      expect(prescriptionErrors(antimicrobial, today).keys.toSet(), {'patientAge', 'patientSex'});
      antimicrobial
        ..patientAge = 131
        ..patientSex = 'F';
      expect(prescriptionErrors(antimicrobial, today).keys, ['patientAge']);
      antimicrobial.patientAge = 40;
      expect(prescriptionErrors(antimicrobial, today), isEmpty);
      expect(prescriptionErrors(antimicrobial..date = DateTime(2026, 11, 12), today).keys, ['date']);
      expect(prescriptionErrors(filled()..prescriberState = 'XX', today).keys, ['prescriberState']);
      expect(prescriptionErrors(filled()..buyerDocument = '12', today).keys, ['buyerDocument']);
      expect(prescriptionErrors(filled()..buyerIssuer = 'S', today).keys, ['buyerIssuer']);
      expect(prescriptionErrors(filled()..prescriberName = 'Dr', today).keys, ['prescriberName']);
      expect(prescriptionErrors(filled()..patientName = 'Jo', today).keys, ['patientName']);
    });
  });

  group('venda de controlado', () {
    test('lido no caixa, espera a receita; lotes em FEFO, sem o vencido', () async {
      await ready();
      controller.scan('7890000000055');
      expect(controller.cart.isEmpty, isTrue);
      expect(controller.pendingControlled?.product.id, clonazepam);
      expect(controller.pendingControlled?.suggestedType, PrescriptionType.notificationB);
      expect(controller.controlledBatches(controller.pendingControlled!.product).map((b) => (b.number, b.availableMilli)), [
        ('CLZ01', 2000),
        ('CLZ02', 3000),
      ]);
      controller.cancelControlled();
      expect(controller.pendingControlled, isNull);
      // Sem a liberação, o carrinho recusa o controlado.
      expect(
        () => controller.cart.add(database.saleProductByCode('7890000000055')!),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA986')),
      );
    });

    test('farmacêutico libera com receita e lote; a venda sobe com os dados só pela outbox', () async {
      await ready();
      controller.scan('7890000000055');
      final form = filled();
      // Quem não tem a permissão não libera; PIN errado também não.
      expect(await controller.releaseControlled(form: form, batchId: batchOld, quantityMilli: 1000, code: '5', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA985');
      expect(await controller.releaseControlled(form: form, batchId: batchOld, quantityMilli: 1000, code: '7', pin: '1111'), isFalse);
      expect(noticeCode(), 'FA966');
      // Lote sem saldo para a quantidade, ou lote vencido.
      expect(await controller.releaseControlled(form: form, batchId: batchOld, quantityMilli: 3000, code: '7', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA988');
      expect(await controller.releaseControlled(form: form, batchId: batchExpired, quantityMilli: 1000, code: '7', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA988');
      // Receita vencida e dados faltando.
      expect(
        await controller.releaseControlled(form: filled(date: DateTime(2026, 9, 1)), batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'),
        isFalse,
      );
      expect(noticeCode(), 'FA987');
      expect(
        await controller.releaseControlled(form: filled()..buyerDocument = '', batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'),
        isFalse,
      );
      expect(noticeCode(), 'FA986');
      // Com tudo certo, há lote com saldo: a liberação pendente é recusada.
      expect(await controller.releaseControlledPending(reason: 'Sem nota', quantityMilli: 1000, code: '7', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA989');

      expect(await controller.releaseControlled(form: form, batchId: batchOld, quantityMilli: 2000, code: '7', pin: '2468'), isTrue);
      expect(controller.pendingControlled, isNull);
      final line = controller.cart.lines.single;
      expect([line.quantityMilli, line.controlled!.batch!.number, line.controlled!.pharmacistName], [2000, 'CLZ01', 'Farmacêutica Ana']);
      expect(line.warnings.last, contains('lote CLZ01'));
      // A quantidade não passa do saldo do lote.
      controller.setQuantity(line, 3000);
      expect([noticeCode(), line.quantityMilli], ['FA988', 2000]);
      controller.setQuantity(line, 1000);
      expect(line.quantityMilli, 1000);

      // Segundo item do mesmo produto fica separado, e o lote já usado mostra o saldo que sobra.
      controller.scan('7890000000055');
      expect(controller.controlledBatches(controller.pendingControlled!.product).map((b) => (b.number, b.availableMilli)), [
        ('CLZ01', 1000),
        ('CLZ02', 3000),
      ]);
      expect(await controller.releaseControlled(form: filled(), batchId: batchNew, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      expect(controller.cart.lines, hasLength(2));

      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 4900));
      await controller.finish();
      expect(controller.notice, isNull);
      final sale = database.nextOutboxBatch().last;
      final items = (sale.payload['items'] as List).cast<Map<String, dynamic>>();
      expect(items.map((item) => item['batch_id']), [batchOld, batchNew]);
      final data = items.first['controlled'] as Map<String, dynamic>;
      expect(data, containsPair('status', 'complete'));
      expect(data, containsPair('pharmacist_id', pharmacistId));
      expect(data, containsPair('prescription_type', 'notification_b'));
      expect(data, containsPair('prescription_date', '2026-11-20'));
      expect(data, containsPair('buyer_document', '123456789'));
      expect(data['patient_age'], isNull);
      expect(data['id'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7')));
      // Comprovante: lote e receita, nunca o documento do comprador.
      final receipt = controller.lastSale!.lines.map((line) => line.text).join('\n');
      expect(receipt, contains('  Lote CLZ01 · Notificação B (azul) nº SP-123456\n  Farmacêutico: Farmacêutica Ana'));
      expect(receipt, isNot(contains('123456789')));
    });

    test('sem saldo em lote: liberação pendente com motivo', () async {
      await ready();
      controller.scan('7890000000048');
      expect(controller.controlledBatches(controller.pendingControlled!.product), isEmpty);
      expect(await controller.releaseControlledPending(reason: '  ', quantityMilli: 1000, code: '7', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA986');
      expect(await controller.releaseControlled(form: filled(type: PrescriptionType.antimicrobial)..patientAge = 30..patientSex = 'M',
          batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA988');
      expect(await controller.releaseControlledPending(reason: 'Nota de entrada não lançada', quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      final line = controller.cart.lines.single;
      expect(line.controlled!.isPending, isTrue);
      expect(line.warnings.last, contains('dados do SNGPC pendentes'));
      // Quantidade do pendente pode mudar (não há lote para conferir).
      controller.setQuantity(line, 2000);
      expect(line.quantityMilli, 2000);
      controller.startPayment();
      controller.addPayment(Payment(method: PaymentMethod.pix, amountCents: 4900));
      await controller.finish();
      final item = (database.nextOutboxBatch().last.payload['items'] as List).single as Map<String, dynamic>;
      expect(item['batch_id'], isNull);
      expect(item['controlled'], {
        'id': (item['controlled'] as Map)['id'],
        'status': 'pending',
        'pharmacist_id': pharmacistId,
        'pending_reason': 'Nota de entrada não lançada',
      });
      expect(controller.lastSale!.lines.map((l) => l.text).join('\n'), contains('dados da receita pendentes'));
    });

    test('quantidade acima de todos os lotes permite a liberação pendente', () async {
      await ready();
      controller.scan('7890000000055');
      expect(await controller.releaseControlledPending(reason: 'Saldo físico maior que o do sistema', quantityMilli: 4000, code: '7', pin: '2468'), isTrue);
      expect(controller.cart.lines.single.controlled!.isPending, isTrue);
    });

    test('o log não recebe dados pessoais da receita, e o comprovante não leva o documento', () async {
      final directory = Directory.systemTemp.createTempSync('pdv-controlled-log');
      addTearDown(() => directory.deleteSync(recursive: true));
      final entries = <Map<String, Object?>>[];
      final logger = LocalLogger(directory: directory, clock: () => now)..onEntry = entries.add;
      final logging = PosController(
        database: database,
        auth: PosAuth(database: database, clock: () => now),
        printer: () => printer,
        terminalNumber: () => 1,
        clock: () => now,
        logger: logger,
      );
      await logging.login('3', '2468');
      logging.openShift(0);
      logging.scan('7890000000055');
      expect(await logging.releaseControlled(form: filled(), batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      logging.startPayment();
      logging.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2450));
      await logging.finish();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final logged = [
        jsonEncode(entries),
        for (final file in directory.listSync(recursive: true).whereType<File>()) file.readAsStringSync(),
      ].join();
      expect(logged, contains('Controlado liberado'));
      for (final personal in ['Comprador Fictício', '123456789', 'Dra. Fictícia', 'SP-123456']) {
        expect(logged, isNot(contains(personal)));
      }
      final receipt = logging.lastSale!.lines.map((line) => line.text).join();
      expect(receipt, isNot(contains('Comprador Fictício')));
      expect(receipt, isNot(contains('123456789')));
    });
  });

  group('tela', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    }

    testWidgets('janela da receita marca os campos e libera com o farmacêutico', (tester) async {
      await tester.runAsync(ready);
      controller.scan('7890000000055');
      await pump(tester);
      expect(find.byKey(const Key('controlled-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('controlled-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('controlled-dialog')), findsOneWidget);
      expect(find.textContaining('CLZ01 · vence 31/03/2030 · saldo 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('rx-release')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('Informe o número da notificação'), findsOneWidget);
      expect(find.text('Informe o nome do comprador'), findsOneWidget);
      expect(find.byKey(const Key('controlled-notice')), findsOneWidget);

      final fields = {
        'number': 'SP-123456', 'date': '20/11/2026', 'prescriberName': 'Dra. Fictícia', 'prescriberNumber': '123456',
        'prescriberState': 'sp', 'buyerName': 'Comprador Fictício', 'buyerDocument': '123456789', 'buyerIssuer': 'SSP',
        'buyerState': 'SP',
      };
      for (final entry in fields.entries) {
        await tester.enterText(find.byKey(Key('rx-${entry.key}')), entry.value);
      }
      await tester.enterText(find.byKey(const Key('rx-code')), '7');
      await tester.enterText(find.byKey(const Key('rx-pin')), '2468');
      await tester.pump();
      expect(find.text('Informe o número da notificação'), findsNothing);
      await tester.tap(find.byKey(const Key('rx-release')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('controlled-dialog')), findsNothing);
      expect(find.byKey(const Key('controlled-panel')), findsNothing);
      expect(controller.cart.lines.single.controlled!.form!.prescriberState, 'SP');
      expect(find.textContaining('lote CLZ01'), findsOneWidget);
    });

    testWidgets('sem saldo em lote, a janela pede só o motivo', (tester) async {
      await tester.runAsync(ready);
      controller.scan('7890000000048');
      await pump(tester);
      await tester.tap(find.byKey(const Key('controlled-open')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Não há saldo em lote'), findsOneWidget);
      expect(find.byKey(const Key('rx-number')), findsNothing);
      expect(find.text('Liberar pendente'), findsOneWidget);
      await tester.tap(find.byKey(const Key('controlled-cancel')).hitTestable().evaluate().isEmpty
          ? find.text('Voltar')
          : find.byKey(const Key('controlled-cancel')));
      await tester.pumpAndSettle();
    });
  });
}
