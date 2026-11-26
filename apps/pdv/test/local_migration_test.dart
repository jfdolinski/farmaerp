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
}
