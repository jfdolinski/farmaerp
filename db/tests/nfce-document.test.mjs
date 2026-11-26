import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// NFC-e emitida no caixa chegando à central pela outbox (item "nfce").

let a;
let b;
let operator;
let product;
let session;
let series;
let otherSeries;
let clockMs = Date.now();
let sequence = 0;
let saleNumber = randomInt(1000, 900000);

function uuidV7() {
  clockMs += 1;
  const bytes = randomBytes(16);
  bytes.writeUIntBE(clockMs, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const key = () => Array.from({ length: 44 }, () => randomInt(10)).join('');
const XML = `<nfeProc versao="4.00">${'x'.repeat(200)}</nfeProc>`;

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
async function push(terminal, kind, payload) {
  sequence += 1;
  const rows = await run((c) => setTerminal(c, terminal.id), 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
    { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind, payload },
  ])]);
  return rows[0].r.results[0];
}
async function newSale(terminal = a.terminal1, cashSession = session) {
  saleNumber += 1;
  const id = uuidV7();
  const result = await push(terminal, 'sale', {
    id, number: saleNumber, cash_session_id: cashSession, operator_id: operator.id, customer_id: null,
    sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: product, barcode_id: null, quantity: 1, unit_price: 10, discount: 0, total: 10, batch_id: null, release: null }],
    payments: [{ id: uuidV7(), method: 'cash', amount: 10, change: 0 }], subtotal: 10, discount_total: 0, total: 10,
  });
  expect(result.status).toBe('applied');
  return id;
}
const nfce = (saleId, overrides = {}) => ({
  id: uuidV7(), sale_id: saleId, series: series.series, number: randomInt(1, 999999), access_key: key(), environment: 2, emission_type: 1,
  status: 'authorized', protocol: String(randomInt(1e9, 9e9)).padEnd(15, '0'), status_code: '100', reason: 'Autorizado o uso da NF-e',
  xml: XML, emitted_at: new Date().toISOString(), authorized_at: new Date().toISOString(), ...overrides,
});
const fiscalStatus = (saleId) => ownerPool.query('SELECT fiscal_status FROM sale WHERE id = $1', [saleId]).then((r) => r.rows[0].fiscal_status);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const roleOf = async (name) => (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, name])).rows[0].id;
  const { rows: [user] } = await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Operador ${randomInt(1e6)}`]);
  for (const branch of [a.branch1, a.branch2]) {
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, await roleOf('Operador de caixa'), branch.id]);
  }
  operator = user;
  product = (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto NFC-e ${randomInt(1e6)}`, barcode: gtin() })]))[0].id;
  await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 10, NULL)', [product]);
  session = uuidV7();
  expect((await push(a.terminal1, 'cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
  series = (await ownerPool.query("SELECT * FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [a.terminal1.id])).rows[0];
  otherSeries = (await ownerPool.query("SELECT series FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [a.terminal2.id])).rows[0].series;
});
afterAll(closePools);

describe('NFC-e do caixa na central', () => {
  it('autorizada: guarda a nota, a venda fica autorizada e a série anda', async () => {
    const saleId = await newSale();
    expect(await fiscalStatus(saleId)).toBe('pending');
    const doc = nfce(saleId, { number: 500 });
    expect(await push(a.terminal1, 'nfce', doc)).toMatchObject({ status: 'applied', code: null });
    expect(await fiscalStatus(saleId)).toBe('authorized');
    const row = (await ownerPool.query('SELECT * FROM fiscal_document WHERE id = $1', [doc.id])).rows[0];
    expect(row).toMatchObject({ terminal_id: a.terminal1.id, branch_id: a.branch1.id, series: series.series, access_key: doc.access_key, status: 'authorized' });
    expect(Number((await ownerPool.query('SELECT last_used_number FROM terminal_fiscal_series WHERE id = $1', [series.id])).rows[0].last_used_number))
      .toBeGreaterThanOrEqual(500);

    // A mesma nota de novo (mesmo id), já autorizada: o caixa não muda nada e a fila dele segue.
    expect(await push(a.terminal1, 'nfce', { ...doc, status: 'rejected', protocol: null, authorized_at: null }))
      .toMatchObject({ status: 'applied' });
    expect(await fiscalStatus(saleId)).toBe('authorized');

    // Na retaguarda: situação sem o XML; o XML à parte.
    const [{ d }] = await asUser(a.admin, 'SELECT app.sale_fiscal_document($1) AS d', [saleId]);
    expect(d).toMatchObject({ status: 'authorized', access_key: doc.access_key, series: series.series });
    expect(d.xml).toBeUndefined();
    const [{ x }] = await asUser(a.admin, 'SELECT app.sale_fiscal_xml($1) AS x', [saleId]);
    expect(x.xml).toBe(XML);
    expect((await asUser(b.admin, 'SELECT app.sale_fiscal_xml($1) AS x', [saleId]))[0].x).toBeNull();
    expect((await asUser(a.oneBranchUser, 'SELECT app.sale_fiscal_document($1) AS d', [saleId]))[0].d).toBeNull();
  });

  it('pendente vira autorizada pelo mesmo id; rejeitada fica com o motivo', async () => {
    const saleId = await newSale();
    const pending = nfce(saleId, { status: 'pending', protocol: null, authorized_at: null, status_code: null, reason: 'Sefaz não respondeu' });
    expect(await push(a.terminal1, 'nfce', pending)).toMatchObject({ status: 'applied' });
    expect(await fiscalStatus(saleId)).toBe('pending');
    expect(await push(a.terminal1, 'nfce', { ...pending, status: 'authorized', protocol: '135260000000001', status_code: '100', authorized_at: new Date().toISOString() }))
      .toMatchObject({ status: 'applied' });
    expect(await fiscalStatus(saleId)).toBe('authorized');

    const rejectedSale = await newSale();
    expect(await push(a.terminal1, 'nfce', nfce(rejectedSale, { status: 'rejected', protocol: null, authorized_at: null, status_code: '539', reason: 'Duplicidade de NF-e' })))
      .toMatchObject({ status: 'applied' });
    expect(await fiscalStatus(rejectedSale)).toBe('rejected');
  });

  it('recusa nota de venda de outro terminal, série errada, chave repetida e dados inválidos', async () => {
    const saleId = await newSale();
    const used = nfce(saleId);
    expect(await push(a.terminal1, 'nfce', used)).toMatchObject({ status: 'applied' });
    const other = await newSale();
    const bad = [
      nfce(other, { series: series.series + 1 }),
      nfce(other, { access_key: used.access_key }),
      nfce(other, { access_key: '123' }),
      nfce(other, { status: 'authorized', protocol: null }),
      nfce(other, { status: 'outro' }),
      nfce(other, { xml: 'curto' }),
      nfce(other, { emitted_at: 'ontem' }),
      nfce(other, { id: 'nada' }),
      nfce(other, { series: 'um' }),
      nfce(uuidV7()),
      // Id de uma nota que já existe, para outra venda.
      { ...nfce(other), id: used.id },
    ];
    for (const payload of bad) {
      expect(await push(a.terminal1, 'nfce', payload), JSON.stringify(payload).slice(0, 80)).toMatchObject({ status: 'conflict', code: 'FA735' });
    }
    // Série que existe, mas é de outro terminal (um caixa novo na filial 2 ganha a série seguinte).
    const extra = (await ownerPool.query(
      "INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', 'active', $3) RETURNING id",
      [a.branch2.id, `Caixa extra ${randomInt(1e6)}`, `chave-${uuidV7()}`],
    )).rows[0];
    const extraSeries = (await ownerPool.query("SELECT series FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [extra.id])).rows[0].series;
    expect(extraSeries).not.toBe(series.series);
    expect(await push(a.terminal1, 'nfce', nfce(other, { series: extraSeries }))).toMatchObject({ status: 'conflict', code: 'FA735' });
    // Id de uma nota pendente reaproveitado para outra venda.
    const pendingSale = await newSale();
    const pending = nfce(pendingSale, { status: 'pending', protocol: null, authorized_at: null });
    expect(await push(a.terminal1, 'nfce', pending)).toMatchObject({ status: 'applied' });
    expect(await push(a.terminal1, 'nfce', { ...nfce(other), id: pending.id })).toMatchObject({ status: 'conflict', code: 'FA735' });
    expect(await fiscalStatus(pendingSale)).toBe('pending');
    // Venda de outro terminal.
    expect(await push(a.terminal2, 'nfce', nfce(other, { series: otherSeries }))).toMatchObject({ status: 'conflict', code: 'FA735' });
    expect(await fiscalStatus(other)).toBe('pending');
  });

  it('a API não grava nem lê o XML direto', async () => {
    await expect(asUser(a.admin, 'SELECT xml FROM v_fiscal_document LIMIT 1')).rejects.toThrow();
    await expect(asUser(a.admin, "UPDATE fiscal_document SET status = 'rejected'")).rejects.toThrow();
  });
});
