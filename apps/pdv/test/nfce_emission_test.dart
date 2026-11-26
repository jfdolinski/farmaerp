import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/core/secret_store.dart';
import 'package:farmaerp_pdv/fiscal/nfce_credentials.dart';
import 'package:farmaerp_pdv/fiscal/nfce_emitter.dart';
import 'package:farmaerp_pdv/fiscal/nfce_retransmitter.dart';
import 'package:farmaerp_pdv/fiscal/sefaz.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/cart.dart';
import 'package:farmaerp_pdv/pos/pos_auth.dart';
import 'package:farmaerp_pdv/pos/pos_controller.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pos_test.dart' show FakePrinter, hashFor;
import 'sefaz_test.dart' show FakeTransport, response;

// Emissão da NFC-e na venda do caixa, com a Sefaz falsa: autorizada, recusada, sem resposta,
// sem certificado e produto sem tributação. Certificado, chave e CSC só de teste.
final _fixture = jsonDecode(File('test/fixtures/fiscal/entrega-certificado.json').readAsStringSync()) as Map<String, dynamic>;
final _terminalId = _fixture['terminalId'] as String;

const branchId = '019a0000-0000-7000-8000-000000000005';
const operatorId = '019a0000-0000-7000-8000-000000000009';
const dipirona = '019a0000-0000-7000-8000-000000000017';
const semTributacao = '019a0000-0000-7000-8000-000000000027';
const seriesId = '019a0000-0000-7000-8000-0000000000e1';

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

class _Api implements TerminalApi {
  @override
  Future<void> registerFiscalKey({required String accessToken, required String publicKey, required String signature}) async {}

  @override
  Future<Map<String, dynamic>> nfceCredentials({required String accessToken}) async =>
      {'credentialVersion': _fixture['credentialVersion'], 'validTo': '2030-01-01T00:00:00Z', 'envelope': _fixture['envelope']};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PullItem product(String id, int code, String name, String barcode, {List<Map<String, dynamic>> taxes = const []}) => PullItem(
  type: 'product',
  id: id,
  data: {
    'code': code, 'name': name, 'status': 'active', 'price': 12.9, 'fraction_quantity': 1, 'batch_required': false,
    'ncm': '30049099', 'cest': '1300100',
    'barcodes': [{'id': id.replaceFirst('7000', '7001'), 'code': barcode, 'is_primary': true, 'fraction_quantity': null}],
    'taxes': taxes,
  },
);

Future<LocalDatabase> seeded(String pin, {String? credentialVersion}) async {
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
        'nfce': {'enabled': true, 'environment': 2, 'contingency_hours': 24, 'credential_version': credentialVersion ?? _fixture['credentialVersion']},
        'series': [{'id': seriesId, 'model': '65', 'series': 1, 'initial_number': 1, 'last_used_number': 41}],
        'last_sale_number': null,
        'fixed_seller_id': operatorId,
      }),
      PullItem(type: 'user', id: operatorId, data: {
        'code': 3, 'name': 'Operador Centro', 'is_admin': false, 'roles': const [], 'permissions': const ['sales.sell'],
        'limits': const {}, 'pin_hash': pin,
      }),
      product(dipirona, 1, 'Dipirona Sódica 500 mg', '7890000000017', taxes: [
        {'id': '019a0000-0000-7000-8000-0000000000d1', 'valid_from': '2026-01-01', 'cfop': '5405', 'origin': 0, 'icms_csosn': '500',
         'pis_cst': '04', 'cofins_cst': '04'},
      ]),
      product(semTributacao, 2, 'Produto sem tributação', '7890000000024'),
      const PullItem(type: 'stock', id: dipirona, data: {'quantity': 50, 'batches': []}),
      const PullItem(type: 'stock', id: semTributacao, data: {'quantity': 50, 'batches': []}),
    ]),
    now: DateTime(2026, 11, 26, 12),
  );
  return database;
}

void main() {
  late String pin;
  late LocalDatabase database;
  late FakeTransport transport;
  late PosController controller;

  setUpAll(() async => pin = await hashFor('2468'));

  Future<void> setUpPos({String? credentialVersion, bool withCredentials = true}) async {
    database = await seeded(pin, credentialVersion: credentialVersion);
    addTearDown(database.close);
    final store = _Store()..values['terminal_fiscal_seed'] = _fixture['seed'] as String;
    final credentials = NfceCredentialService(api: _Api(), database: database, store: store);
    if (withCredentials) {
      await credentials.refresh(accessToken: 't', terminalId: _terminalId, sign: (m) async => 'assinado');
    }
    transport = FakeTransport(() => response());
    controller = PosController(
      nfce: NfceEmitter(
        database: database,
        credentials: credentials,
        sefaz: SefazClient(transport: transport),
        terminalId: () => _terminalId,
        appVersion: '0.2.4',
      ),
      database: database,
      auth: PosAuth(database: database),
      printer: () => FakePrinter(),
      terminalNumber: () => 1,
    );
    await controller.login('3', '2468');
    controller.openShift(0);
  }

  Future<String> sell(String barcode) async {
    controller.scan(barcode);
    controller.startPayment();
    controller.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2000));
    await controller.finish();
    final sale = database.nextOutboxBatch().where((item) => item.kind == 'sale').last;
    return sale.payload['id']! as String;
  }

  String? noticeCode() => controller.notice?.reference.replaceFirst('Código ', '');

  test('autorizada: guarda o nfeProc, sobe depois da venda, imprime o DANFE com o QR Code e a série anda', () async {
    await setUpPos();
    final saleId = await sell('7890000000017');
    expect(noticeCode(), isNull);
    final nfce = database.nfceOfSale(saleId)!;
    expect([nfce.status, nfce.series, nfce.number, nfce.protocol], ['authorized', 1, 42, '135260000000123']);
    expect(nfce.accessKey, matches(RegExp(r'^35\d{4}11222333000181650010000000421\d{9}$')));
    expect(nfce.xml, startsWith('<?xml version="1.0" encoding="UTF-8"?><nfeProc'));
    expect(nfce.xml, contains('<protNFe versao="4.00">'));
    expect(controller.info, contains('NFC-e 42 autorizada'));

    // A Sefaz recebeu a nota da venda: SP homologação, com o valor e o CPF ausente.
    final sent = transport.calls.single;
    expect(sent.$1.host, 'homologacao.nfce.fazenda.sp.gov.br');
    expect(sent.$2, contains('<vNF>12.90</vNF>'));
    expect(sent.$2, contains('<tPag>01</tPag><vPag>20.00</vPag>'));
    expect(sent.$2, contains('<vTroco>7.10</vTroco>'));

    // Na outbox: a venda, depois a nota.
    final kinds = database.nextOutboxBatch().map((item) => item.kind).where((kind) => kind == 'sale' || kind == 'nfce').toList();
    expect(kinds, ['sale', 'nfce']);
    final payload = database.nextOutboxBatch().firstWhere((item) => item.kind == 'nfce').payload;
    expect(payload, containsPair('sale_id', saleId));
    expect(payload, containsPair('status', 'authorized'));
    expect(payload, containsPair('series', 1));

    final receipt = controller.lastSale!.lines;
    expect(receipt.map((line) => line.text), containsAll(['DANFE NFC-e', 'EMITIDA EM AMBIENTE DE HOMOLOGAÇÃO', 'CONSUMIDOR NÃO IDENTIFICADO']));
    expect(receipt.map((line) => line.text), isNot(contains('NÃO É DOCUMENTO FISCAL')));
    expect(receipt.singleWhere((line) => line.qr).text, nfce.qrCode);
    expect(receipt.map((line) => line.text), contains('NFC-e nº 42 Série 1 ${_moment(nfce.emittedAt)}'));

    // Próxima venda: número seguinte.
    final next = await sell('7890000000017');
    expect(database.nfceOfSale(next)!.number, 43);
  });

  test('recusada: a venda conclui com a nota pendente e o aviso FA736; o comprovante não é fiscal', () async {
    await setUpPos();
    transport = FakeTransport(() => response(status: '539', reason: 'Duplicidade de NF-e'));
    final saleId = await sellWith(controller, database, transport, '7890000000017');
    expect(noticeCode(), 'FA736');
    final nfce = database.nfceOfSale(saleId)!;
    expect([nfce.status, nfce.statusCode, nfce.reason, nfce.protocol], ['rejected', '539', 'Duplicidade de NF-e', null]);
    expect(nfce.xml, startsWith('<NFe xmlns="http://www.portalfiscal.inf.br/nfe">'));
    expect(controller.lastSale!.lines.map((line) => line.text), containsAll(['NÃO É DOCUMENTO FISCAL', 'Nota fiscal pendente de emissão.']));
    expect(controller.lastSale!.lines.where((line) => line.qr), isEmpty);
    expect(controller.info, 'Venda ${controller.lastSale!.code} concluída.');
  });

  test('sem resposta da Sefaz: contingência offline com o mesmo número, DANFE de contingência e aviso FA739', () async {
    await setUpPos();
    final saleId = await sellWith(controller, database, FakeTransport(() => throw const SocketException('sem rede')), '7890000000017');
    expect(noticeCode(), 'FA739');
    final nfce = database.nfceOfSale(saleId)!;
    expect([nfce.status, nfce.emissionType, nfce.number], ['contingency', 9, 42]);
    // Chave com tpEmis 9; a nota traz a hora e o motivo da contingência.
    expect(nfce.accessKey.substring(34, 35), '9');
    expect(nfce.xml, contains('<tpEmis>9</tpEmis>'));
    expect(nfce.xml, contains('<xJust>Sem comunicacao com a Sefaz no momento da venda</xJust>'));
    expect(nfce.xml, contains('<dhCont>'));
    final receipt = controller.lastSale!.lines;
    expect(receipt.map((line) => line.text), containsAll(['DANFE NFC-e', 'EMITIDA EM CONTINGÊNCIA', 'Pendente de autorização']));
    expect(receipt.singleWhere((line) => line.qr).text, nfce.qrCode);
    final payload = database.nextOutboxBatch().lastWhere((item) => item.kind == 'nfce').payload;
    expect([payload['status'], payload['emission_type']], ['contingency', 9]);
  });

  test('retransmissão: autorizada atualiza a nota e sobe de novo; recusada fica com o motivo; sem resposta espera', () async {
    await setUpPos();
    final first = await sellWith(controller, database, FakeTransport(() => throw const SocketException('sem rede')), '7890000000017');
    final second = await sellWith(controller, database, FakeTransport(() => throw const SocketException('sem rede')), '7890000000017');
    final emitter = controller.nfce!;
    NfceRetransmitter retransmitter(FakeTransport transport) => NfceRetransmitter(
      database: database,
      credentials: emitter.credentials,
      sefaz: SefazClient(transport: transport),
      terminalId: emitter.terminalId,
    );

    // Ainda sem resposta: nada muda, para na primeira.
    final offline = FakeTransport(() => throw const SocketException('sem rede'));
    expect(await retransmitter(offline).tick(), 0);
    expect(offline.calls, hasLength(1));
    expect(database.nfceOfSale(first)!.status, 'contingency');

    // Volta a internet: a primeira é autorizada, a segunda recusada.
    var call = 0;
    final online = FakeTransport(() => ++call == 1 ? response() : response(status: '204', reason: 'Duplicidade de NF-e'));
    expect(await retransmitter(online).tick(), 2);
    final authorized = database.nfceOfSale(first)!;
    expect([authorized.status, authorized.protocol, authorized.emissionType], ['authorized', '135260000000123', 9]);
    expect(authorized.xml, startsWith('<?xml version="1.0" encoding="UTF-8"?><nfeProc'));
    final rejected = database.nfceOfSale(second)!;
    expect([rejected.status, rejected.statusCode], ['rejected', '204']);
    // A nota sobe de novo com o mesmo id e a situação nova.
    final updates = database.nextOutboxBatch().where((item) => item.kind == 'nfce' && item.payload['id'] == authorized.id).toList();
    expect(updates.map((item) => item.payload['status']), ['contingency', 'authorized']);
    // Nada mais a transmitir.
    expect(database.nfceToTransmit(), isEmpty);
    expect(await retransmitter(online).tick(), 0);
  });

  test('alerta da contingência: aviso na metade do prazo da filial, vencido no prazo', () async {
    await setUpPos();
    expect(nfceContingencyAlert(database, DateTime.now(), limit: contingencyLimitOf(database)), isNull);
    await sellWith(controller, database, FakeTransport(() => throw const SocketException('sem rede')), '7890000000017');
    final emitted = database.nfceContingency().oldest!;
    final limit = contingencyLimitOf(database);
    expect(limit, const Duration(hours: 24));
    final fresh = nfceContingencyAlert(database, emitted.add(const Duration(hours: 1)), limit: limit)!;
    expect([fresh.count, fresh.warning, fresh.overdue], [1, false, false]);
    expect(fresh.text, 'NFC-e em contingência: 1 (a mais antiga há 1 h)');
    final half = nfceContingencyAlert(database, emitted.add(const Duration(hours: 12)), limit: limit)!;
    expect([half.warning, half.overdue], [true, false]);
    final late = nfceContingencyAlert(database, emitted.add(const Duration(hours: 25)), limit: limit)!;
    expect([late.warning, late.overdue], [true, true]);
    expect(late.text, contains('prazo vencido'));
  });

  test('sem certificado no caixa ou produto sem tributação: venda concluída sem nota (FA738, FA723)', () async {
    await setUpPos(withCredentials: false);
    final saleId = await sell('7890000000017');
    expect(noticeCode(), 'FA738');
    expect(database.nfceOfSale(saleId), isNull);
    expect(transport.calls, isEmpty);

    await setUpPos();
    final other = await sell('7890000000024');
    expect(noticeCode(), 'FA723');
    expect(database.nfceOfSale(other), isNull);
    expect(transport.calls, isEmpty);
    // O número não foi gasto.
    expect(database.nextNfceNumber(), (series: 1, number: 42));
  });

  test('a nota da venda em contingência passa no schema oficial da NF-e', () async {
    await setUpPos();
    final saleId = await sellWith(controller, database, FakeTransport(() => throw const SocketException('sem rede')), '7890000000017');
    final file = File('${Directory.systemTemp.createTempSync('nfce-venda').path}/nota.xml')
      ..writeAsStringSync(database.nfceOfSale(saleId)!.xml);
    try {
      final result = await Process.run(Platform.isWindows ? 'powershell' : 'pwsh', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tool/validate-xsd.ps1',
        '-Schema', 'test/fixtures/schemas/PL_010h_v1.03/nfe_v4.00.xsd', '-Xml', file.path,
      ]);
      expect('${result.stdout}${result.stderr}'.trim(), 'valido');
    } on ProcessException {
      markTestSkipped('PowerShell indisponível: validação de schema não rodou.');
    }
  });
}

String _moment(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  final local = value.toLocal();
  return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

/// Venda com outra resposta da Sefaz (troca o emissor do caixa pelo mesmo, com o transporte dado).
Future<String> sellWith(PosController controller, LocalDatabase database, FakeTransport transport, String barcode) async {
  final emitter = controller.nfce!;
  final replaced = PosController(
    nfce: NfceEmitter(
      database: database,
      credentials: emitter.credentials,
      sefaz: SefazClient(transport: transport),
      terminalId: emitter.terminalId,
      appVersion: emitter.appVersion,
    ),
    database: database,
    auth: PosAuth(database: database),
    printer: () => FakePrinter(),
    terminalNumber: () => 1,
  );
  await replaced.login('3', '2468');
  replaced.scan(barcode);
  replaced.startPayment();
  replaced.addPayment(Payment(method: PaymentMethod.cash, amountCents: 2000));
  await replaced.finish();
  controller.notice = replaced.notice;
  controller.info = replaced.info;
  controller.lastSale = replaced.lastSale;
  return database.nextOutboxBatch().where((item) => item.kind == 'sale').last.payload['id']! as String;
}
