import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/sync/sync_service.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/terminal/terminal_controller.dart';
import 'package:farmaerp_pdv/terminal/terminal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'caps_finders.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_test.dart' show FakeApi, MemoryStore;

const branchId = '019a0000-0000-7000-8000-000000000005';
const seriesId = '019a0000-0000-7000-8000-0000000000a1';
const userId = '019a0000-0000-7000-8000-000000000008';
const dipirona = '019a0000-0000-7000-8000-000000000027';
const barcodeId = '019a0000-0000-7000-8000-000000000028';
const taxId = '019a0000-0000-7000-8000-0000000000c1';
const batchId = '019a0000-0000-7000-8000-0000000000b1';
const otherProduct = '019a0000-0000-7000-8000-000000000031';
const otherBarcodeId = '019a0000-0000-7000-8000-000000000032';

PullItem fiscal({int? lastUsed}) => PullItem(
  type: 'fiscal',
  id: branchId,
  data: {
    'branch': {'id': branchId, 'name': 'Loja Centro', 'state': 'SP'},
    'company': {'tax_regime': 1},
    'series': [
      {'id': seriesId, 'model': '65', 'series': 1, 'initial_number': 1, 'last_used_number': lastUsed},
    ],
  },
);

PullItem user({List<String> permissions = const ['stock.view']}) => PullItem(
  type: 'user',
  id: userId,
  data: {
    'code': 3,
    'name': 'Operador Centro',
    'is_admin': false,
    'roles': [
      {'id': '019a0000-0000-7000-8000-0000000000d1', 'name': 'Operador de caixa'},
    ],
    'permissions': permissions,
    'limits': {'sale_discount': 5, 'stock_loss': 0},
  },
);

PullItem product(String id, String barcodeIdValue, String code, {num price = 12.9, String status = 'active'}) =>
    PullItem(
      type: 'product',
      id: id,
      data: {
        'code': 1,
        'name': 'Dipirona Demonstração 500 mg',
        'manufacturer': 'Laboratório Demonstração',
        'status': status,
        'price': price,
        'fraction_quantity': 1.0,
        'batch_required': true,
        'barcodes': [
          {'id': barcodeIdValue, 'code': code, 'is_primary': true, 'fraction_quantity': null},
        ],
        'taxes': [
          {'id': taxId, 'valid_from': '2026-01-01', 'cfop': '5405', 'icms_csosn': '500'},
        ],
      },
    );

PullItem stock(String id, {num quantity = 7.5}) => PullItem(
  type: 'stock',
  id: id,
  data: {
    'quantity': quantity,
    'batches': [
      {'id': batchId, 'number': 'L1', 'expires_on': '2090-01-31', 'quantity': quantity},
    ],
  },
);

void main() {
  late FakeApi api;
  late LocalDatabase database;
  late SyncService sync;

  setUp(() {
    api = FakeApi();
    database = LocalDatabase.inMemory();
    sync = SyncService(api: api, database: database, clock: () => DateTime.utc(2026, 11, 23, 15, 30));
  });
  tearDown(() => database.close());

  group('banco local', () {
    test('cria o esquema uma vez e guarda UUID em 16 bytes', () {
      expect(database.schemaVersion, 14);
      expect(uuidBytes(dipirona), hasLength(16));
      expect(uuidText(uuidBytes(dipirona)), dipirona);
      expect(toCents(12.9), 1290);
      expect(toCents(0.1 + 0.2), 30);
      expect(toMilli(7.5), 7500);
    });

    test('arquivo criptografado: reabre com a chave do cofre e não deixa texto legível', () async {
      final directory = Directory.systemTemp.createTempSync('pdv-db');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/farmaerp.db');
      final store = MemoryStore();

      final first = await LocalDatabase.open(file: file, store: store);
      first.applyPage(PullPage(format: 1, until: '10', items: [product(dipirona, barcodeId, '7890000000017')]), now: DateTime(2026));
      first.close();
      expect(store.values['local_database_key'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(latin1.decode(file.readAsBytesSync()).contains('Dipirona'), isFalse);

      final again = await LocalDatabase.open(file: file, store: store);
      expect(again.productByBarcode('7890000000017')?.name, contains('Dipirona'));
      again.close();

      // Cofre apagado: o arquivo antigo fica guardado de lado e começa uma cópia nova.
      final reset = await LocalDatabase.open(file: file, store: MemoryStore());
      expect(reset.productByBarcode('7890000000017'), isNull);
      expect(reset.syncState.initialLoadDone, isFalse);
      reset.close();
      expect(directory.listSync().whereType<File>().any((f) => f.path.contains('.ilegivel-')), isTrue);
    });
  });

  group('descida', () {
    test('carga inicial em pacotes libera a loja e guarda o cursor', () async {
      api.pullResponses.addAll([
        PullPage(format: 1, until: '500', total: 4, next: '2:$userId', items: [fiscal(), user()]),
        PullPage(format: 1, until: '500', items: [product(dipirona, barcodeId, '7890000000017'), stock(dipirona)]),
      ]);
      expect(sync.initialLoadDone, isFalse);
      await sync.pull('token-1');

      expect(api.pullCalls.map((c) => [c.cursor, c.until, c.after, c.token]).toList(), [
        [null, null, null, 'token-1'],
        [null, '500', '2:$userId', 'token-1'],
      ]);
      final state = database.syncState;
      expect(state.cursor, '500');
      expect(state.initialLoadDone, isTrue);
      expect(state.windowUntil, isNull);
      expect(state.format, 1);
      expect(sync.lastPullAt, DateTime.utc(2026, 11, 23, 15, 30));

      final found = database.productByBarcode('7890000000017')!;
      expect(found.id, dipirona);
      expect(found.priceCents, 1290);
      expect(found.stockMilli, 7500);
      expect(found.status, 'active');
      expect(database.counts(), {
        'product': 1, 'product_barcode': 1, 'stock_batch': 1, 'app_user': 1, 'fiscal_series': 1,
      });
      final tax = database.debugSelect('SELECT valid_from, data FROM product_tax').single;
      expect(tax['valid_from'], '2026-01-01');
      expect(jsonDecode(tax['data'] as String)['cfop'], '5405');
      final operator = database.debugSelect('SELECT name, permissions, limits FROM app_user').single;
      expect(jsonDecode(operator['permissions'] as String), ['stock.view']);
      expect(jsonDecode(operator['limits'] as String), {'sale_discount': 5, 'stock_loss': 0});
    });

    test('carga interrompida recomeça do último pacote gravado', () async {
      api.pullResponses.addAll([
        PullPage(format: 1, until: '500', total: 3, next: '3:$dipirona', items: [fiscal(), product(dipirona, barcodeId, '7890000000017')]),
        const ApiException('FA001'),
      ]);
      await expectLater(sync.pull('token-1'), throwsA(isA<ApiException>()));
      expect(sync.running, isFalse);
      var state = database.syncState;
      expect(state.cursor, isNull);
      expect(state.initialLoadDone, isFalse);
      expect([state.windowUntil, state.windowAfter, state.windowTotal, state.windowReceived], ['500', '3:$dipirona', 3, 2]);
      expect([sync.received, sync.total], [2, 3]);

      api.pullResponses.add(PullPage(format: 1, until: '500', items: [stock(dipirona)]));
      await sync.pull('token-2');
      expect(api.pullCalls.last, (cursor: null, until: '500', after: '3:$dipirona', token: 'token-2'));
      state = database.syncState;
      expect(state.cursor, '500');
      expect(state.initialLoadDone, isTrue);
      expect(database.productByBarcode('7890000000017')?.stockMilli, 7500);
      // A geração não mudou ao retomar: nada da primeira parte foi apagado.
      expect(database.counts()['product'], 1);
    });

    test('incremental: atualiza, retira e mantém o resto', () async {
      api.pullResponses.add(PullPage(format: 1, until: '500', items: [
        fiscal(), user(), product(dipirona, barcodeId, '7890000000017'), product(otherProduct, otherBarcodeId, '7890000000024'),
        stock(dipirona),
      ]));
      await sync.pull('t');
      api.pullResponses.add(PullPage(format: 1, until: '510', items: [
        product(dipirona, barcodeId, '7890000000017', price: 9.99),
        const PullItem(type: 'product', id: otherProduct),
        const PullItem(type: 'user', id: userId),
        stock(dipirona, quantity: 2),
      ]));
      await sync.pull('t');
      expect(api.pullCalls.last.cursor, '500');
      expect(database.syncState.cursor, '510');
      expect(database.productByBarcode('7890000000017')?.priceCents, 999);
      expect(database.productByBarcode('7890000000017')?.stockMilli, 2000);
      // Retirado leva junto códigos, tributação e estoque.
      expect(database.productByBarcode('7890000000024'), isNull);
      expect(database.counts(), {
        'product': 1, 'product_barcode': 1, 'stock_batch': 1, 'app_user': 0, 'fiscal_series': 1,
      });
    });

    test('estoque de produto que não está na cópia local é ignorado', () async {
      api.pullResponses.add(PullPage(format: 1, until: '5', items: [stock(otherProduct)]));
      await sync.pull('t');
      expect(database.debugSelect('SELECT * FROM stock'), isEmpty);
      expect(database.syncState.cursor, '5');
    });

    test('numeração: a descida atualiza o número da central e não mexe no local', () async {
      api.pullResponses.add(PullPage(format: 1, until: '5', items: [fiscal()]));
      await sync.pull('t');
      database.debugSelect('UPDATE fiscal_series SET local_last_used_number = 42 RETURNING id');
      api.pullResponses.add(PullPage(format: 1, until: '6', items: [fiscal(lastUsed: 30)]));
      await sync.pull('t');
      final series = database.debugSelect('SELECT central_last_used_number, local_last_used_number, active FROM fiscal_series').single;
      expect([series['central_last_used_number'], series['local_last_used_number'], series['active']], [30, 42, 1]);
    });

    test('formato novo da central refaz a carga e limpa o que não veio', () async {
      api.pullResponses.add(PullPage(format: 1, until: '500', items: [
        fiscal(), user(), product(dipirona, barcodeId, '7890000000017'), product(otherProduct, otherBarcodeId, '7890000000024'),
      ]));
      await sync.pull('t');
      api.pullResponses.addAll([
        PullPage(format: 2, until: '600', items: const []),
        PullPage(format: 2, until: '600', items: [fiscal(), product(dipirona, barcodeId, '7890000000017')]),
      ]);
      await sync.pull('t');
      expect(api.pullCalls.map((c) => c.cursor).toList(), [null, '500', null]);
      final state = database.syncState;
      expect([state.cursor, state.format, state.generation, state.initialLoadDone], ['600', 2, 2, isTrue]);
      expect(database.productByBarcode('7890000000024'), isNull);
      expect(database.productByBarcode('7890000000017'), isNotNull);
      expect(database.counts()['app_user'], 0);
    });

    test('tipo desconhecido de uma central mais nova não trava a descida', () async {
      api.pullResponses.add(PullPage(format: 1, until: '5', items: const [PullItem(type: 'promotion', id: dipirona, data: {})]));
      await sync.pull('t');
      expect(database.syncState.cursor, '5');
    });
  });

  group('cliente HTTP', () {
    test('a descida usa o token, aceita gzip e lê o pacote', () async {
      late http.Request sent;
      final client = HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({'format': 1, 'until': '77', 'total': 1, 'next': null, 'items': [fiscal().toJson()]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final page = await client.pull(accessToken: 'abc', cursor: '70');
      expect(sent.url.path, '/terminals/sync/pull');
      expect(sent.headers['Authorization'], 'Bearer abc');
      expect(jsonDecode(sent.body), {'cursor': '70', 'until': null, 'after': null});
      expect([page.format, page.until, page.total, page.next, page.items.single.type], [1, '77', 1, null, 'fiscal']);
    });

    test('o sinal de vida informa a última descida', () async {
      late http.Request sent;
      await HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((request) async {
          sent = request;
          return http.Response('{"status":"active"}', 200);
        }),
      ).heartbeat(accessToken: 'abc', appVersion: '0.2.0', lastSyncAt: DateTime.utc(2026, 11, 23, 15, 30));
      expect(jsonDecode(sent.body), {'appVersion': '0.2.0', 'lastSyncAt': '2026-11-23T15:30:00.000Z'});
    });
  });

  group('terminal com a descida', () {
    TerminalController controller(MemoryStore store) => TerminalController(
      api: api,
      store: store,
      sync: sync,
      platform: 'windows',
      deviceName: 'CAIXA-01',
      appVersion: '0.1.0',
      pollInterval: const Duration(hours: 1),
      heartbeatInterval: const Duration(hours: 1),
      clock: () => DateTime(2026, 11, 4, 12),
    );

    Future<TerminalController> ready() async {
      final terminal = controller(MemoryStore());
      addTearDown(terminal.dispose);
      await terminal.start();
      api
        ..pairingState = 'claimed'
        ..terminalState = 'active';
      return terminal;
    }

    test('baixa depois do sinal de vida e informa a hora na próxima vez', () async {
      final terminal = await ready();
      api.pullResponses.add(PullPage(format: 1, until: '9', items: [fiscal()]));
      await terminal.tick();
      expect(terminal.phase, TerminalPhase.ready);
      expect(api.pullCalls, hasLength(1));
      expect(api.pullCalls.single.token, 'token-1');
      expect(sync.initialLoadDone, isTrue);
      expect(api.lastSyncAt, isNull);

      await terminal.tick();
      expect(api.lastSyncAt, DateTime.utc(2026, 11, 23, 15, 30));
      expect(api.pullCalls.last.cursor, '9');
    });

    test('terminal bloqueado não baixa nada', () async {
      final terminal = await ready();
      api.heartbeatFailure = const ApiException('FA304');
      await terminal.tick();
      expect(terminal.phase, TerminalPhase.blocked);
      expect(api.pullCalls, isEmpty);
    });

    test('falha de conexão na descida deixa o caixa offline, sem perder o que já veio', () async {
      final terminal = await ready();
      api.pullResponses.addAll([
        PullPage(format: 1, until: '9', total: 2, next: '1:$branchId', items: [fiscal()]),
        const ApiException('FA001'),
      ]);
      await terminal.tick();
      expect(terminal.phase, TerminalPhase.ready);
      expect(terminal.online, isFalse);
      expect(database.syncState.windowAfter, '1:$branchId');
    });

    testWidgets('mostra o progresso da carga e depois a loja pronta', (tester) async {
      late TerminalController terminal;
      await tester.runAsync(() async {
        terminal = await ready();
        api.pullResponses.addAll([
          PullPage(format: 1, until: '9', total: 4, next: '1:$branchId', items: [fiscal()]),
          const ApiException('FA001'),
        ]);
        await terminal.tick();
      });
      await tester.pumpWidget(MaterialApp(home: TerminalScreen(controller: terminal)));
      expect(find.byKey(const Key('preparing-store')), findsOneWidget);
      expect(findText('Recebendo os dados da filial: 1 de 4.'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(find.byKey(const Key('load-progress')));
      expect(bar.value, 0.25);

      await tester.runAsync(() async {
        api.pullResponses.add(PullPage(format: 1, until: '9', items: [user()]));
        await terminal.tick();
      });
      await tester.pump();
      expect(find.byKey(const Key('preparing-store')), findsNothing);
      expect(find.byKey(const Key('store-ready')), findsOneWidget);
      expect(find.byKey(const Key('last-sync')), findsOneWidget);
    });
  });
}

extension on PullItem {
  Map<String, Object?> toJson() => {'type': type, 'id': id, 'data': data};
}
