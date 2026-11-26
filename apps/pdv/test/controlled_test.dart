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

import 'caps_finders.dart';

import 'pos_test.dart' show FakePrinter, hashFor;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const managerId = '019a0000-0000-7000-8000-00000000000d';
const pharmacistId = '019a0000-0000-7000-8000-0000000000f1';
const clonazepam = '019a0000-0000-7000-8000-000000000033';
const amoxicilina = '019a0000-0000-7000-8000-000000000043';
const diazepam = '019a0000-0000-7000-8000-000000000053';
const azitromicina = '019a0000-0000-7000-8000-000000000063';
const batchDiazepam = '019a0000-0000-7000-8000-000000000056';
const batchAzitro = '019a0000-0000-7000-8000-000000000066';
const drAna = '019a0000-0000-7000-8000-0000000000a1';
const drBruno = '019a0000-0000-7000-8000-0000000000a2';
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
      user(operatorId, 3, 'Operador Centro', const ['sales.sell', 'pdv.prescriber_create']),
      user(managerId, 5, 'Gerente Centro', const ['sales.sell', 'controlled.view']),
      user(pharmacistId, 7, 'Farmacêutica Ana', const ['sales.sell', 'controlled.dispense']),
      product(clonazepam, 4, 'Clonazepam 2 mg', 'B1', '7890000000055'),
      product(amoxicilina, 5, 'Amoxicilina 500 mg', 'antimicrobial', '7890000000048'),
      product(diazepam, 6, 'Diazepam 10 mg', 'B1', '7890000000062'),
      product(azitromicina, 8, 'Azitromicina 500 mg', 'antimicrobial', '7890000000079'),
      const PullItem(type: 'stock', id: diazepam, data: {
        'quantity': 4,
        'batches': [
          {'id': batchDiazepam, 'number': 'DZP01', 'expires_on': '2030-06-30', 'quantity': 4},
        ],
      }),
      const PullItem(type: 'stock', id: azitromicina, data: {
        'quantity': 3,
        'batches': [
          {'id': batchAzitro, 'number': 'AZT01', 'expires_on': '2030-06-30', 'quantity': 3},
        ],
      }),
      const PullItem(type: 'stock', id: clonazepam, data: {
        'quantity': 5,
        'batches': [
          {'id': batchNew, 'number': 'CLZ02', 'expires_on': '2031-01-31', 'quantity': 3},
          {'id': batchOld, 'number': 'CLZ01', 'expires_on': '2030-03-31', 'quantity': 2},
          {'id': batchExpired, 'number': 'CLZ00', 'expires_on': '2026-01-31', 'quantity': 4},
        ],
      }),
      const PullItem(type: 'stock', id: amoxicilina, data: {'quantity': -1, 'batches': []}),
      const PullItem(type: 'health_professional', id: drAna, data: {
        'name': 'Dra. Fictícia Antônia', 'council': 'CRM', 'registration': '012345', 'state': 'SP', 'specialty': 'Psiquiatria',
      }),
      const PullItem(type: 'health_professional', id: drBruno, data: {
        'name': 'Dr. Bruno Fictício', 'council': 'CRO', 'registration': '777', 'state': 'PR', 'specialty': null,
      }),
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

    test('antimicrobiano (não psicotrópico): número, idade e sexo obrigatórios; comprador opcional, mas inteiro', () {
      final today = DateTime(2026, 11, 23, 18);
      PrescriptionForm antimicrobial() => filled(type: PrescriptionType.antimicrobial, date: DateTime(2026, 11, 20))
        ..patientAge = 40
        ..patientSex = 'M';
      expect(PrescriptionType.antimicrobial.requiresBuyer, isFalse);
      expect(PrescriptionType.specialControl.requiresBuyer, isTrue);
      expect(prescriptionErrors(antimicrobial(), today), isEmpty);
      expect(prescriptionErrors(antimicrobial()..number = '', today).keys, ['number']);
      expect(prescriptionErrors(antimicrobial()..number = '', today)['number'], 'Informe o número da receita');
      PrescriptionForm withoutBuyer() => antimicrobial()
        ..buyerName = ''
        ..buyerDocument = ''
        ..buyerIssuer = ''
        ..buyerState = '';
      expect(prescriptionErrors(withoutBuyer(), today), isEmpty);
      expect(prescriptionErrors(withoutBuyer()..buyerName = 'Comprador Fictício', today).keys.toSet(),
          {'buyerDocument', 'buyerIssuer', 'buyerState'});
      // Psicotrópico sem comprador continua barrado.
      expect(prescriptionErrors(filled()..buyerName = '', today).keys, ['buyerName']);
      // O que sobe: comprador vazio vai nulo (inclusive o tipo de documento).
      final release = ControlledRelease.complete(
        form: withoutBuyer(),
        batch: const ControlledBatch(id: batchAzitro, number: 'AZT01', expiresOn: '2030-06-30', availableMilli: 3000),
        pharmacist: (id: pharmacistId, name: 'Farmacêutica Ana'),
        today: today,
      );
      final json = release.toJson();
      expect([json['buyer_name'], json['buyer_document_type'], json['buyer_document'], json['buyer_issuer'], json['buyer_state']],
          [null, null, null, null, null]);
      expect([json['prescription_number'], json['patient_age'], json['patient_sex']], ['SP-123456', 40, 'M']);
    });

    test('receita de outro item: só do mesmo tipo; notificação traz tudo menos número e data', () {
      final special = filled(type: PrescriptionType.specialControl)..patientName = 'Paciente Fictício';
      final copy = reusePrescription(special, PrescriptionType.specialControl)!;
      expect([copy.number, copy.date, copy.prescriberName, copy.buyerDocument, copy.patientName],
          ['SP-123456', DateTime(2026, 11, 20), 'Dra. Fictícia', '123456789', 'Paciente Fictício']);
      expect(identical(copy, special), isFalse);
      expect(reusePrescription(special, PrescriptionType.antimicrobial), isNull);
      final notification = reusePrescription(filled(), PrescriptionType.notificationB)!;
      expect([notification.number, notification.date, notification.prescriberNumber, notification.buyerName],
          ['', null, '123456', 'Comprador Fictício']);
    });
  });

  group('venda de controlado', () {
    test('lido no caixa, entra na venda sem receita; ao finalizar, pede a receita; lotes em FEFO, sem o vencido', () async {
      await ready();
      controller.scan('7890000000055');
      controller.scan('7890000000055');
      final line = controller.cart.lines.single;
      expect([line.product.id, line.quantityMilli, line.controlled], [clonazepam, 2000, null]);
      expect(line.warnings.last, 'Controlado: falta a receita (pedida ao finalizar)');
      expect(controller.pendingControlled, isNull);
      // Desconto e quantidade mudam como em qualquer item.
      controller.setQuantity(line, 1000);
      expect(line.quantityMilli, 1000);

      controller.startPayment();
      expect(controller.paying, isFalse);
      expect(controller.pendingControlled?.line, line);
      expect(controller.pendingControlled?.suggestedType, PrescriptionType.notificationB);
      expect(controller.controlledBatches(controller.pendingControlled!.product).map((b) => (b.number, b.availableMilli)), [
        ('CLZ01', 2000),
        ('CLZ02', 3000),
      ]);
      // Voltar aos itens: o controlado fica na venda, ainda sem receita.
      controller.cancelControlled();
      expect([controller.pendingControlled, controller.paying, controller.cart.lines.length], [null, false, 1]);
      // Sem a receita, a venda não sai nem por fora do fluxo.
      expect(
        () => buildSale(cart: controller.cart, session: database.openCashSession!, operator: controller.operator!, number: 1,
            terminalNumber: 1, now: now),
        throwsA(isA<PosException>().having((e) => e.code, 'code', 'FA986')),
      );
      // Tirar o item que está esperando a receita fecha a janela.
      controller.startPayment();
      controller.remove(line);
      expect([controller.pendingControlled, controller.paying], [null, false]);
    });

    test('dois controlados: um por vez; a receita do primeiro serve para o segundo; depois vai para o pagamento', () async {
      await ready();
      controller.scan('7890000000055');
      controller.scan('7890000000062');
      controller.startPayment();
      expect(controller.pendingControlled?.product.id, clonazepam);
      expect(controller.prescriptionSources(controller.pendingControlled!), isEmpty);
      expect(await controller.releaseControlled(form: filled(), batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      expect([controller.pendingControlled?.product.id, controller.paying], [diazepam, false]);
      final sources = controller.prescriptionSources(controller.pendingControlled!);
      expect(sources.single.product.id, clonazepam);
      final copy = reusePrescription(sources.single.controlled!.form!, controller.pendingControlled!.suggestedType)!
        ..number = 'SP-654321'
        ..date = DateTime(2026, 11, 21);
      expect(await controller.releaseControlled(form: copy, batchId: batchDiazepam, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      expect([controller.pendingControlled, controller.paying], [null, true]);
      final forms = controller.cart.lines.map((line) => line.controlled!.form!).toList();
      expect(forms.map((form) => (form.number, form.prescriberNumber, form.buyerDocument)), [
        ('SP-123456', '123456', '123456789'),
        ('SP-654321', '123456', '123456789'),
      ]);
      // A cópia é independente: mudar a do segundo não mexe no primeiro.
      expect(identical(forms[0], forms[1]), isFalse);
    });

    test('não vender tira o controlado e segue; sem itens, não vai ao pagamento', () async {
      await ready();
      controller.scan('7890000000055');
      controller.startPayment();
      controller.dropControlled();
      expect([controller.cart.isEmpty, controller.pendingControlled, controller.paying], [true, null, false]);
    });

    test('antimicrobiano sem comprador: a venda sobe com o comprador vazio', () async {
      await ready();
      controller.scan('7890000000079');
      controller.startPayment();
      final form = filled(type: PrescriptionType.antimicrobial, date: DateTime(2026, 11, 20))
        ..buyerName = ''
        ..buyerDocument = ''
        ..buyerIssuer = ''
        ..buyerState = ''
        ..patientAge = 52
        ..patientSex = 'F';
      expect(await controller.releaseControlled(form: form..number = '', batchId: batchAzitro, quantityMilli: 1000, code: '7', pin: '2468'), isFalse);
      expect(noticeCode(), 'FA986');
      expect(await controller.releaseControlled(form: form..number = 'RX-9', batchId: batchAzitro, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2450));
      await controller.finish();
      expect(controller.notice, isNull);
      final item = (database.nextOutboxBatch().last.payload['items'] as List).single as Map<String, dynamic>;
      final data = item['controlled'] as Map<String, dynamic>;
      expect([data['prescription_type'], data['prescription_number'], data['buyer_name'], data['buyer_document_type'], data['patient_age']],
          ['antimicrobial', 'RX-9', null, null, 52]);
      expect(item['batch_id'], batchAzitro);
    });

    test('farmacêutico libera com receita e lote; a venda sobe com os dados só pela outbox', () async {
      await ready();
      controller.scan('7890000000055');
      controller.startPayment();
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
      expect([controller.pendingControlled, controller.paying], [null, true]);
      controller.backToItems();
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
      expect(controller.cart.lines, hasLength(2));
      controller.startPayment();
      expect(controller.controlledBatches(controller.pendingControlled!.product).map((b) => (b.number, b.availableMilli)), [
        ('CLZ01', 1000),
        ('CLZ02', 3000),
      ]);
      expect(await controller.releaseControlled(form: filled(), batchId: batchNew, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
      expect(controller.cart.lines, hasLength(2));
      expect(controller.paying, isTrue);
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
      controller.startPayment();
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
      controller.backToItems();
      controller.setQuantity(line, 2000);
      expect(line.quantityMilli, 2000);
      controller.startPayment();
      expect(controller.paying, isTrue);
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
      controller.startPayment();
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
      logging.startPayment();
      expect(await logging.releaseControlled(form: filled(), batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'), isTrue);
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

  group('profissionais da saúde', () {
    test('descem da central; busca por nome sem acento ou pelo número; inativo some', () {
      expect(database.searchProfessionals('antonia').map((p) => p.id), [drAna]);
      expect(database.searchProfessionals('12345').map((p) => p.label), ['Dra. Fictícia Antônia · CRM 012345/SP']);
      expect(database.searchProfessionals('Fictí').map((p) => p.id), [drBruno, drAna]);
      expect(database.searchProfessionals('a'), isEmpty);
      expect(database.professionalByRegistration('CRM', '12345', 'sp')?.id, drAna);
      expect(database.professionalByRegistration('CRO', '12345', 'SP'), isNull);
      // Inativo (ou apagado) desce vazio e sai da cópia local.
      database.applyPage(const PullPage(format: 8, until: '11', items: [PullItem(type: 'health_professional', id: drBruno, data: null)]),
          now: synced);
      expect(database.searchProfessionals('Bruno'), isEmpty);
    });

    test('cadastro rápido no caixa: entra na cópia local e sobe pela outbox; repetido devolve o que já existe', () async {
      await ready();
      controller.scan('7890000000055');
      controller.startPayment();
      final form = filled()
        ..prescriberName = '  Dr.  Novo   Prescritor '
        ..prescriberNumber = '998877'
        ..prescriberState = 'MG';
      expect(controller.prescriberRegistered(form), isFalse);
      // Prescritor com problema não cadastra.
      expect(controller.registerPrescriber(filled()..prescriberState = 'XX'), isNull);
      expect(noticeCode(), 'FA734');
      final saved = controller.registerPrescriber(form)!;
      expect([saved.name, saved.registration, saved.state], ['Dr. Novo Prescritor', '998877', 'MG']);
      expect(controller.prescriberRegistered(form), isTrue);
      expect(controller.searchPrescribers('novo prescritor').single.id, saved.id);
      // De novo, com zero à esquerda: o mesmo, sem outra subida.
      expect(controller.registerPrescriber(form..prescriberNumber = '0998877')!.id, saved.id);
      final outbox = database.nextOutboxBatch().where((item) => item.kind == 'health_professional').toList();
      expect(outbox, hasLength(1));
      expect(outbox.single.payload, {'id': saved.id, 'name': 'Dr. Novo Prescritor', 'council': 'CRM', 'registration': '998877', 'state': 'MG', 'created_by': operatorId});
    });

    test('sem "Cadastrar prescritor no PDV": só com a liberação, e quem liberou vai junto para a central', () async {
      await controller.login('5', '2468');
      controller.openShift(0);
      controller.scan('7890000000055');
      controller.startPayment();
      final form = filled()
        ..prescriberName = 'Dra. Liberada'
        ..prescriberNumber = '776655'
        ..prescriberState = 'SP';
      expect(controller.can('pdv.prescriber_create'), isFalse);
      expect(controller.registerPrescriber(form), isNull);
      expect(noticeCode(), 'FA002');
      expect(controller.prescriberRegistered(form), isFalse);
      final saved = controller.registerPrescriber(form, authorizedBy: pharmacistId)!;
      final outbox = database.nextOutboxBatch().where((item) => item.kind == 'health_professional').single;
      expect(outbox.payload, containsPair('created_by', pharmacistId));
      expect(outbox.payload['id'], saved.id);
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
      // Na leitura, só a marca no item; o painel aparece ao finalizar.
      expect(find.byKey(const Key('controlled-panel')), findsNothing);
      expect(findTextContaining('falta a receita'), findsOneWidget);
      controller.startPayment();
      await tester.pump();
      expect(find.byKey(const Key('controlled-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('controlled-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('controlled-dialog')), findsOneWidget);
      expect(findTextContaining('CLZ01 · vence 31/03/2030 · saldo 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('rx-release')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(findText('Informe o número da notificação'), findsOneWidget);
      expect(findText('Informe o nome do comprador'), findsOneWidget);
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
      expect(findText('Informe o número da notificação'), findsNothing);
      await tester.tap(find.byKey(const Key('rx-release')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('controlled-dialog')), findsNothing);
      expect(find.byKey(const Key('controlled-panel')), findsNothing);
      expect(controller.cart.lines.single.controlled!.form!.prescriberState, 'SP');
      expect(controller.paying, isTrue);
    });

    testWidgets('segundo controlado: o botão traz a receita do primeiro', (tester) async {
      await tester.runAsync(ready);
      controller.scan('7890000000055');
      controller.scan('7890000000062');
      controller.startPayment();
      await tester.runAsync(() => controller.releaseControlled(form: filled(), batchId: batchOld, quantityMilli: 1000, code: '7', pin: '2468'));
      await pump(tester);
      expect(findTextContaining('Diazepam 10 mg é controlado'), findsOneWidget);
      await tester.tap(find.byKey(const Key('controlled-open')));
      await tester.pumpAndSettle();
      expect(findText('Usar a receita de Clonazepam 2 mg'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rx-reuse-0')));
      await tester.pumpAndSettle();
      expect(findTextContaining('A notificação vale para um só medicamento'), findsOneWidget);
      String text(String name) => tester.widget<TextField>(find.byKey(Key('rx-$name'))).controller!.text;
      expect([text('prescriberName'), text('prescriberNumber'), text('buyerDocument'), text('number'), text('date')],
          ['Dra. Fictícia', '123456', '123456789', '', '']);
    });

    testWidgets('busca do prescritor preenche os campos; prescritor novo pode ser cadastrado', (tester) async {
      await tester.runAsync(ready);
      controller.scan('7890000000055');
      controller.startPayment();
      await pump(tester);
      await tester.tap(find.byKey(const Key('controlled-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rx-prescriber-search')), 'antonia');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rx-prescriber-0')));
      await tester.pumpAndSettle();
      String text(String name) => tester.widget<TextField>(find.byKey(Key('rx-$name'))).controller!.text;
      expect([text('prescriberName'), text('prescriberNumber'), text('prescriberState')], ['Dra. Fictícia Antônia', '012345', 'SP']);
      // Já cadastrado: sem o botão de cadastrar.
      expect(find.byKey(const Key('rx-prescriber-save')), findsNothing);

      await tester.enterText(find.byKey(const Key('rx-prescriber-search')), 'ninguém');
      await tester.pumpAndSettle();
      expect(findText('Nenhum prescritor encontrado. Preencha abaixo e cadastre.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('rx-prescriberName')), 'Dra. Nova Fictícia');
      await tester.enterText(find.byKey(const Key('rx-prescriberNumber')), '4321');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rx-prescriber-save')));
      await tester.pumpAndSettle();
      expect(findTextContaining('Prescritor cadastrado: Dra. Nova Fictícia · CRM 4321/SP'), findsOneWidget);
      expect(find.byKey(const Key('rx-prescriber-save')), findsNothing);
    });

    testWidgets('sem saldo em lote, a janela pede só o motivo', (tester) async {
      await tester.runAsync(ready);
      controller.scan('7890000000048');
      controller.startPayment();
      await pump(tester);
      await tester.tap(find.byKey(const Key('controlled-open')));
      await tester.pumpAndSettle();
      expect(findTextContaining('Não há saldo em lote'), findsOneWidget);
      expect(find.byKey(const Key('rx-number')), findsNothing);
      expect(findText('Liberar pendente'), findsOneWidget);
      await tester.tap(find.byKey(const Key('controlled-cancel')).hitTestable().evaluate().isEmpty
          ? findText('Voltar')
          : find.byKey(const Key('controlled-cancel')));
      await tester.pumpAndSettle();
    });
  });
}
