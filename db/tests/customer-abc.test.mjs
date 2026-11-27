import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Parte D do lote de 26/11: curva ABC de clientes por filial, com recálculo por curva.

let a;
let b;
let product;
let session;
let operator;
let clockMs = Date.now();
let sequence = 0;
let saleNumber = 600000 + randomInt(9000);
const DAY = 86400000;
const NOW = new Date('2026-11-27T12:00:00Z');

const tag = () => randomBytes(4).toString('hex');
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
/** CPF com dígitos certos, gerado ao acaso (não é de ninguém de propósito). */
function cpf() {
  const digits = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(digits).size === 1) digits[0] = (digits[0] + 1) % 10;
  for (const size of [9, 10]) {
    const sum = digits.slice(0, size).reduce((total, digit, index) => total + digit * (size + 1 - index), 0);
    const rest = (sum * 10) % 11;
    digits.push(rest === 10 ? 0 : rest);
  }
  return digits.join('');
}
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
const asWorker = (sql, params) => run((c) => c.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'abc', true)"), sql, params);
async function push(entries, terminal = a.terminal1) {
  const rows = await run((c) => setTerminal(c, terminal.id), 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(entries.map(([kind, payload]) => {
    sequence += 1;
    return { id: uuidV7(), sequence, kind, payload };
  }))]);
  return rows[0].r.results;
}
const customer = async (name) => (await ownerPool.query(
  "INSERT INTO customer (economic_group_id, person_type, document, name) VALUES ($1, 'individual', $3, $2) RETURNING id", [a.group.id, `${name} ${tag()}`, cpf()],
)).rows[0].id;
/** Venda do PDV na filial 1 (do terminal 1) para o cliente, na data dada. */
async function sell(customerId, soldAt, terminal = a.terminal1) {
  saleNumber += 1;
  const id = uuidV7();
  const results = await push([['sale', {
    id, number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId, seller_id: null, quote_id: null,
    sold_at: soldAt.toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: product, quantity: 1, unit_price: 10, discount: 0, total: 10 }],
    payments: [{ id: uuidV7(), method: 'cash', amount: 10 }], subtotal: 10, discount_total: 0, total: 10,
  }]], terminal);
  if (results[0].status !== 'applied') throw new Error(JSON.stringify(results[0]));
  return id;
}
const daysAgo = (days) => new Date(NOW.getTime() - days * DAY);
const recalc = async (curve, at = NOW, branch = a.branch1.id) =>
  (await ownerPool.query('SELECT app.abc_recalculate($1, $2, $3) AS n', [branch, curve, at])).rows[0].n;
const curveOf = async (customerId, branch = a.branch1.id) =>
  (await ownerPool.query('SELECT curve, sales_count FROM customer_abc WHERE customer_id = $1 AND branch_id = $2 AND deleted_at IS NULL', [customerId, branch])).rows[0] ?? null;
const events = async (customerId) =>
  (await ownerPool.query('SELECT from_curve, to_curve, sales_count FROM customer_abc_event WHERE customer_id = $1 ORDER BY occurred_at, created_at', [customerId])).rows;

let heavy;
let middle;
let light;
let old;
let imported;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = a.admin;
  product = (await run((c) => setUser(c, a.admin.id), 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto ${tag()}`, barcode: gtin() })]))[0].id;
  await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 10, NULL)', [product]);
  session = uuidV7();
  await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: daysAgo(300).toISOString(), opening_float: 0 }]]);
  heavy = await customer('Fiel');
  middle = await customer('Médio');
  light = await customer('Raro');
  old = await customer('Antigo');
  imported = await customer('Importado');
  for (let i = 0; i < 12; i += 1) await sell(heavy, daysAgo(1 + i));
  for (let i = 0; i < 5; i += 1) await sell(middle, daysAgo(10 + i));
  await sell(light, daysAgo(3));
  // Fora do período (180 dias): não conta.
  for (let i = 0; i < 12; i += 1) await sell(old, daysAgo(200 + i));
  await sell(old, daysAgo(5));
  // Venda importada do sistema anterior conta junto: 3 importadas + 1 do PDV = 4 (B).
  const job = (await ownerPool.query(
    "INSERT INTO document_import (economic_group_id, file_name, size_bytes, received_bytes, status, created_by) VALUES ($1, 'abc.zip', 1, 1, 'done', $2) RETURNING id",
    [a.group.id, a.admin.id],
  )).rows[0].id;
  for (let i = 0; i < 3; i += 1) {
    await ownerPool.query(
      `INSERT INTO imported_sale (economic_group_id, branch_id, import_id, access_key, model, series, number, emitted_at, customer_id, subtotal, discount_total, total, change_amount, xml)
       VALUES ($1, $2, $3, $4, '65', 1, $5, $6, $7, 10, 0, 10, 0, $8)`,
      [a.group.id, a.branch1.id, job, String(randomInt(1e9)).padStart(44, '7'), randomInt(1e6), daysAgo(20 + i), imported, `<nfeProc>${'<x/>'.repeat(40)}</nfeProc>`],
    );
  }
  await sell(imported, daysAgo(2));
});
afterAll(closePools);

describe('padrões e cálculo', () => {
  it('filial sem parâmetros usa os padrões: 180 dias, A >= 12, B >= 4; recálculo 7, 15 e 30 dias', async () => {
    const s = (await ownerPool.query('SELECT (app.abc_setting($1)).*', [a.branch1.id])).rows[0];
    expect(s).toMatchObject({ id: null, period_days: 180, a_min_sales: 12, b_min_sales: 4, a_interval_days: 7, b_interval_days: 15, c_interval_days: 30 });
  });

  it('cada curva na sua vez: a A classifica só quem é A; a B e a C depois', async () => {
    expect(await recalc('A')).toBe(1);
    expect(await curveOf(heavy)).toEqual({ curve: 'A', sales_count: 12 });
    expect(await curveOf(middle)).toBeNull();
    expect(await recalc('B')).toBe(2);
    expect(await curveOf(middle)).toEqual({ curve: 'B', sales_count: 5 });
    // Importadas contam: 3 + 1.
    expect(await curveOf(imported)).toEqual({ curve: 'B', sales_count: 4 });
    expect(await recalc('C')).toBe(2);
    expect(await curveOf(light)).toEqual({ curve: 'C', sales_count: 1 });
    // As de 200 dias atrás não contam.
    expect(await curveOf(old)).toEqual({ curve: 'C', sales_count: 1 });
    expect(await events(heavy)).toEqual([{ from_curve: null, to_curve: 'A', sales_count: 12 }]);
    const settings = (await ownerPool.query('SELECT a_ran_at, b_ran_at, c_ran_at FROM abc_curve_setting WHERE branch_id = $1', [a.branch1.id])).rows[0];
    expect(Object.values(settings).map((v) => v.toISOString())).toEqual([NOW.toISOString(), NOW.toISOString(), NOW.toISOString()]);
    // A mudança desce para os caixas junto com o cliente.
    expect((await ownerPool.query("SELECT count(*)::int AS n FROM sync_change WHERE entity = 'customer' AND entity_id = $1", [heavy])).rows[0].n).toBeGreaterThan(0);
  });

  it('quem cai sai da curva na vez dela e vai para a curva certa; venda cancelada não conta', async () => {
    // O cliente fiel tem 8 vendas canceladas: fica com 4 (B).
    const sales = (await ownerPool.query('SELECT id FROM sale WHERE customer_id = $1 ORDER BY sold_at LIMIT 8', [heavy])).rows;
    for (const s of sales) {
      await ownerPool.query("UPDATE sale SET canceled_at = now(), cancel_reason = 'Cliente desistiu da compra', deleted_at = now() WHERE id = $1", [s.id]);
    }
    // Na vez da C, o fiel (A) não muda: ele não é C nem vai para C.
    expect(await recalc('C', new Date(NOW.getTime() + DAY))).toBe(0);
    expect((await curveOf(heavy)).curve).toBe('A');
    // Na vez da A, ele sai da A e vai para a B.
    expect(await recalc('A', new Date(NOW.getTime() + DAY))).toBe(1);
    expect(await curveOf(heavy)).toEqual({ curve: 'B', sales_count: 4 });
    expect((await events(heavy)).at(-1)).toEqual({ from_curve: 'A', to_curve: 'B', sales_count: 4 });
  });

  it('sem vendas no período, quem estava numa curva vai para a C na vez dela', async () => {
    // 400 dias depois, ninguém tem venda no período.
    const later = new Date(NOW.getTime() + 400 * DAY);
    await recalc('B', later);
    expect(await curveOf(middle)).toEqual({ curve: 'C', sales_count: 0 });
    expect(await curveOf(heavy)).toEqual({ curve: 'C', sales_count: 0 });
  });

  it('curva inválida: FA005', async () => {
    await expect(recalc('D')).rejects.toSatisfy(hasCode('FA005'));
  });
});

describe('rotina e retaguarda', () => {
  it('a rotina roda as curvas vencidas; só ela chama', async () => {
    await expect(asUser(a.admin, 'SELECT app.abc_run_due(now())')).rejects.toSatisfy(hasCode('FA002'));
    // Filial 2 nunca rodou: na primeira rodada, as três.
    await asWorker('SELECT app.abc_run_due($1)', [NOW]);
    const ran = async () => (await ownerPool.query('SELECT a_ran_at, b_ran_at, c_ran_at FROM abc_curve_setting WHERE branch_id = $1', [a.branch2.id])).rows[0];
    expect(Object.values(await ran()).map((v) => v.toISOString())).toEqual([NOW.toISOString(), NOW.toISOString(), NOW.toISOString()]);
    // 8 dias depois, só a A (7 dias) venceu.
    const week = new Date(NOW.getTime() + 8 * DAY);
    await asWorker('SELECT app.abc_run_due($1)', [week]);
    expect(Object.values(await ran()).map((v) => v.toISOString())).toEqual([week.toISOString(), NOW.toISOString(), NOW.toISOString()]);
  });

  it('parâmetros: quem cadastra clientes na filial troca; inválido ou fora de ordem recusa', async () => {
    const data = { periodDays: 90, aMinSales: 6, bMinSales: 3, aIntervalDays: 1, bIntervalDays: 2, cIntervalDays: 3 };
    await expect(asUser(b.admin, 'SELECT app.set_abc_settings($1, $2::jsonb)', [a.branch1.id, JSON.stringify(data)])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.oneBranchUser, 'SELECT app.set_abc_settings($1, $2::jsonb)', [a.branch2.id, JSON.stringify(data)])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.admin, 'SELECT app.set_abc_settings($1, $2::jsonb)', [a.branch1.id, JSON.stringify({ ...data, periodDays: '90' })])).rejects.toSatisfy(hasCode('FA005'));
    await expect(asUser(a.admin, 'SELECT app.set_abc_settings($1, $2::jsonb)', [a.branch1.id, JSON.stringify({ ...data, bMinSales: 6 })])).rejects.toSatisfy(hasCode('FA761'));
    await expect(asUser(a.admin, 'SELECT app.set_abc_settings($1, $2::jsonb)', [a.branch1.id, JSON.stringify({ ...data, periodDays: 3 })])).rejects.toSatisfy(hasCode('FA761'));
    await asUser(a.admin, 'SELECT app.set_abc_settings($1, $2::jsonb)', [a.branch1.id, JSON.stringify(data)]);
    const row = (await asUser(a.admin, 'SELECT * FROM app.abc_settings()')).find((r) => r.branch_id === a.branch1.id);
    expect(row).toMatchObject({ period_days: 90, a_min_sales: 6, b_min_sales: 3, a_interval_days: 1, b_interval_days: 2, c_interval_days: 3, can_manage: true });
    expect(await asUser(b.admin, 'SELECT * FROM app.abc_settings()')).not.toEqual(expect.arrayContaining([expect.objectContaining({ branch_id: a.branch1.id })]));
  });

  it('recalcular agora usa os parâmetros novos e as três curvas; a lista e o cliente mostram a curva', async () => {
    await expect(asUser(b.admin, 'SELECT app.abc_recalculate_now($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA002'));
    await asUser(a.admin, 'SELECT app.abc_recalculate_now($1)', [a.branch1.id]);
    // Com 90 dias, A >= 6, B >= 3: o médio (5) vai para B, o importado (4) para B.
    expect((await curveOf(middle)).curve).toBe('B');
    const row = (await asUser(a.admin, 'SELECT * FROM app.abc_settings()')).find((r) => r.branch_id === a.branch1.id);
    expect(row.a_count + row.b_count + row.c_count).toBeGreaterThanOrEqual(5);
    const listB = await asUser(a.admin, "SELECT * FROM app.abc_customers($1, 'B')", [a.branch1.id]);
    expect(listB.map((r) => r.customer_id)).toEqual(expect.arrayContaining([middle, imported]));
    expect(listB.every((r) => r.curve === 'B')).toBe(true);
    const name = (await ownerPool.query('SELECT name FROM customer WHERE id = $1', [middle])).rows[0].name;
    expect((await asUser(a.admin, 'SELECT * FROM app.abc_customers($1, NULL, $2)', [a.branch1.id, name])).map((r) => r.customer_id)).toEqual([middle]);
    expect(await asUser(b.admin, "SELECT * FROM app.abc_customers($1, 'B')", [a.branch1.id])).toEqual([]);
    expect((await asUser(a.admin, 'SELECT * FROM app.customer_abc_curves($1)', [middle])).map((r) => [r.branch_id, r.curve])).toEqual([[a.branch1.id, 'B']]);
  });

  it('o caixa recebe a curva do cliente na filial dele', async () => {
    await ownerPool.query('INSERT INTO pdv_customer_cache (economic_group_id, terminal_id, customer_id) VALUES ($1, $2, $3)', [a.group.id, a.terminal1.id, middle]);
    const data = (await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [a.terminal1.id, middle])).rows[0].data;
    expect(data.abc_curve).toBe('B');
    await ownerPool.query('INSERT INTO pdv_customer_cache (economic_group_id, terminal_id, customer_id) VALUES ($1, $2, $3)', [a.group.id, a.terminal2.id, middle]);
    // Na filial 2 ele não comprou: sem curva.
    const other = (await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [a.terminal2.id, middle])).rows[0].data;
    expect(other.abc_curve).toBeNull();
  });

  it('o histórico não muda', async () => {
    await expect(ownerPool.query("UPDATE customer_abc_event SET to_curve = 'A' WHERE customer_id = $1", [middle])).rejects.toSatisfy(hasCode('FA104'));
  });
});
