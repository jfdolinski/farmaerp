import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('banco da versão 12 com devolução e item atualiza até a última sem perder nada', () {
    // A versão 13 refaz a tabela sale_return: com as chaves estrangeiras ligadas, o item da
    // devolução fazia a atualização falhar (FOREIGN KEY constraint failed no COMMIT).
    final raw = LocalDatabase.migratedInMemory(12);
    const now = '2026-11-20T10:00:00Z';
    raw.execute(
      "INSERT INTO sale_return (id, number, code, sale_id, sale_code, destination, total_cents, returned_at, created_at, updated_at) "
      "VALUES (zeroblob(16), 1, '1-000001', randomblob(16), '1-000009', 'credit', 500, ?, ?, ?)",
      [now, now, now],
    );
    raw.execute(
      'INSERT INTO sale_return_item (id, sale_return_id, sale_item_id, quantity_milli, amount_cents, created_at, updated_at) '
      'VALUES (randomblob(16), zeroblob(16), randomblob(16), 1000, 500, ?, ?)',
      [now, now],
    );
    final database = LocalDatabase.fromDatabase(raw);
    addTearDown(database.close);
    expect(database.schemaVersion, greaterThanOrEqualTo(14));
    expect(raw.select('SELECT count(*) AS n FROM sale_return_item').first['n'], 1);
    expect(raw.select('SELECT destination, total_cents, cashback_refund_cents FROM sale_return').first,
        {'destination': 'credit', 'total_cents': 500, 'cashback_refund_cents': 0});
    expect(raw.select('PRAGMA foreign_key_check'), isEmpty);
    expect(raw.select('PRAGMA foreign_keys').first.columnAt(0), 1);
  });

  test('referência quebrada depois da migração desfaz a migração inteira', () {
    final raw = LocalDatabase.migratedInMemory(12);
    const now = '2026-11-20T10:00:00Z';
    // Item de devolução apontando para devolução que não existe (só entra com as chaves desligadas).
    raw.execute('PRAGMA foreign_keys = OFF');
    raw.execute(
      'INSERT INTO sale_return_item (id, sale_return_id, sale_item_id, quantity_milli, amount_cents, created_at, updated_at) '
      'VALUES (randomblob(16), randomblob(16), randomblob(16), 1000, 500, ?, ?)',
      [now, now],
    );
    expect(() => LocalDatabase.fromDatabase(raw), throwsStateError);
    expect(raw.select('PRAGMA user_version').first.columnAt(0), 12);
    expect(raw.select('PRAGMA foreign_keys').first.columnAt(0), 1);
  });

  test('versão 20 com cliente atualiza para a 21: o cliente continua e ganha a inscrição e o indicador de IE', () {
    final raw = LocalDatabase.migratedInMemory(20);
    raw.execute("INSERT INTO customer (id, code, person_type, name, document, agreements, search_text, saved_at) VALUES (randomblob(16), 7, 'company', 'Empresa', '11222333000181', '[]', 'empresa', '2026-11-27T10:00:00Z')");
    final database = LocalDatabase.fromDatabase(raw);
    addTearDown(database.close);
    expect(database.schemaVersion, 22);
    expect(raw.select('SELECT name, state_registration, ie_indicator FROM customer').first, {'name': 'Empresa', 'state_registration': null, 'ie_indicator': null});
    raw.execute("UPDATE customer SET state_registration = '110042490114', ie_indicator = 1");
    expect(() => raw.execute('UPDATE customer SET ie_indicator = 3'), throwsA(anything));
  });

  test('versão 21 com NFC-e atualiza para a 22: as notas ficam como modelo 65, e a numeração é por modelo', () {
    final raw = LocalDatabase.migratedInMemory(21);
    const now = '2026-11-27T10:00:00Z';
    raw.execute(
      'INSERT INTO nfce_document (id, sale_id, series, number, access_key, environment, emission_type, status, xml, qr_code, '
      'consult_url, emitted_at, updated_at) '
      "VALUES (randomblob(16), randomblob(16), 1, 42, '35261111222333000181650010000000421000000019', 2, 1, 'authorized', "
      "'<nfeProc/>', 'qr', 'url', ?, ?)",
      [now, now],
    );
    final database = LocalDatabase.fromDatabase(raw);
    addTearDown(database.close);
    expect(database.schemaVersion, 22);
    expect(raw.select('SELECT model, number FROM nfce_document').first, {'model': '65', 'number': 42});
    // A NF-e com a mesma série e número entra; outra NFC-e com o mesmo número, não.
    raw.execute(
      'INSERT INTO nfce_document (id, sale_id, model, series, number, access_key, environment, emission_type, status, xml, qr_code, '
      'consult_url, emitted_at, updated_at) '
      "VALUES (randomblob(16), randomblob(16), '55', 1, 42, '35261111222333000181550010000000421000000019', 2, 1, 'pending', "
      "'<NFe/>', '', '', ?, ?)",
      [now, now],
    );
    expect(() => raw.execute(
      'INSERT INTO nfce_document (id, sale_id, model, series, number, access_key, environment, emission_type, status, xml, qr_code, '
      'consult_url, emitted_at, updated_at) '
      "VALUES (randomblob(16), randomblob(16), '65', 1, 42, 'outra', 2, 1, 'pending', '<NFe/>', '', '', ?, ?)",
      [now, now],
    ), throwsA(anything));
    // NF-e não entra em contingência offline (tpEmis 9).
    expect(() => raw.execute(
      'INSERT INTO nfce_document (id, sale_id, model, series, number, access_key, environment, emission_type, status, xml, qr_code, '
      'consult_url, emitted_at, updated_at) '
      "VALUES (randomblob(16), randomblob(16), '55', 1, 43, 'mais-outra', 2, 9, 'contingency', '<NFe/>', '', '', ?, ?)",
      [now, now],
    ), throwsA(anything));
  });

  test('versão 18 com cliente atualiza para a 19: o cliente continua e ganha a curva ABC', () {
    final raw = LocalDatabase.migratedInMemory(18);
    raw.execute("INSERT INTO customer (id, code, person_type, name, document, agreements, search_text, saved_at) VALUES (randomblob(16), 7, 'individual', 'Cliente', '11144477735', '[]', 'cliente', '2026-11-27T10:00:00Z')");
    final database = LocalDatabase.fromDatabase(raw);
    addTearDown(database.close);
    expect(database.schemaVersion, 22);
    expect(raw.select('SELECT name, abc_curve FROM customer').first, {'name': 'Cliente', 'abc_curve': null});
    raw.execute("UPDATE customer SET abc_curve = 'A'");
    expect(() => raw.execute("UPDATE customer SET abc_curve = 'D'"), throwsA(anything));
  });

  test('versão 17 com NFC-e atualiza para a 18 sem perder as notas, e a nota pode ficar cancelada', () {
    final raw = LocalDatabase.migratedInMemory(17);
    const now = '2026-11-26T10:00:00Z';
    raw.execute(
      'INSERT INTO nfce_document (id, sale_id, series, number, access_key, environment, emission_type, status, protocol, xml, qr_code, '
      'consult_url, emitted_at, authorized_at, attempts, updated_at) '
      "VALUES (randomblob(16), randomblob(16), 4, 42, '35261111222333000181650040000000421000000019', 2, 1, 'authorized', "
      "'135260000000123', '<nfeProc/>', 'qr', 'url', ?, ?, 1, ?)",
      [now, now, now],
    );
    final database = LocalDatabase.fromDatabase(raw);
    addTearDown(database.close);
    expect(database.schemaVersion, 22);
    expect(raw.select('SELECT number, status, protocol FROM nfce_document').first, {'number': 42, 'status': 'authorized', 'protocol': '135260000000123'});
    raw.execute("UPDATE nfce_document SET status = 'canceled'");
    expect(raw.select('SELECT status FROM nfce_document').first['status'], 'canceled');
    expect(() => raw.execute("UPDATE nfce_document SET status = 'outra'"), throwsA(anything));
    expect(raw.select('PRAGMA foreign_keys').first.columnAt(0), 1);
  });
}
