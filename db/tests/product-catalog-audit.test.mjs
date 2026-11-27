import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, asOwner, asUser, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

async function catalogItem(name = 'Paracetamol Auditoria 750 mg') {
  const item = {
    sourceKey: `auditoria-${randomBytes(6).toString('hex')}`,
    name,
    manufacturer: `Fabricante ${randomBytes(3).toString('hex')}`,
    barcodes: [gtin()],
  };
  const { rows } = await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify(item)]);
  return { ...item, id: rows[0].id };
}

const create = (client, data = {}) =>
  client
    .query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: 'Produto auditoria', barcode: gtin(), ...data })])
    .then((r) => r.rows[0].id);
const update = (client, id, data = {}) =>
  client.query('SELECT app.update_product($1, $2::jsonb)', [id, JSON.stringify({ displayName: 'Produto auditoria', ...data })]);
const history = (client, id) =>
  client.query('SELECT * FROM app.product_catalog_history($1)', [id]).then((r) => r.rows);
const events = (client, id) =>
  client
    .query('SELECT kind, source, query, result_count, catalog_product_id, previous_catalog_product_id, user_id FROM v_product_catalog_event WHERE product_id = $1 ORDER BY id', [id])
    .then((r) => r.rows);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('auditoria do Catálogo no cadastro do produto', () => {
  it('cadastro já vinculado: a busca que levou ao item vem antes do vínculo, com a origem', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, {
        catalogProductId: item.id,
        catalogSource: 'barcode',
        catalogLookup: { kind: 'lookup', query: item.barcodes[0], resultCount: 1 },
      });
      expect(await events(client, id)).toEqual([
        { kind: 'lookup', source: null, query: item.barcodes[0], result_count: 1, catalog_product_id: item.id, previous_catalog_product_id: null, user_id: a.admin.id },
        { kind: 'linked', source: 'barcode', query: null, result_count: null, catalog_product_id: item.id, previous_catalog_product_id: null, user_id: a.admin.id },
      ]);
      const rows = await history(client, id);
      expect(rows.map((r) => r.kind)).toEqual(['linked', 'lookup']);
      expect(rows[0]).toMatchObject({ catalog_name: item.name, user_name: a.admin.name });
    });
  });

  it('busca manual no cadastro: fica como busca; sem origem informada o vínculo é manual', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { catalogProductId: item.id, catalogLookup: { kind: 'search', query: '  paracetamol ', resultCount: 7 } });
      const rows = await events(client, id);
      expect(rows.map((r) => [r.kind, r.source, r.query, r.result_count, r.catalog_product_id])).toEqual([
        ['search', null, 'paracetamol', 7, null],
        ['linked', 'manual', null, null, item.id],
      ]);
      // Origem desconhecida também vira manual.
      const other = await create(client, { catalogProductId: (await catalogItem()).id, catalogSource: 'qualquer' });
      expect((await events(client, other)).map((r) => [r.kind, r.source])).toEqual([['linked', 'manual']]);
    });
  });

  it('cadastro sem Catálogo não registra nada, nem a busca; busca incompleta é ignorada', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { catalogLookup: { kind: 'search', query: 'nada', resultCount: 0 } });
      expect(await events(client, id)).toEqual([]);
      const linked = await create(client, { catalogProductId: item.id, catalogLookup: { kind: 'search', query: '  ' , resultCount: 3 } });
      expect((await events(client, linked)).map((r) => r.kind)).toEqual(['linked']);
    });
  });

  it('alteração: vincular, trocar e desfazer ficam registrados; salvar sem mudar o vínculo não registra', async () => {
    const first = await catalogItem();
    const second = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await update(client, id, { catalogProductId: first.id, catalogSource: 'barcode' });
      await update(client, id, { catalogProductId: first.id, displayName: 'Outro nome' });
      await update(client, id, { catalogProductId: second.id });
      await update(client, id, {});
      expect((await events(client, id)).map((r) => [r.kind, r.source, r.catalog_product_id, r.previous_catalog_product_id])).toEqual([
        ['linked', 'barcode', first.id, null],
        ['changed', 'manual', second.id, first.id],
        ['unlinked', 'manual', null, second.id],
      ]);
      const rows = await history(client, id);
      expect(rows[1]).toMatchObject({ kind: 'changed', catalog_name: second.name, previous_catalog_name: first.name });
    });
  });

  it('a origem não vaza para outro produto da mesma transação', async () => {
    const first = await catalogItem();
    const second = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      await create(client, { catalogProductId: first.id, catalogSource: 'barcode', catalogLookup: { kind: 'lookup', query: '123', resultCount: 1 } });
      const plain = await create(client);
      await update(client, plain, { catalogProductId: second.id });
      expect((await events(client, plain)).map((r) => [r.kind, r.source])).toEqual([['linked', 'manual']]);
    });
  });

  it('a importação de notas cria o produto vinculado pelo GTIN com origem importação, sem usuário', async () => {
    const item = await catalogItem();
    await asOwner(async (client) => {
      await client.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'import', true)");
      const id = (await client.query(
        'SELECT app.import_product($1, $2::jsonb, now()) AS id',
        [a.group.id, JSON.stringify({ code: `ANT-${randomInt(1e9)}`, gtin: item.barcodes[0], name: 'Importado' })],
      )).rows[0].id;
      const { rows } = await client.query('SELECT kind, source, catalog_product_id, user_id FROM product_catalog_event WHERE product_id = $1', [id]);
      expect(rows).toEqual([{ kind: 'linked', source: 'import', catalog_product_id: item.id, user_id: null }]);
      // Origem informada pela tela não se passa por importação.
      await client.query("SELECT set_config('app.worker', '', true), set_config('app.user_id', $1, true)", [a.admin.id]);
      const typed = await create(client, { catalogProductId: (await catalogItem()).id, catalogSource: 'import' });
      expect((await client.query('SELECT source FROM product_catalog_event WHERE product_id = $1', [typed])).rows).toEqual([{ source: 'manual' }]);
    });
  });

  it('depois do cadastro, a origem e a busca não passam para o próximo vínculo da transação', async () => {
    await asOwner(async (client) => {
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      const plain = await create(client);
      await create(client, {
        catalogProductId: (await catalogItem()).id,
        catalogSource: 'barcode',
        catalogLookup: { kind: 'lookup', query: '7890000000000', resultCount: 1 },
      });
      // Vínculo feito direto, fora do cadastro: manual e sem busca.
      await client.query('UPDATE product SET catalog_product_id = $1 WHERE id = $2', [(await catalogItem()).id, plain]);
      await client.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'import', true)");
      const imported = (await client.query('SELECT app.import_product($1, $2::jsonb, now()) AS id', [
        a.group.id, JSON.stringify({ code: `ANT-${randomInt(1e9)}`, gtin: (await catalogItem()).barcodes[0], name: 'Importado' }),
      ])).rows[0].id;
      const kinds = async (id) => (await client.query('SELECT kind, source FROM product_catalog_event WHERE product_id = $1 ORDER BY id', [id])).rows;
      expect(await kinds(plain)).toEqual([{ kind: 'linked', source: 'manual' }]);
      expect(await kinds(imported)).toEqual([{ kind: 'linked', source: 'import' }]);
    });
  });

  it('busca registrada na tela do produto; a automática repetida com o mesmo resultado não duplica', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      const record = (kind, query, count, catalogId = null) =>
        client.query('SELECT app.record_catalog_search($1, $2, $3, $4, $5)', [id, kind, query, count, catalogId]);
      await record('search', ' dipirona ', 4);
      await record('search', 'dipirona', 4);
      await record('lookup', item.barcodes[0], 1, item.id);
      await record('lookup', item.barcodes[0], 1, item.id);
      await record('lookup', item.barcodes[0], 0);
      await record('lookup', item.barcodes[0], 2);
      expect((await events(client, id)).map((r) => [r.kind, r.query, r.result_count, r.catalog_product_id])).toEqual([
        ['search', 'dipirona', 4, null],
        ['search', 'dipirona', 4, null],
        ['lookup', item.barcodes[0], 1, item.id],
        ['lookup', item.barcodes[0], 0, null],
        ['lookup', item.barcodes[0], 2, null],
      ]);
      await expectCode(client, () => record('outro', 'x', 1), 'FA005');
      await expectCode(client, () => record('search', '   ', 1), 'FA005');
      await expectCode(client, () => record('search', 'x', -1), 'FA005');
      await expectCode(client, () => record('search', 'x', null), 'FA005');
    });
  });

  it('sem permissão de cadastro não registra busca; produto de outro grupo não existe', async () => {
    const client = await appPool.connect();
    const record = (id) => client.query('SELECT app.record_catalog_search($1, $2, $3, $4)', [id, 'search', 'x', 1]);
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      const id = await create(client);
      await expectCode(client, () => record(randomUUIDv7Like()), 'FA006');
      await client.query("SELECT set_config('app.user_id', $1, true)", [b.admin.id]);
      await expectCode(client, () => record(id), 'FA006');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.oneBranchUser.id]);
      await expectCode(client, () => record(id), 'FA002');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      expect(await events(client, id)).toEqual([]);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('cada grupo vê só a auditoria dos seus produtos; quem não vê produtos não vê nada', async () => {
    const item = await catalogItem();
    const client = await appPool.connect();
    let id;
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      id = await create(client, { catalogProductId: item.id });
      expect(await history(client, id)).toHaveLength(1);
      await client.query("SELECT set_config('app.user_id', $1, true)", [b.admin.id]);
      expect(await history(client, id)).toEqual([]);
      expect(await events(client, id)).toEqual([]);
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.oneBranchUser.id]);
      expect(await history(client, id)).toEqual([]);
      expect(await events(client, id)).toEqual([]);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('o registro não se altera nem se apaga pela aplicação', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { catalogProductId: item.id });
      await client.query('SAVEPOINT s');
      await expect(client.query("UPDATE product_catalog_event SET kind = 'unlinked' WHERE product_id = $1", [id])).rejects.toMatchObject({ code: '42501' });
      await client.query('ROLLBACK TO s');
      await expect(client.query("INSERT INTO product_catalog_event (economic_group_id, product_id, kind, source) VALUES ($1, $2, 'linked', 'manual')", [a.group.id, id]))
        .rejects.toMatchObject({ code: '42501' });
    });
    await asOwner(async (client) => {
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      const id = await create(client, { catalogProductId: (await catalogItem()).id });
      await client.query('SAVEPOINT s');
      await expect(client.query("UPDATE product_catalog_event SET source = 'barcode' WHERE product_id = $1", [id])).rejects.toSatisfy(hasCode('FA104'));
      await client.query('ROLLBACK TO s');
    });
  });
});

/** Identificador qualquer que não existe. */
function randomUUIDv7Like() {
  const hex = randomBytes(16).toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-7${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}
