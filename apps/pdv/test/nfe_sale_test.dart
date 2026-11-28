import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farmaerp_pdv/core/secret_store.dart';
import 'package:farmaerp_pdv/customers/customer_service.dart';
import 'package:farmaerp_pdv/fiscal/nfce_credentials.dart';
import 'package:farmaerp_pdv/fiscal/nfce_emitter.dart';
import 'package:farmaerp_pdv/fiscal/nfce_retransmitter.dart';
import 'package:farmaerp_pdv/fiscal/sefaz.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/danfe_printer.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/pos/pos_screen.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nfce_emission_test.dart' show RoutingTransport, consultResponse;
import 'caps_finders.dart';
import 'pos_test.dart' show FakePrinter, hashFor;
import 'sefaz_test.dart' show FakeTransport, response;

// NF-e de venda (modelo 55) no caixa, com a Sefaz falsa: cliente PJ, emissão antes de gravar,
// venda bloqueada sem comunicação ou recusada, pendente quando a resposta se perde, DANFE A4 e a
// retransmissão nos endereços da NF-e. Certificado, chave, CNPJ e IE só de teste.
final _fixture = jsonDecode(File('test/fixtures/fiscal/entrega-certificado.json').readAsStringSync()) as Map<String, dynamic>;
final _terminalId = _fixture['terminalId'] as String;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const dipirona = '019a0000-0000-7000-8000-000000000017';
const company = '019a0000-0000-7000-8000-0000000000a1';
const person = '019a0000-0000-7000-8000-0000000000a2';
const incomplete = '019a0000-0000-7000-8000-0000000000a3';

class _Store implements SecretStore {
  final values = <String, String>{};
  @override
  String get kind => 'system';
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Cliente da venda como a central devolve (escolhido na busca).
final _customers = <String, Map<String, dynamic>>{
  company: {
    'code': 10, 'person_type': 'company', 'name': 'EMPRESA FICTICIA LTDA', 'trade_name': 'Fictícia', 'document': '11222333000262',
    'state_registration': '110042490114', 'ie_indicator': 1, 'email': 'compras@exemplo.test', 'phone': '1133334444',
    'postal_code': '01001000', 'street': 'Praça da Sé', 'street_number': '100', 'complement': null, 'district': 'Sé',
    'city': 'São Paulo', 'city_code': '3550308', 'state': 'SP', 'agreements': [],
  },
  person: {
    'code': 11, 'person_type': 'individual', 'name': 'Cliente Pessoa', 'document': '11144477735', 'ie_indicator': 9, 'agreements': [],
  },
  incomplete: {
    'code': 12, 'person_type': 'company', 'name': 'EMPRESA SEM ENDERECO LTDA', 'document': '11222333000343', 'ie_indicator': 9,
    'state_registration': null, 'city': 'São Paulo', 'state': 'SP', 'agreements': [],
  },
};

class _Api implements TerminalApi {
  @override
  Future<void> registerFiscalKey({required String accessToken, required String publicKey, required String signature}) async {}

  @override
  Future<Map<String, dynamic>> nfceCredentials({required String accessToken}) async =>
      {'credentialVersion': _fixture['credentialVersion'], 'validTo': '2030-01-01T00:00:00Z', 'envelope': _fixture['envelope']};

  @override
  Future<PullItem> customer({required String accessToken, required String id}) async =>
      PullItem(type: 'customer', id: id, data: _customers[id]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// DANFE "impresso": guarda o que recebeu.
class _Danfe implements DanfePrinter {
  final printed = <(String, Uint8List)>[];
  DanfeResult result = DanfeResult.printed;

  @override
  Future<({DanfeResult result, File file})> print(String accessKey, Uint8List pdf) async {
    printed.add((accessKey, pdf));
    return (result: result, file: File('DANFE-$accessKey.pdf'));
  }
}

Future<LocalDatabase> _seeded(String pin, {bool withNfeSeries = true}) async {
  final database = LocalDatabase.inMemory();
  database.applyPage(
    PullPage(format: 8, until: '10', items: [
      PullItem(type: 'fiscal', id: branchId, data: {
        'branch': {
          'id': branchId, 'name': 'Loja Centro', 'cnpj': '11222333000181', 'state_registration': '110042490114', 'state': 'SP',
          'street': 'Rua das Flores', 'street_number': '100', 'district': 'Centro', 'city': 'São Paulo', 'city_code': '3550308',
          'postal_code': '01001000',
        },
        'company': {'legal_name': 'FARMACIA DEMONSTRACAO LTDA', 'trade_name': 'Farmácia Demonstração', 'tax_regime': 1},
        'nfce': {'enabled': true, 'environment': 2, 'contingency_hours': 24, 'credential_version': _fixture['credentialVersion']},
        'series': [
          {'id': '019a0000-0000-7000-8000-0000000000e1', 'model': '65', 'series': 1, 'initial_number': 1, 'last_used_number': 41},
          if (withNfeSeries) {'id': '019a0000-0000-7000-8000-0000000000e2', 'model': '55', 'series': 1, 'initial_number': 1, 'last_used_number': null},
        ],
        'last_sale_number': null,
        'fixed_seller_id': operatorId,
      }),
      PullItem(type: 'user', id: operatorId, data: {
        'code': 3, 'name': 'Operador Centro', 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell'],
        'limits': const {}, 'pin_hash': pin,
      }),
      PullItem(type: 'product', id: dipirona, data: {
        'code': 1, 'name': 'Dipirona Sódica 500 mg', 'status': 'active', 'price': 12.9, 'fraction_quantity': 1, 'batch_required': false,
        'ncm': '30049099', 'cest': '1300100', 'unit': 'FR',
        'barcodes': [{'id': '019a0000-0000-7001-8000-000000000017', 'code': '7890000000017', 'is_primary': true, 'fraction_quantity': null}],
        'taxes': [
          {'id': '019a0000-0000-7000-8000-0000000000d1', 'valid_from': '2026-01-01', 'cfop': '5405', 'origin': 0, 'icms_csosn': '500',
           'pis_cst': '04', 'cofins_cst': '04'},
        ],
      }),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
    ]),
    now: DateTime(2026, 11, 27, 12),
  );
  return database;
}

void main() {
  late String pin;
  late LocalDatabase database;
  late NfceCredentialService credentials;
  late _Danfe danfe;

  setUpAll(() async => pin = await hashFor('2468'));

  Future<PosController> pos(
    SefazTransport transport, {
    bool withNfeSeries = true,
    DateTime Function()? clock,
    Future<Map<String, dynamic>> Function(String documentId, String reason, String supervisorId)? cancelNfce,
  }) async {
    database = await _seeded(pin, withNfeSeries: withNfeSeries);
    addTearDown(database.close);
    final store = _Store()..values['terminal_fiscal_seed'] = _fixture['seed'] as String;
    credentials = NfceCredentialService(api: _Api(), database: database, store: store);
    await credentials.refresh(accessToken: 't', terminalId: _terminalId, sign: (m) async => 'assinado');
    danfe = _Danfe();
    final controller = PosController(
      nfce: NfceEmitter(
        database: database,
        credentials: credentials,
        sefaz: SefazClient(transport: transport),
        terminalId: () => _terminalId,
        appVersion: '0.2.24',
      ),
      database: database,
      auth: PosAuth(database: database),
      printer: () => FakePrinter(),
      terminalNumber: () => 1,
      customers: CustomerService(api: _Api(), database: database, accessToken: () async => 't'),
      danfePrinter: danfe,
      clock: clock,
      cancelNfce: cancelNfce,
    );
    await controller.login('3', '2468');
    controller.openShift(0);
    return controller;
  }

  Future<void> ring(PosController controller, String customerId) async {
    controller.scan('7890000000017');
    await controller.selectCustomer(customerId);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2000));
  }

  String? noticeCode(PosController controller) => controller.notice?.reference.replaceFirst('Código ', '');
  List<OutboxItem> outbox(String kind) => database.nextOutboxBatch().where((item) => item.kind == kind).toList();

  group('destinatário da NF-e', () {
    test('só pessoa jurídica com CNPJ e endereço completo; o indicador vem do cadastro ou da inscrição', () {
      final recipient = nfeRecipientOf(_customers[company]!.cast<String, Object?>())!;
      expect([recipient.cnpj, recipient.ieIndicator, recipient.stateRegistration, recipient.cityCode, recipient.uf, recipient.email],
          ['11222333000262', 1, '110042490114', '3550308', 'SP', 'compras@exemplo.test']);
      expect(nfeRecipientOf(_customers[person]!.cast<String, Object?>()), isNull);
      expect(nfeRecipientOf(_customers[incomplete]!.cast<String, Object?>()), isNull);
      expect(nfeRecipientOf(null), isNull);
      // Sem o indicador guardado (cliente antigo): segue a inscrição; não contribuinte não leva a IE.
      final old = {..._customers[company]!, 'ie_indicator': null}.cast<String, Object?>();
      expect(nfeRecipientOf(old)!.ieIndicator, 1);
      expect(nfeRecipientOf({...old, 'state_registration': 'ISENTO'})!.ieIndicator, 2);
      final nonContributor = nfeRecipientOf({...old, 'state_registration': null})!;
      expect([nonContributor.ieIndicator, nonContributor.stateRegistration], [9, null]);
      expect(nfeRecipientOf({..._customers[company]!, 'ie_indicator': 9}.cast<String, Object?>())!.stateRegistration, isNull);
    });
  });

  group('escolha do documento', () {
    test('PJ contribuinte já vem com NF-e; PF e PJ incompleta ficam na NFC-e; tirar o cliente volta para NFC-e', () async {
      final controller = await pos(FakeTransport(() => response()));
      controller.scan('7890000000017');
      await controller.selectCustomer(company);
      expect([controller.nfeAvailable, controller.cart.fiscalModel], [true, '55']);
      controller.setFiscalModel('65');
      expect(controller.cart.fiscalModel, '65');
      controller.setFiscalModel('55');
      expect(controller.cart.fiscalModel, '55');
      controller.clearCustomer();
      expect([controller.nfeAvailable, controller.cart.fiscalModel], [false, '65']);
      await controller.selectCustomer(person);
      expect([controller.nfeAvailable, controller.cart.fiscalModel], [false, '65']);
      controller.setFiscalModel('55');
      expect([controller.cart.fiscalModel, noticeCode(controller)], ['65', 'FA784']);
      await controller.selectCustomer(incomplete);
      expect(controller.nfeAvailable, isFalse);
    });

    test('PJ não contribuinte: a NF-e aparece, mas a NFC-e vem marcada', () async {
      _customers[company]!['ie_indicator'] = 9;
      addTearDown(() => _customers[company]!['ie_indicator'] = 1);
      final controller = await pos(FakeTransport(() => response()));
      await controller.selectCustomer(company);
      expect([controller.nfeAvailable, controller.cart.fiscalModel], [true, '65']);
    });

    test('sem a série 55 no caixa, a NF-e não aparece', () async {
      final controller = await pos(FakeTransport(() => response()), withNfeSeries: false);
      await controller.selectCustomer(company);
      expect([controller.nfeAvailable, controller.cart.fiscalModel], [false, '65']);
    });
  });

  testWidgets('no pagamento, a escolha NFC-e ou NF-e (A4) aparece só para o cliente PJ e troca o botão de finalizar', (tester) async {
    final controller = (await tester.runAsync(() => pos(FakeTransport(() => response()))))!;
    controller.scan('7890000000017');
    await tester.runAsync(() => controller.selectCustomer(company));
    controller.startPayment();
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    await tester.pumpWidget(MaterialApp(home: PosScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fiscal-model')), findsOneWidget);
    expect(find.byKey(const Key('fiscal-model-hint')), findsOneWidget);
    expect(findText('Finalizar com NF-e'), findsOneWidget);
    await tester.tap(findText('NFC-e (cupom)'));
    await tester.pumpAndSettle();
    expect(controller.cart.fiscalModel, '65');
    expect(findText('Finalizar venda'), findsOneWidget);
    expect(find.byKey(const Key('fiscal-model-hint')), findsNothing);
    controller.clearCustomer();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fiscal-model')), findsNothing);
  });

  group('emissão', () {
    test('autorizada: envia na Sefaz da NF-e antes de gravar; venda e nota sobem com o modelo 55; DANFE A4 sai na impressora', () async {
      final transport = FakeTransport(() => response());
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), isNull);

      final sent = transport.calls.single;
      expect(sent.$1.host, 'homologacao.nfe.fazenda.sp.gov.br');
      expect(sent.$2, contains('<mod>55</mod>'));
      expect(sent.$2, contains('<dest><CNPJ>11222333000262</CNPJ>'));
      expect(sent.$2, contains('<indIEDest>1</indIEDest><IE>110042490114</IE>'));
      expect(sent.$2, contains('<indPres>1</indPres>'));

      final sale = outbox('sale').single.payload;
      expect([sale['fiscal_model'], sale['customer_id']], ['55', company]);
      final nfe = database.nfceOfSale(sale['id']! as String)!;
      expect([nfe.model, nfe.series, nfe.number, nfe.status, nfe.emissionType, nfe.qrCode], ['55', 1, 1, 'authorized', 1, '']);
      expect(nfe.accessKey, matches(RegExp(r'^35\d{4}11222333000181550010000000011\d{9}$')));
      final payload = outbox('nfce').single.payload;
      expect([payload['model'], payload['status'], payload['sale_id']], ['55', 'authorized', sale['id']]);

      // DANFE A4: o PDF da nota autorizada, pela impressora do Windows.
      expect(danfe.printed.single.$1, nfe.accessKey);
      expect(utf8.decode(danfe.printed.single.$2.sublist(0, 5)), '%PDF-');
      expect(controller.lastDanfePath, 'DANFE-${nfe.accessKey}.pdf');
      expect(controller.info, contains('NF-e 1 autorizada'));
      // O cupom diz qual é a nota; não é o DANFE da NFC-e.
      final receipt = controller.lastSale!.lines.map((line) => line.text);
      expect(receipt, containsAll(['NF-e nº 1 Série 1', 'Documento fiscal: DANFE em folha A4.']));
      expect(receipt, isNot(contains('DANFE NFC-e')));
      expect(controller.lastSale!.lines.where((line) => line.qr), isEmpty);
      // A série da NFC-e não andou; a da NF-e, sim.
      expect(database.nextFiscalNumber('55'), (series: 1, number: 2));
      expect(database.nextFiscalNumber('65'), (series: 1, number: 42));
      expect(controller.cart.fiscalModel, '65');
    });

    test('cancelar a última venda com NF-e: oferece por 24 horas (a NFC-e, só 30 minutos)', () async {
      DateTime? now;
      final controller = await pos(
        FakeTransport(() => response()),
        clock: () => now ?? DateTime.now(),
        cancelNfce: (documentId, reason, supervisorId) async => {'cash_refund': 'same_session'},
      );
      await ring(controller, company);
      await controller.finish();
      final nfe = database.nfceOfSale(controller.lastSale!.saleId!)!;
      expect(nfe.isNfe, isTrue);
      now = nfe.authorizedAt!.add(const Duration(hours: 23));
      expect(controller.cancelableNfce?.id, nfe.id);
      now = nfe.authorizedAt!.add(const Duration(hours: 24, minutes: 1));
      expect(controller.cancelableNfce, isNull);
    });

    test('sem comunicação com a Sefaz: a venda continua aberta, nada é gravado e o número não é gasto', () async {
      final transport = FakeTransport(() => throw const SefazNotReached('Sem conexão com a Sefaz: sem rede'));
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA781');
      expect(outbox('sale'), isEmpty);
      expect(outbox('nfce'), isEmpty);
      expect(controller.cart.lines, hasLength(1));
      expect(controller.cart.fiscalModel, '55');
      expect(danfe.printed, isEmpty);
      expect(database.nextFiscalNumber('55'), (series: 1, number: 1));
      // Troca para NFC-e e conclui.
      controller.setFiscalModel('65');
      await controller.finish();
      expect(outbox('sale').single.payload['fiscal_model'], '65');
    });

    test('recusada: a venda continua aberta e o motivo da Sefaz aparece para corrigir', () async {
      final controller = await pos(FakeTransport(() => response(status: '233', reason: 'Rejeicao: IE do destinatario nao cadastrada')));
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA782');
      expect(controller.notice!.message, contains('Sefaz: 233 Rejeicao: IE do destinatario nao cadastrada'));
      expect(outbox('sale'), isEmpty);
      expect(database.nextFiscalNumber('55'), (series: 1, number: 1));
    });

    test('enviada e sem resposta: a venda conclui com a NF-e pendente (FA785), sem DANFE ainda', () async {
      final controller = await pos(FakeTransport(() => throw TimeoutException('sem resposta')));
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA785');
      final sale = outbox('sale').single.payload;
      final nfe = database.nfceOfSale(sale['id']! as String)!;
      expect([nfe.model, nfe.status, nfe.number], ['55', 'pending', 1]);
      expect(danfe.printed, isEmpty);
      expect(controller.lastSale!.lines.map((line) => line.text), contains('NF-e enviada à Sefaz; aguardando a autorização.'));
    });

    test('cliente que deixou de servir para a NF-e: bloqueia antes de enviar', () async {
      final transport = FakeTransport(() => response());
      final controller = await pos(transport);
      await ring(controller, company);
      database.saveCustomer(PullItem(type: 'customer', id: company, data: {..._customers[company]!, 'city_code': null}));
      await controller.finish();
      expect(noticeCode(controller), 'FA784');
      expect(transport.calls, isEmpty);
      expect(outbox('sale'), isEmpty);
    });

    test('DANFE que não imprimiu: a venda fica concluída e o aviso FA783 diz que o PDF foi aberto', () async {
      final controller = await pos(FakeTransport(() => response()));
      danfe.result = DanfeResult.opened;
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA783');
      expect(outbox('sale'), hasLength(1));
    });
  });

  group('contingência SVC', () {
    const svcHost = 'hom.svc.fazenda.gov.br';
    const ufHost = 'homologacao.nfe.fazenda.sp.gov.br';

    test('Sefaz da UF sem comunicação: a mesma nota vai para a SVC-AN com tpEmis 6, hora e motivo; autorizada, a venda conclui com DANFE', () async {
      final transport = RoutingTransport((url, body) {
        if (url.host == ufHost) throw const SefazNotReached('Sem conexão com a Sefaz: SP fora');
        return response();
      });
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), isNull);
      expect(transport.calls.map((call) => call.$1.host), [ufHost, svcHost]);
      final svcBody = transport.calls.last.$2;
      expect(svcBody, contains('<tpEmis>6</tpEmis>'));
      expect(svcBody, contains('<xJust>Sefaz da UF sem comunicacao no momento da emissao</xJust>'));
      expect(svcBody, contains('<dhCont>'));
      final nfe = database.nfceOfSale(outbox('sale').single.payload['id']! as String)!;
      expect([nfe.status, nfe.emissionType, nfe.number], ['authorized', 6, 1]);
      // A chave leva o tpEmis 6 (posição 35).
      expect(nfe.accessKey.substring(34, 35), '6');
      expect(outbox('nfce').single.payload['emission_type'], 6);
      expect(danfe.printed, hasLength(1));
    });

    test('serviço parado na UF (108/109) também vai para a SVC', () async {
      final transport = RoutingTransport((url, body) => url.host == ufHost ? response(batch: '108', batchReason: 'Servico Paralisado Momentaneamente') : response());
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(transport.calls.map((call) => call.$1.host), [ufHost, svcHost]);
      expect(database.nfceOfSale(outbox('sale').single.payload['id']! as String)!.emissionType, 6);
    });

    test('UF e SVC sem comunicação (caixa sem internet): bloqueia, sem gastar o número', () async {
      final transport = RoutingTransport((url, body) => throw const SefazNotReached('Sem conexão com a Sefaz: sem rede'));
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA781');
      expect(transport.calls, hasLength(2));
      expect(outbox('sale'), isEmpty);
      expect(database.nextFiscalNumber('55'), (series: 1, number: 1));
    });

    test('enviada à SVC sem resposta: pendente em contingência; a retransmissão consulta e envia na SVC', () async {
      final transport = RoutingTransport((url, body) {
        if (url.host == ufHost) throw const SefazNotReached('SP fora');
        throw TimeoutException('SVC lenta');
      });
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA785');
      final pending = database.nfceToTransmit().single;
      expect([pending.status, pending.emissionType], ['pending', 6]);

      final online = RoutingTransport((url, body) => url.path.toLowerCase().contains('consulta') ? consultResponse('217') : response());
      final retransmitter = NfceRetransmitter(
        database: database,
        credentials: credentials,
        sefaz: SefazClient(transport: online),
        terminalId: () => _terminalId,
      );
      expect(await retransmitter.tick(), 1);
      expect(online.calls.map((call) => call.$1.host), [svcHost, svcHost]);
      expect(database.nfceOfSale(pending.saleId)!.status, 'authorized');
    });

    test('recusada na SVC: bloqueia com o motivo', () async {
      final transport = RoutingTransport((url, body) {
        if (url.host == ufHost) throw const SefazNotReached('SP fora');
        return response(status: '233', reason: 'Rejeicao: IE do destinatario nao cadastrada');
      });
      final controller = await pos(transport);
      await ring(controller, company);
      await controller.finish();
      expect(noticeCode(controller), 'FA782');
      expect(outbox('sale'), isEmpty);
    });
  });

  test('retransmissão da NF-e pendente: consulta e envia nos endereços da NF-e; autorizada, imprime o DANFE', () async {
    final controller = await pos(FakeTransport(() => throw TimeoutException('sem resposta')));
    await ring(controller, company);
    await controller.finish();
    final pending = database.nfceToTransmit().single;
    expect(pending.model, '55');

    final printed = <LocalNfce>[];
    final online = RoutingTransport((url, body) => url.path.toLowerCase().contains('consulta') ? consultResponse('217') : response());
    final retransmitter = NfceRetransmitter(
      database: database,
      credentials: credentials,
      sefaz: SefazClient(transport: online),
      terminalId: () => _terminalId,
      onNfeAuthorized: (nfe) async => printed.add(nfe),
    );
    expect(await retransmitter.tick(), 1);
    expect(online.calls.map((call) => call.$1.toString()), [
      'https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeconsultaprotocolo4.asmx',
      'https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx',
    ]);
    final authorized = database.nfceOfSale(pending.saleId)!;
    expect([authorized.status, authorized.model], ['authorized', '55']);
    expect(printed.single.accessKey, authorized.accessKey);
    expect(outbox('nfce').last.payload, containsPair('status', 'authorized'));
  });
}
