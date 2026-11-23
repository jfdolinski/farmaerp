import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/core/local_logger.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/sync/sync_service.dart';
import 'package:farmaerp_pdv/terminal/terminal_api.dart';
import 'package:farmaerp_pdv/terminal/terminal_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_test.dart' show FakeApi, MemoryStore;

final now = DateTime.utc(2026, 11, 23, 15, 30);

void main() {
  late FakeApi api;
  late LocalDatabase database;
  late SyncService sync;

  setUp(() {
    api = FakeApi();
    database = LocalDatabase.inMemory();
    sync = SyncService(api: api, database: database, clock: () => now);
  });
  tearDown(() => database.close());

  Map<String, Object?> warn(String message, [Map<String, Object?> extra = const {}]) => {
    'level': 'warn',
    'time': now.toIso8601String(),
    'msg': message,
    'version': '0.2.0',
    ...extra,
  };

  List<Map<String, Object?>> rows() => database
      .debugSelect('SELECT sequence, kind, payload, sent_at, result, result_code, attempts FROM outbox ORDER BY sequence')
      .map((row) => {...row, 'payload': jsonDecode(row['payload'] as String)})
      .toList();

  group('outbox', () {
    test('grava em ordem, com UUID v7, e desfaz junto com a operação', () {
      final first = database.enqueue('log', {'a': 1}, now: now);
      final second = database.enqueue('log', {'a': 2}, now: now);
      expect(first[14], '7');
      expect(second.compareTo(first), greaterThan(0));
      expect(rows().map((row) => row['sequence']), [1, 2]);

      // A operação que falha leva junto o item da outbox.
      expect(
        () => database.transaction(() {
          database.enqueue('log', {'a': 3}, now: now);
          throw StateError('venda recusada');
        }),
        throwsStateError,
      );
      expect(database.outboxPending, 2);
      database.transaction(() => database.enqueue('log', {'a': 4}, now: now));
      expect(rows().map((row) => row['sequence']), [1, 2, 3]);
    });

    test('só aviso e erro sobem, já limitados ao que a central aceita', () {
      database.enqueueLog({'level': 'info', 'msg': 'iniciado'}, now: now);
      database.enqueueLog({'level': 'debug', 'msg': 'x'}, now: now);
      database.enqueueLog(
        warn('m' * 600, {
          'error_code': 'FA001',
          'trace_id': '019a0000-0000-7000-8000-0000000000aa',
          'service': 'pdv',
          'route': '/terminals/heartbeat',
          'err': 'e' * 3000,
        }),
        now: now,
      );
      database.enqueueLog(warn('código estranho', {'error_code': 'X1', 'trace_id': 'nada'}), now: now);
      database.enqueueLog(warn('campos enormes', {for (var i = 0; i < 20; i += 1) 'k$i': 'v' * 1000}), now: now);
      final logs = rows();
      expect(logs, hasLength(3));
      final first = logs[0]['payload'] as Map;
      expect((first['msg'] as String).length, 500);
      expect(first['error_code'], 'FA001');
      expect(first['trace_id'], '019a0000-0000-7000-8000-0000000000aa');
      expect((first['fields'] as Map).keys, ['route', 'err']);
      expect(((first['fields'] as Map)['err'] as String).length, 2000);
      expect((logs[1]['payload'] as Map).containsKey('error_code'), isFalse);
      expect((logs[1]['payload'] as Map).containsKey('trace_id'), isFalse);
      expect((logs[2]['payload'] as Map)['fields'], containsPair('truncated', true));
    });

    test('fila de logs cheia: o resto fica só no arquivo', () {
      database.transaction(() {
        for (var i = 0; i < maxPendingLogs; i += 1) {
          database.enqueue('log', {'i': i}, now: now);
        }
      });
      database.enqueueLog(warn('mais um'), now: now);
      expect(database.outboxPending, maxPendingLogs);
      // Outro tipo de item nunca é descartado.
      database.enqueue('sale', {'x': 1}, now: now);
      expect(database.outboxPending, maxPendingLogs + 1);
    });

    test('o log do PDV entra na outbox sem dados pessoais', () {
      final directory = Directory.systemTemp.createTempSync('pdv-log');
      addTearDown(() => directory.deleteSync(recursive: true));
      final logger = LocalLogger(directory: directory, version: '0.2.0', clock: () => now)
        ..onEntry = (entry) => database.enqueueLog(entry, now: now);
      logger.info('Terminal liberado');
      logger.warn('Cliente sem cadastro', fields: {'cpf': '123.456.789-09', 'nota': 'CPF 123.456.789-09'});
      logger.error('Falhou', errorCode: 'FA000', error: StateError('x'));
      final logs = rows();
      expect(logs, hasLength(2));
      final payload = logs[0]['payload'] as Map;
      expect(payload['fields'], {'cpf': '[protegido]', 'nota': 'CPF [protegido]'});
      expect(jsonEncode(logs), isNot(contains('123.456.789-09')));
      expect((logs[1]['payload'] as Map)['error_code'], 'FA000');
      expect(((logs[1]['payload'] as Map)['fields'] as Map)['err'], contains('Bad state: x'));
      // O arquivo local continua recebendo tudo.
      final lines = directory.listSync().whereType<File>().single.readAsLinesSync();
      expect(lines, hasLength(3));
    });

    test('falha na fila não derruba o log', () {
      final directory = Directory.systemTemp.createTempSync('pdv-log');
      addTearDown(() => directory.deleteSync(recursive: true));
      final logger = LocalLogger(directory: directory, clock: () => now)
        ..onEntry = (_) => throw StateError('disco cheio');
      logger.warn('ainda grava');
      expect(directory.listSync().whereType<File>().single.readAsLinesSync(), hasLength(1));
    });
  });

  group('subida', () {
    test('em pacotes, na ordem, até esvaziar; conflito e duplicado ficam registrados', () async {
      for (var i = 0; i < 5; i += 1) {
        database.enqueue('log', {'msg': 'x' * 30000, 'i': i}, now: now);
      }
      api.pushResponses.add(<PushResult>[]);
      await sync.push('t');
      // O pacote respeita o tamanho: dois itens de 30 KB por vez.
      expect(api.pushCalls.first.map((item) => item.sequence), [1, 2]);
      // Sem resposta para os itens, eles ficam na fila, com a tentativa contada.
      expect(database.outboxPending, 5);
      expect(rows().first['attempts'], 1);

      api.pushCalls.clear();
      final batch = database.nextOutboxBatch();
      api.pushResponses.add([
          PushResult(id: batch[0].id, status: 'conflict', code: 'FA958'),
          PushResult(id: batch[1].id, status: 'duplicate', result: 'applied'),
        ]);
      await sync.push('t');
      expect(api.pushCalls.expand((call) => call.map((item) => item.sequence)).toList(), [1, 2, 3, 4, 5]);
      expect(database.outboxPending, 0);
      expect(rows().map((row) => [row['result'], row['result_code']]).toList(), [
        ['conflict', 'FA958'], ['applied', null], ['applied', null], ['applied', null], ['applied', null],
      ]);
    });

    test('sem conexão, nada sai da fila', () async {
      database.enqueue('log', {'a': 1}, now: now);
      api.pushResponses.add(const ApiException('FA001'));
      await expectLater(sync.push('t'), throwsA(isA<ApiException>()));
      expect(database.outboxPending, 1);
      await sync.push('t');
      expect(database.outboxPending, 0);
    });

    test('logs entregues saem da fila local depois de 7 dias', () async {
      final old = SyncService(api: api, database: database, clock: () => now.subtract(const Duration(days: 8)));
      database.enqueue('log', {'a': 1}, now: now);
      database.enqueue('sale', {'a': 2}, now: now);
      await old.push('t');
      expect(rows(), hasLength(2));
      database.enqueue('log', {'a': 3}, now: now);
      await sync.push('t');
      expect(rows().map((row) => row['sequence']), [2, 3]);
    });
  });

  group('terminal', () {
    test('o sinal de vida informa as pendências, e a subida vem antes da descida', () async {
      final terminal = TerminalController(
        api: api,
        store: MemoryStore(),
        sync: sync,
        platform: 'windows',
        deviceName: 'CAIXA-01',
        appVersion: '0.1.0',
        pollInterval: const Duration(hours: 1),
        heartbeatInterval: const Duration(hours: 1),
      );
      addTearDown(terminal.dispose);
      await terminal.start();
      api
        ..pairingState = 'claimed'
        ..terminalState = 'active';
      database.enqueue('log', {'a': 1}, now: now);
      database.enqueue('log', {'a': 2}, now: now);
      // A descida falha: a subida já tinha terminado.
      api.pullResponses.add(const ApiException('FA001'));
      await terminal.tick();
      expect(api.outboxPending, 2);
      expect(api.pushCalls, hasLength(1));
      expect(database.outboxPending, 0);
      await terminal.tick();
      expect(api.outboxPending, 0);
    });

    test('cliente HTTP envia os itens e lê os resultados', () async {
      late http.Request sent;
      final client = HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'results': [
                {'id': 'a', 'status': 'duplicate', 'result': 'conflict', 'code': 'FA958'},
              ],
            }),
            200,
          );
        }),
      );
      final results = await client.push(
        accessToken: 'abc',
        items: const [OutboxItem(id: 'a', sequence: 7, kind: 'log', payload: {'level': 'warn'})],
      );
      expect(sent.url.path, '/terminals/sync/push');
      expect(sent.headers['Authorization'], 'Bearer abc');
      expect(jsonDecode(sent.body), {
        'items': [
          {'id': 'a', 'sequence': 7, 'kind': 'log', 'payload': {'level': 'warn'}},
        ],
      });
      expect([results.single.status, results.single.outcome, results.single.code], ['duplicate', 'conflict', 'FA958']);

      await HttpTerminalApi(
        baseUrl: 'https://central.test',
        client: MockClient((request) async {
          sent = request;
          return http.Response('{"status":"active"}', 200);
        }),
      ).heartbeat(accessToken: 'abc', appVersion: '0.2.0', outboxPending: 3);
      expect(jsonDecode(sent.body), {'appVersion': '0.2.0', 'outboxPending': 3});
    });
  });
}
