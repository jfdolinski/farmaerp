import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setUser } from './helpers.mjs';

// Inventário de abertura: contagem por planilha e digitação, conferência contra o saldo no corte,
// aplicação (contado vira saldo, não contado vai a zero), lotes e fora do SNGPC.

let a;
let b;
const CUTOFF = '2026-10-01T18:00:00-03:00';
const BEFORE = '2026-09-30T10:00:00-03:00';
const AFTER = '2026-10-02T10:00:00-03:00';

async function run(setup, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setup(client);
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);

/** Produto com código de barras (e código anterior), criado direto no banco. */
async function product(name, { legacy = null, tracksBatches = false } = {}) {
  const client = await ownerPool.connect();
  try {
    await client.query('BEGIN');
    const id = (await client.query(
      'INSERT INTO product (economic_group_id, display_name, legacy_code) VALUES ($1, $2, $3) RETURNING id', [a.group.id, name, legacy],
    )).rows[0].id;
    const barcode = `INV${randomInt(1e9)}`;
    await client.query('SELECT app.insert_product_barcode($1, $2, $3, true, true, true, true, NULL, NULL)', [a.group.id, id, barcode]);
    if (tracksBatches) {
      await client.query('UPDATE product_branch_status SET tracks_batches = true WHERE product_id = $1 AND branch_id = $2', [id, a.branch1.id]);
    }
    await client.query('COMMIT');
    return { id, barcode, code: (await ownerPool.query('SELECT code FROM product WHERE id = $1', [id])).rows[0].code };
  } finally {
    client.release();
  }
}
const move = (productId, quantity, at, { type = 'adjustment', batchId = null } = {}) => ownerPool.query(
  `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity, occurred_at, reason)
   VALUES ($1, $2, $3, $4, $5, $6, $7, 'teste')`, [a.group.id, a.branch1.id, productId, batchId, type, quantity, at],
);
const balance = async (productId, batchId) => Number((await ownerPool.query(
  'SELECT COALESCE(sum(quantity), 0) AS q FROM stock_balance WHERE product_id = $1 AND branch_id = $2 AND batch_id IS NOT DISTINCT FROM $3 AND deleted_at IS NULL',
  [productId, a.branch1.id, batchId],
)).rows[0].q);
const batchId = async (productId, number) => (await ownerPool.query(
  'SELECT id FROM product_batch WHERE product_id = $1 AND branch_id = $2 AND upper(batch_number) = $3', [productId, a.branch1.id, number],
)).rows[0]?.id ?? null;

let p1;
let p2;
let p3;
let p4;
let p5;
let countId;
let l1;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  p1 = await product('Contado a menos');
  p2 = await product('Não contado');
  p3 = await product('Achado na prateleira', { legacy: `ANT${randomInt(1e9)}` });
  p4 = await product('Com lote');
  p5 = await product('Vendido depois do corte');
  await move(p1.id, 10, BEFORE);
  await move(p1.id, -1, AFTER, { type: 'import' });
  await move(p2.id, 5, BEFORE);
  // Saldo antigo sem lote (negativo, como deixa a venda importada) e um lote com saldo.
  await move(p4.id, -2, BEFORE, { type: 'import' });
  // Passou a exigir lote depois da venda antiga.
  await ownerPool.query('UPDATE product_branch_status SET tracks_batches = true WHERE product_id = $1 AND branch_id = $2', [p4.id, a.branch1.id]);
  l1 = (await ownerPool.query('SELECT app.batch_for_entry($1, $2, $3, $4, $5, NULL) AS id', [a.group.id, a.branch1.id, p4.id, 'L1', '2027-06-30'])).rows[0].id;
  await move(p4.id, 3, BEFORE, { batchId: l1 });
  await move(p5.id, 4, BEFORE);
  await move(p5.id, -4, AFTER, { type: 'import' });
});
afterAll(closePools);

describe('abertura do inventário', () => {
  it('só com a permissão; corte no futuro recusado; um em contagem por filial', async () => {
    await expect(asUser(a.oneBranchUser, 'SELECT app.create_stock_count($1, $2, NULL)', [a.branch1.id, CUTOFF])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(b.admin, 'SELECT app.create_stock_count($1, $2, NULL)', [a.branch1.id, CUTOFF])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.admin, "SELECT app.create_stock_count($1, now() + interval '1 day', NULL)", [a.branch1.id])).rejects.toSatisfy(hasCode('FA747'));
    countId = (await asUser(a.admin, 'SELECT app.create_stock_count($1, $2, $3) AS id', [a.branch1.id, CUTOFF, 'Abertura da loja']))[0].id;
    await expect(asUser(a.admin, 'SELECT app.create_stock_count($1, $2, NULL)', [a.branch1.id, CUTOFF])).rejects.toSatisfy(hasCode('FA744'));
  });
});

describe('contagem', () => {
  it('planilha soma por seção, acha pelo código anterior e recusa linha com problema sem parar', async () => {
    const result = (await asUser(a.admin, 'SELECT app.stock_count_load($1, $2::jsonb) AS r', [countId, JSON.stringify([
      { line: 2, lookup: p1.barcode, quantity: '3' },
      { line: 3, lookup: String(p1.code), quantity: '4', batch: 'IGNORADO', expires_on: '2027-01-01' },
      { line: 4, lookup: (await ownerPool.query('SELECT legacy_code FROM product WHERE id = $1', [p3.id])).rows[0].legacy_code, quantity: '4' },
      { line: 5, lookup: p4.barcode, quantity: '2', batch: ' l1 ', expires_on: '2027-07-31' },
      { line: 6, lookup: p4.barcode, quantity: '5', batch: 'L2', expires_on: '2028-01-31' },
      { line: 7, lookup: p4.barcode, quantity: '1' },
      { line: 8, lookup: 'NAO-EXISTE', quantity: '1' },
      { line: 9, lookup: p5.barcode, quantity: '-1' },
      { line: 10, lookup: p5.barcode, quantity: 'abc' },
      { line: 11, lookup: p5.barcode, quantity: '1.0005' },
    ])]))[0].r;
    expect(result.accepted).toBe(5);
    expect(result.rejected_total).toBe(5);
    expect(result.rejected.map((r) => [r.line, r.reason])).toEqual([
      [7, 'Produto que exige lote: informe o lote e a validade.'],
      [8, 'Produto não encontrado pelo código.'],
      [9, 'Quantidade inválida.'],
      [10, 'Quantidade ou validade fora do formato.'],
      [11, 'Quantidade inválida.'],
    ]);
    const items = await asUser(a.admin, 'SELECT * FROM app.stock_count_items($1)', [countId]);
    const p1Row = items.find((i) => i.product_id === p1.id);
    expect([Number(p1Row.quantity), p1Row.batch_number, p1Row.source]).toEqual([7, null, 'file']);
    expect(items.filter((i) => i.product_id === p4.id).map((i) => [i.batch_number, i.expires_on.toISOString().slice(0, 10)]))
      .toEqual([['L1', '2027-07-31'], ['L2', '2028-01-31']]);
  });

  it('digitação define a quantidade; produto com lote exige lote; tira linha', async () => {
    await asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, $3)', [countId, p5.barcode, 1]);
    await asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, $3)', [countId, p5.barcode, 1]);
    await expect(asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, 1)', [countId, p4.barcode])).rejects.toSatisfy(hasCode('FA746'));
    await expect(asUser(a.admin, "SELECT app.stock_count_set_item($1, 'NAO-EXISTE', NULL, NULL, 1)", [countId])).rejects.toSatisfy(hasCode('FA004'));
    await expect(asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, -1)', [countId, p5.barcode])).rejects.toSatisfy(hasCode('FA810'));
    await expect(asUser(a.oneBranchUser, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, 1)', [countId, p5.barcode])).rejects.toSatisfy(hasCode('FA006'));
    await asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, 7)', [countId, p1.barcode]);
    const items = await asUser(a.admin, 'SELECT * FROM app.stock_count_items($1)', [countId]);
    expect(items.find((i) => i.product_id === p1.id)).toMatchObject({ source: 'typed' });
    expect(items.filter((i) => i.product_id === p5.id).map((i) => [Number(i.quantity), i.source])).toEqual([[1, 'typed']]);
    const extra = await product('Contado por engano');
    await asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, 9)', [countId, extra.barcode]);
    const wrong = (await asUser(a.admin, 'SELECT * FROM app.stock_count_items($1)', [countId])).find((i) => i.product_id === extra.id);
    await asUser(a.admin, 'SELECT app.stock_count_remove_item($1)', [wrong.id]);
    expect((await asUser(a.admin, 'SELECT * FROM app.stock_count_items($1)', [countId])).some((i) => i.product_id === extra.id)).toBe(false);
  });
});

describe('conferência e aplicação', () => {
  it('conferência contra o saldo no corte; lote existente com outra validade impede aplicar', async () => {
    const review = await asUser(a.admin, 'SELECT * FROM app.stock_count_review($1)', [countId]);
    const line = (productId, batch = null) => review.find((r) => r.product_id === productId && r.batch_number === batch);
    // P1: no corte havia 10 (a venda de depois não conta); contados 7.
    expect([Number(line(p1.id).expected), Number(line(p1.id).counted), Number(line(p1.id).difference)]).toEqual([10, 7, -3]);
    expect([Number(line(p2.id).expected), line(p2.id).was_counted, Number(line(p2.id).difference)]).toEqual([5, false, -5]);
    expect(Number(line(p3.id).difference)).toBe(4);
    expect([Number(line(p4.id).expected), Number(line(p4.id).difference)]).toEqual([-2, 2]);
    expect([Number(line(p4.id, 'L1').expected), Number(line(p4.id, 'L1').difference)]).toEqual([3, -1]);
    expect(line(p4.id, 'L1').problem).toBe('O lote já existe com a validade 30/06/2027.');
    expect([Number(line(p5.id).expected), Number(line(p5.id).difference)]).toEqual([4, -3]);
    await expect(asUser(a.admin, 'SELECT app.apply_stock_count($1)', [countId])).rejects.toSatisfy(hasCode('FA746'));
    // Corrige a validade digitando a linha do lote.
    await asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, $3, $4, 2)', [countId, p4.barcode, 'L1', '2027-06-30']);
    expect((await asUser(a.admin, 'SELECT * FROM app.stock_count_review($1) WHERE problem IS NOT NULL', [countId]))).toEqual([]);
    // Quem só vê a filial sem a permissão do inventário não confere.
    await expect(asUser(a.oneBranchUser, 'SELECT * FROM app.stock_count_review($1)', [countId])).rejects.toSatisfy(hasCode('FA006'));
  });

  it('aplica: contado vira saldo, não contado vai a zero, lote novo nasce, saldo pode ficar negativo; fora do SNGPC', async () => {
    const controlled = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
      sourceKey: `inv-${randomInt(1e9)}`, name: 'Controlado do inventário', controlledClass: 'B1',
    })])).rows[0].id;
    await ownerPool.query('UPDATE product SET catalog_product_id = $1 WHERE id = $2', [controlled, p4.id]);
    await ownerPool.query('INSERT INTO sngpc_branch (economic_group_id, branch_id, opened_by) VALUES ($1, $2, $3)', [a.group.id, a.branch1.id, a.admin.id]);
    const totals = (await asUser(a.admin, 'SELECT app.apply_stock_count($1) AS t', [countId]))[0].t;
    // Zerados: P2 e o saldo antigo sem lote do P4; acrescentados: P3 e o lote L2.
    expect(totals).toEqual({ counted_lines: 5, raised: 2, lowered: 3, zeroed: 2 });
    // P1: 7 contados, menos a venda depois do corte.
    expect(await balance(p1.id, null)).toBe(6);
    expect(await balance(p2.id, null)).toBe(0);
    expect(await balance(p3.id, null)).toBe(4);
    expect(await balance(p4.id, null)).toBe(0);
    expect(await balance(p4.id, l1)).toBe(2);
    const l2 = await batchId(p4.id, 'L2');
    expect(await balance(p4.id, l2)).toBe(5);
    expect((await ownerPool.query('SELECT expires_on FROM product_batch WHERE id = $1', [l2])).rows[0].expires_on.toISOString().slice(0, 10)).toBe('2028-01-31');
    // P5: contado 1 no corte, mas vendeu 4 depois: fica -3.
    expect(await balance(p5.id, null)).toBe(-3);
    const movements = (await ownerPool.query('SELECT movement_type, occurred_at, reason FROM stock_movement WHERE stock_count_id = $1', [countId])).rows;
    expect(movements).toHaveLength(7);
    expect(movements.every((m) => m.movement_type === 'inventory' && m.occurred_at.toISOString() === '2026-10-01T21:00:00.000Z')).toBe(true);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE product_id = ANY ($1)', [[p1.id, p4.id]])).rows[0].n).toBe(0);
    const [listed] = await asUser(a.admin, 'SELECT * FROM app.list_stock_counts($1)', [a.branch1.id]);
    expect(listed).toMatchObject({ id: countId, status: 'applied', note: 'Abertura da loja', item_count: 5, can_change: false });
    expect(listed.applied_at).not.toBeNull();
  });

  it('depois de aplicado não muda; novo inventário só com corte depois; cancelar não mexe no estoque', async () => {
    await expect(asUser(a.admin, 'SELECT app.apply_stock_count($1)', [countId])).rejects.toSatisfy(hasCode('FA745'));
    await expect(asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, 1)', [countId, p1.barcode])).rejects.toSatisfy(hasCode('FA745'));
    const [anyItem] = await asUser(a.admin, 'SELECT * FROM app.stock_count_items($1)', [countId]);
    await expect(asUser(a.admin, 'SELECT app.stock_count_remove_item($1)', [anyItem.id])).rejects.toSatisfy(hasCode('FA745'));
    await expect(asUser(a.admin, 'SELECT app.create_stock_count($1, $2, NULL)', [a.branch1.id, BEFORE])).rejects.toSatisfy(hasCode('FA747'));
    const second = (await asUser(a.admin, 'SELECT app.create_stock_count($1, $2, NULL) AS id', [a.branch1.id, AFTER]))[0].id;
    await asUser(a.admin, 'SELECT app.stock_count_set_item($1, $2, NULL, NULL, 100)', [second, p1.barcode]);
    await asUser(a.admin, 'SELECT app.cancel_stock_count($1)', [second]);
    expect(await balance(p1.id, null)).toBe(6);
    await expect(asUser(a.admin, 'SELECT app.apply_stock_count($1)', [second])).rejects.toSatisfy(hasCode('FA745'));
    // Cancelado libera a abertura de outro.
    const third = (await asUser(a.admin, 'SELECT app.create_stock_count($1, $2, NULL) AS id', [a.branch1.id, AFTER]))[0].id;
    expect(third).toBeTruthy();
    expect(await asUser(b.admin, 'SELECT * FROM app.list_stock_counts()')).toEqual([]);
  });

  it('a API não grava direto nas tabelas', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      await expect(client.query("UPDATE stock_count SET status = 'applied'")).rejects.toMatchObject({ code: '42501' });
      await client.query('ROLLBACK');
    } finally {
      client.release();
    }
  });
});
