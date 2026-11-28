import 'dart:convert';

import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show FakeApi;
import 'sync_test.dart' show barcodeId, dipirona, fiscal, product, user;

// Cópia local ligada ao terminal: o caixa pareado de novo (por exemplo numa central nova) não usa
// nem envia nada do pareamento anterior.

const terminalA = '019a0000-0000-7000-8000-0000000000f1';
const terminalB = '019a0000-0000-7000-8000-0000000000f2';
final now = DateTime.utc(2026, 11, 28, 12);

/// Cópia com a carga inteira feita: o operador (código 3), um produto e a filial.
void loaded(LocalDatabase database) {
  database.startFullLoad();
  database.applyPage(
    PullPage(format: 1, until: '10', items: [fiscal(), user(), product(dipirona, barcodeId, '7890000000017')]),
    now: now,
  );
}

void main() {
  test('cópia vazia é adotada; o mesmo terminal não mexe em nada', () {
    final database = LocalDatabase.inMemory();
    expect(database.bindTerminal(terminalA, now: now), (binding: TerminalBinding.adopted, archived: 0));
    expect(database.dataTerminalId, terminalA);
    loaded(database);
    database.enqueue('sale', {'id': 'x'}, now: now);
    expect(database.bindTerminal(terminalA, now: now), (binding: TerminalBinding.same, archived: 0));
    expect(database.userByCode(3), isNotNull);
    expect(database.outboxPending, 1);
  });

  test('cópia de outro terminal: arquiva o que não subiu, limpa o resto e recomeça a carga; ficam os ajustes do aparelho', () {
    final database = LocalDatabase.inMemory();
    database.bindTerminal(terminalA, now: now);
    loaded(database);
    database.enqueue('sale', {'id': 'venda-antiga'}, now: now);
    database.enqueueLog({'level': 'warn', 'message': 'aviso'}, now: now);
    database.setSetting('printer', 'Impressora do balcão');
    expect(database.syncState.initialLoadDone, isTrue);

    final result = database.bindTerminal(terminalB, now: now);

    expect(result, (binding: TerminalBinding.reset, archived: 1));
    expect(database.dataTerminalId, terminalB);
    // Nada do pareamento anterior: nem operador, nem produto, nem item para subir.
    expect(database.userByCode(3), isNull);
    expect(database.productByBarcode('7890000000017'), isNull);
    expect(database.outboxPending, 0);
    // A carga inteira recomeça (a venda fica bloqueada até ela terminar).
    expect(database.syncState.cursor, isNull);
    expect(database.syncState.initialLoadDone, isFalse);
    expect(database.setting('printer'), 'Impressora do balcão');
    // O item não enviado ficou no arquivo, com o terminal de origem (o log não).
    expect(database.archivedCount, 1);

    // A cópia refeita volta a funcionar.
    loaded(database);
    expect(database.userByCode(3), isNotNull);
    expect(database.bindTerminal(terminalB, now: now).binding, TerminalBinding.same);
    expect(database.archivedCount, 1);
  });

  test('o arquivo guarda o item como estava, com o terminal de origem', () {
    final database = LocalDatabase.inMemory();
    database.bindTerminal(terminalA, now: now);
    loaded(database);
    database.enqueue('cash_session_open', {'id': 'turno-antigo', 'opening_float': 50}, now: now);
    database.bindTerminal(terminalB, now: now);
    final row = database.archivedRows().single;
    expect(row.terminalId, terminalA);
    expect(row.source, 'outbox');
    final data = jsonDecode(row.data) as Map<String, dynamic>;
    expect(data['kind'], 'cash_session_open');
    expect(jsonDecode(data['payload'] as String), {'id': 'turno-antigo', 'opening_float': 50});
  });

  test('cópia de antes da marca: com itens por enviar é adotada (nada se perde); sem eles, é refeita', () {
    final pending = LocalDatabase.inMemory();
    loaded(pending);
    pending.enqueue('sale', {'id': 'por-enviar'}, now: now);
    expect(pending.bindTerminal(terminalA, now: now).binding, TerminalBinding.adopted);
    expect(pending.outboxPending, 1);
    expect(pending.userByCode(3), isNotNull);

    final stale = LocalDatabase.inMemory();
    loaded(stale);
    stale.enqueueLog({'level': 'warn', 'message': 'só log'}, now: now);
    expect(stale.bindTerminal(terminalA, now: now), (binding: TerminalBinding.reset, archived: 0));
    expect(stale.userByCode(3), isNull);
  });

  test('login pelo código: com dois cadastros no mesmo código, vale o que chegou por último', () {
    final database = LocalDatabase.inMemory();
    loaded(database);
    // Mesmo código, outra pessoa (outra central), chegando depois na descida.
    database.applyPage(
      PullPage(format: 1, until: '20', items: [
        PullItem(type: 'user', id: '019a0000-0000-7000-8000-0000000000e9', data: {
          ...user().data!,
          'name': 'Operador Novo',
        }),
      ]),
      now: now,
    );
    expect(database.userByCode(3)!.name, 'Operador Novo');
  });

  test('a sincronização liga a cópia ao terminal antes de subir: refeita, avisa a tela e tira o operador', () async {
    final database = LocalDatabase.inMemory();
    database.bindTerminal(terminalA, now: now);
    loaded(database);
    database.enqueue('sale', {'id': 'venda-antiga'}, now: now);
    final api = FakeApi();
    final sync = SyncService(api: api, database: database, clock: () => now);
    var loggedOut = 0;
    sync.onLocalReset = () => loggedOut += 1;

    await sync.run('token', terminalId: terminalB);

    expect(loggedOut, 1);
    expect(sync.resetNotice, contains('1 itens não enviados ou notas fiscais'));
    // A venda antiga não subiu para a central nova.
    expect(api.pushCalls, isEmpty);
    // E a carga inteira começou do zero (sem cursor).
    expect(api.pullCalls.first.cursor, isNull);

    // Mesmo terminal na rodada seguinte: nada muda, nada é avisado de novo.
    sync.resetNotice = null;
    await sync.run('token', terminalId: terminalB);
    expect(loggedOut, 1);
    expect(sync.resetNotice, isNull);
  });
}
