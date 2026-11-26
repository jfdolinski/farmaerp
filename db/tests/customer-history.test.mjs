import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Consulta de vendas do cliente: ticket médio (12 meses), compras dos últimos 30 dias e produtos
// recorrentes (2 ou mais compras em 180 dias).

let a;
let b;
let operator;
let customer;
let otherCustomer;
let viewer;
let clockMs = Date.now();
let sequence = 0;
let saleNumber = randomInt(1000, 900000);
const DAY = 24 * 60 * 60 * 1000;

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
const asTerminal = (terminal, sql, params) => run((c) => setTerminal(c, terminal.id), sql, params);

async function push(terminal, kind, payload) {
  sequence += 1;
  const rows = await asTerminal(terminal, 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
    { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind, payload },
  ])]);
  const result = rows[0].r.results[0];
  if (result.status !== 'applied') throw new Error(`${kind}: ${result.status} ${result.code}`);
}

const product = async (name) => {
  const id = (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: name, barcode: gtin() })]))[0].id;
  await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 10, NULL)', [id]);
  return id;
};

/** Venda no terminal, com a data dada (o turno abre um pouco antes). */
async function sell(terminal, buyer, daysAgo, lines) {
  const at = new Date(Date.now() - daysAgo * DAY);
  const session = uuidV7();
  await push(terminal, 'cash_session_open', {
    id: session, operator_id: operator.id, opened_at: new Date(at.getTime() - 60_000).toISOString(), opening_float: 0,
  });
  saleNumber += 1;
  const items = lines.map(([productId, quantity, price], index) => ({
    id: uuidV7(), line: index + 1, product_id: productId, barcode_id: null, quantity, unit_price: price, discount: 0,
    total: Math.round(quantity * price * 100) / 100, batch_id: null, release: null,
  }));
  const total = Math.round(items.reduce((sum, item) => sum + item.total, 0) * 100) / 100;
  await push(terminal, 'sale', {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: buyer,
    sold_at: at.toISOString(), fiscal_model: '65', items, payments: [{ id: uuidV7(), method: 'cash', amount: total, change: 0 }],
    subtotal: total, discount_total: 0, total,
  });
}

let dipirona;
let losartana;
let vitamina;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const roleOf = async (name) => (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, name])).rows[0].id;
  const { rows: [user] } = await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Operador ${randomInt(1e6)}`]);
  for (const branch of [a.branch1, a.branch2]) {
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, await roleOf('Operador de caixa'), branch.id]);
  }
  operator = user;
  // Quem vê clientes só na filial 1.
  const { rows: [seller] } = await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Gerente ${randomInt(1e6)}`]);
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [seller.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [seller.id, await roleOf('Gerente'), a.branch1.id]);
  viewer = seller;

  const newCustomer = async () => (await asUser(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
    personType: 'individual', document: cpf(), name: `Cliente Histórico ${randomInt(1e6)}`,
  })]))[0].id;
  customer = await newCustomer();
  otherCustomer = await newCustomer();
  dipirona = await product(`Dipirona ${randomInt(1e6)}`);
  losartana = await product(`Losartana ${randomInt(1e6)}`);
  vitamina = await product(`Vitamina ${randomInt(1e6)}`);

  await sell(a.terminal1, customer, 2, [[dipirona, 1, 10], [losartana, 2, 30]]); // 70
  await sell(a.terminal1, customer, 20, [[losartana, 1, 30]]); // 30
  await sell(a.terminal2, customer, 10, [[dipirona, 2, 10]]); // 20, na filial 2
  await sell(a.terminal1, customer, 45, [[losartana, 1, 30], [losartana, 1, 30]]); // 60: fora dos 30 dias, a mesma compra em duas linhas
  await sell(a.terminal1, customer, 100, [[vitamina, 1, 50]]); // 50
  await sell(a.terminal1, customer, 200, [[vitamina, 1, 50]]); // 50: fora dos 180 dias
  await sell(a.terminal1, customer, 400, [[dipirona, 1, 10]]); // fora dos 12 meses
  await sell(a.terminal1, otherCustomer, 3, [[dipirona, 5, 10]]);
});
afterAll(closePools);

describe('histórico de compras do cliente', () => {
  it('no caixa: a rede inteira; ticket médio de 12 meses, últimos 30 dias e recorrentes de 180 dias', async () => {
    const [{ r }] = await asTerminal(a.terminal1, 'SELECT app.pdv_customer_history($1) AS r', [customer]);
    expect(r.sales_12m).toBe(6);
    expect(Number(r.total_12m)).toBe(280);
    expect(Number(r.average_ticket)).toBe(46.67);
    expect(r.last_30_days.map((s) => [Number(s.total), s.items])).toEqual([[70, 2], [20, 1], [30, 1]]);
    expect(r.last_30_days[1].branch_name).toBe(a.branch2.name);
    // Losartana em 2 compras e dipirona em 2 (a de 400 dias fica fora).
    expect(r.recurring.map((p) => [p.product_id, p.purchases, Number(p.quantity)])).toEqual(expect.arrayContaining([
      [losartana, 3, 5], [dipirona, 2, 3],
    ]));
    // Vitamina: uma compra em 100 dias e outra em 200 (fora dos 180): não é recorrente.
    expect(r.recurring.map((p) => p.product_id)).not.toContain(vitamina);
    expect(r.recurring).toHaveLength(2);
  });

  it('cliente sem compras volta zerado; de outro grupo não existe', async () => {
    const fresh = (await asUser(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
      personType: 'individual', document: cpf(), name: 'Cliente Sem Compras',
    })]))[0].id;
    const [{ r }] = await asTerminal(a.terminal1, 'SELECT app.pdv_customer_history($1) AS r', [fresh]);
    expect(r).toEqual({ sales_12m: 0, total_12m: 0, average_ticket: null, last_purchase_at: null, last_30_days: [], recurring: [] });
    await expect(asTerminal(b.terminal1, 'SELECT app.pdv_customer_history($1)', [customer])).rejects.toSatisfy(hasCode('FA006'));
  });

  it('na retaguarda: só as filiais que o usuário vê; exige permissão de clientes', async () => {
    const [{ r: all }] = await asUser(a.admin, 'SELECT app.customer_purchase_history($1) AS r', [customer]);
    expect(all.sales_12m).toBe(6);
    const [{ r: own }] = await asUser(viewer, 'SELECT app.customer_purchase_history($1) AS r', [customer]);
    expect(own.sales_12m).toBe(5);
    expect(own.last_30_days.map((s) => Number(s.total))).toEqual([70, 30]);
    await expect(asUser(a.oneBranchUser, 'SELECT app.customer_purchase_history($1)', [customer])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(b.admin, 'SELECT app.customer_purchase_history($1)', [customer])).rejects.toSatisfy(hasCode('FA006'));
  });
});
