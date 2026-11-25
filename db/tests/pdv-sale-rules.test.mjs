import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;
let manager;
let operator;

const tag = () => randomBytes(4).toString('hex');
let clockMs = Date.now();
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
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits) => {
    const total = digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0);
    const rest = (total * 10) % 11;
    return rest === 10 ? 0 : rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}

async function committed(user, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
async function asTerminal(terminal, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows[0].r;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
async function pull(terminal, cursor = null) {
  let page = await asTerminal(terminal, 'SELECT app.pdv_pull($1, NULL, NULL, 1000) AS r', [cursor]);
  const items = [...page.items];
  while (page.next) {
    page = await asTerminal(terminal, 'SELECT app.pdv_pull($1, $2, $3, 1000) AS r', [cursor, page.until, page.next]);
    items.push(...page.items);
  }
  return { until: page.until, has: (type, id) => items.some((i) => i.type === type && i.id === id), get: (type, id) => items.find((i) => i.type === type && i.id === id)?.data };
}
let sequence = 0;
const push = (terminal, entries) => asTerminal(terminal, 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(entries.map(([kind, payload]) => {
  sequence += 1;
  return { id: uuidV7(), sequence, kind, payload };
}))]).then((r) => r.results);

const person = async (roleName) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  return user;
};
const newProduct = (fixture = a) => committed(fixture.admin, async (client) => {
  const barcode = gtin();
  const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Regra ${tag()}`, barcode })]);
  await client.query('SELECT app.set_product_price($1, NULL, 10, NULL)', [rows[0].id]);
  const code = (await client.query('SELECT code FROM product WHERE id = $1', [rows[0].id])).rows[0].code;
  return { id: rows[0].id, barcode, code };
});

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  manager = await person('Gerente');
  operator = await person('Operador de caixa');
});
afterAll(closePools);

describe('tempo sem internet para a venda sem estoque', () => {
  it('desce nos dados fiscais: o do terminal vale mais que o da filial', async () => {
    const start = await pull(a.terminal1);
    expect(start.get('fiscal', a.branch1.id).offline_zero_stock_minutes).toBe(30);
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_offline_minutes($1, 45)', [a.branch1.id]));
    let step = await pull(a.terminal1, start.until);
    expect(step.get('fiscal', a.branch1.id).offline_zero_stock_minutes).toBe(45);

    await committed(a.admin, (client) => client.query('SELECT app.set_terminal_offline_minutes($1, 10)', [a.terminal1.id]));
    step = await pull(a.terminal1, step.until);
    expect(step.get('fiscal', a.branch1.id).offline_zero_stock_minutes).toBe(10);
    await committed(a.admin, (client) => client.query('SELECT app.set_terminal_offline_minutes($1, NULL)', [a.terminal1.id]));
    expect((await pull(a.terminal1, step.until)).get('fiscal', a.branch1.id).offline_zero_stock_minutes).toBe(45);
  });

  it('valores fora da faixa, sem permissão ou de outro grupo são recusados', async () => {
    for (const minutes of [4, 1441, null]) {
      await expect(committed(a.admin, (client) => client.query('SELECT app.set_branch_offline_minutes($1, $2)', [a.branch1.id, minutes])))
        .rejects.toSatisfy(hasCode('FA976'));
    }
    await expect(committed(a.admin, (client) => client.query('SELECT app.set_terminal_offline_minutes($1, 3)', [a.terminal1.id])))
      .rejects.toSatisfy(hasCode('FA976'));
    await expect(committed(operator, (client) => client.query('SELECT app.set_branch_offline_minutes($1, 60)', [a.branch1.id])))
      .rejects.toSatisfy(hasCode('FA002'));
    await expect(committed(operator, (client) => client.query('SELECT app.set_terminal_offline_minutes($1, 60)', [a.terminal1.id])))
      .rejects.toSatisfy(hasCode('FA002'));
    await expect(committed(b.admin, (client) => client.query('SELECT app.set_branch_offline_minutes($1, 60)', [a.branch1.id])))
      .rejects.toSatisfy(hasCode('FA006'));
    await expect(committed(a.admin, (client) => client.query('SELECT app.set_terminal_offline_minutes($1, 60)', [randomUUID()])))
      .rejects.toSatisfy(hasCode('FA006'));
    await expect(ownerPool.query('UPDATE branch SET offline_zero_stock_minutes = 2 WHERE id = $1', [a.branch1.id])).rejects.toSatisfy(hasCode('FA976'));
  });
});

describe('o que desce para a venda', () => {
  it('produto traz o desconto máximo em vigor; regra nova faz descer de novo', async () => {
    const product = await newProduct();
    const start = await pull(a.terminal1);
    expect(start.get('product', product.id)).toMatchObject({ max_discount: null, max_discount_until: null });
    await committed(a.admin, (client) => client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
      typeCode: 'max_discount', value: 7.5, level: 'product', productLookup: String(product.code), validTo: '2099-12-31T00:00:00Z',
    })]));
    const step = await pull(a.terminal1, start.until);
    expect(step.get('product', product.id)).toMatchObject({ max_discount: 7.5 });
    expect(step.get('product', product.id).max_discount_until).toMatch(/^2099-12-3/);
    // Outra regra (comissão) não faz descer tudo de novo.
    const quiet = await pull(a.terminal1, step.until);
    await committed(a.admin, (client) => client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
      typeCode: 'commission', value: 2, level: 'product', productLookup: String(product.code),
    })]));
    expect((await pull(a.terminal1, quiet.until)).has('product', product.id)).toBe(false);
  });

  it('cliente guardado traz os convênios, e o vínculo novo desce', async () => {
    const customerId = await committed(a.admin, (client) => client.query('SELECT app.create_customer($1::jsonb) AS id', [
      JSON.stringify({ personType: 'individual', document: cpf(), name: `Cliente convênio ${tag()}` }),
    ]).then((r) => r.rows[0].id));
    const agreement = (await ownerPool.query('INSERT INTO agreement (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Convênio ${tag()}`])).rows[0];
    await asTerminal(a.terminal1, 'SELECT app.pdv_get_customer($1) AS r', [customerId]);
    const start = await pull(a.terminal1);
    expect(start.get('customer', customerId).agreements).toEqual([]);
    await ownerPool.query(
      'INSERT INTO customer_agreement (economic_group_id, customer_id, agreement_id, registration, credit_limit) VALUES ($1, $2, $3, $4, 300)',
      [a.group.id, customerId, agreement.id, 'M-77'],
    );
    const step = await pull(a.terminal1, start.until);
    expect(step.get('customer', customerId).agreements).toEqual([
      { agreement_id: agreement.id, name: agreement.name, registration: 'M-77', credit_limit: 300, used: 0 },
    ]);
  });
});

describe('estoque das outras filiais', () => {
  it('lista as filiais do grupo, a própria primeiro', async () => {
    const product = await newProduct();
    const adjust = (branch, quantity) => committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
      productLookup: product.barcode, branchId: branch.id, direction: 'in', quantity, reason: 'Teste',
    })]));
    await adjust(a.branch2, 4);
    await adjust(a.branchFree, 9);
    const list = await asTerminal(a.terminal1, 'SELECT app.pdv_network_stock($1) AS r', [product.id]);
    expect(list.map((row) => [row.branch_id, row.own, Number(row.quantity)])).toEqual([
      [a.branch1.id, true, 0], [a.branchFree.id, false, 9], [a.branch2.id, false, 4],
    ]);
    const foreign = await newProduct(b);
    await expect(asTerminal(a.terminal1, 'SELECT app.pdv_network_stock($1) AS r', [foreign.id])).rejects.toSatisfy(hasCode('FA006'));
    const blocked = (await ownerPool.query(
      `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', 'blocked', $3) RETURNING *`,
      [a.branch1.id, `Caixa ${tag()}`, `chave-${randomUUID()}`],
    )).rows[0];
    await expect(asTerminal(blocked, 'SELECT app.pdv_network_stock($1) AS r', [product.id])).rejects.toSatisfy(hasCode('FA304'));
  });
});

describe('venda sem estoque com o PDV sem internet', () => {
  it('fica o registro de quem autorizou e quanto tempo estava sem internet', async () => {
    const product = await newProduct();
    const session = uuidV7();
    await push(a.terminal1, [['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 }]]);
    let number = 500;
    const sale = (release) => {
      number += 1;
      return {
        id: uuidV7(), number, cash_session_id: session, operator_id: operator.id, customer_id: null, sold_at: new Date().toISOString(), fiscal_model: '65',
        items: [{ id: uuidV7(), line: 1, product_id: product.id, quantity: 1, unit_price: 10, discount: 0, total: 10, zero_stock_release: release }],
        payments: [{ id: uuidV7(), method: 'cash', amount: 10 }], subtotal: 10, discount_total: 0, total: 10,
      };
    };
    const byManager = sale({ supervisor_id: manager.id, minutes_offline: 95 });
    const byOperator = sale({ supervisor_id: operator.id, minutes_offline: 40 });
    const results = await push(a.terminal1, [
      ['sale', byManager], ['sale', byOperator],
      ['sale', sale({ supervisor_id: 'nada', minutes_offline: 10 })],
      ['sale', sale({ supervisor_id: manager.id, minutes_offline: -1 })],
      ['sale', sale({ supervisor_id: b.admin.id, minutes_offline: 10 })],
    ]);
    expect(results.map((r) => [r.status, r.code])).toEqual([
      ['applied', null], ['applied', null], ['conflict', 'FA962'], ['conflict', 'FA962'], ['conflict', 'FA004'],
    ]);
    const alerts = async (payload) => (await ownerPool.query(
      `SELECT kind, detail FROM sale_alert WHERE sale_id = $1 AND kind = 'offline_zero_stock'`, [payload.id],
    )).rows;
    expect(await alerts(byManager)).toEqual([{ kind: 'offline_zero_stock', detail: { supervisor_id: manager.id, supervisor_allowed: true, minutes_offline: 95 } }]);
    expect(await alerts(byOperator)).toEqual([{ kind: 'offline_zero_stock', detail: { supervisor_id: operator.id, supervisor_allowed: false, minutes_offline: 40 } }]);
  });

  it('desconto acima da regra liberado por quem pode passar dela não vira alerta', async () => {
    const product = await newProduct();
    await committed(a.admin, (client) => client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
      typeCode: 'max_discount', value: 5, level: 'product', productLookup: String(product.code),
    })]));
    const session = uuidV7();
    await push(a.terminal1, [['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 }]]);
    let number = 800;
    const sale = (supervisor) => {
      number += 1;
      return {
        id: uuidV7(), number, cash_session_id: session, operator_id: operator.id, customer_id: null, sold_at: new Date().toISOString(), fiscal_model: '65',
        items: [{ id: uuidV7(), line: 1, product_id: product.id, quantity: 1, unit_price: 10, discount: 0.8, total: 9.2, release: { supervisor_id: supervisor.id, reason: 'Cliente antigo' } }],
        payments: [{ id: uuidV7(), method: 'cash', amount: 9.2 }], subtotal: 10, discount_total: 0.8, total: 9.2,
      };
    };
    const byAdmin = sale(a.admin);
    const byManager = sale(manager);
    await push(a.terminal1, [['sale', byAdmin], ['sale', byManager]]);
    const kinds = async (payload) => (await ownerPool.query("SELECT kind FROM sale_alert WHERE sale_id = $1 AND kind LIKE 'discount%' ORDER BY kind", [payload.id])).rows.map((r) => r.kind);
    expect(await kinds(byAdmin)).toEqual([]);
    // O Gerente libera dentro do limite dele (10%), mas não pode passar da regra do produto (5%).
    expect(await kinds(byManager)).toEqual(['discount_above_rule']);
  });
});
