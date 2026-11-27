import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Parte C do lote de 26/11: liberação do estoque negativo no orçamento e na venda (com ou sem
// internet) e vários orçamentos juntados numa venda no caixa, cada item com o vendedor dele.

let a;
let b;
let operator;
let clerk;
let manager;
let product;
let clockMs = Date.now();
let sequence = 0;
let number = 0;
let saleNumber = 700000 + randomInt(9000);
let session;

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
const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();

async function push(entries, terminal = a.terminal1) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(entries.map(([kind, payload]) => {
      sequence += 1;
      return { id: uuidV7(), sequence, kind, payload };
    }))]);
    await client.query('COMMIT');
    return rows[0].r.results;
  } finally {
    client.release();
  }
}
const codes = (results) => results.map((r) => [r.status, r.code]);
async function asTerminal(sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, a.terminal1.id);
    return (await client.query(sql, params)).rows[0];
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}
const person = async (roleName) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  return user;
};
const item = (overrides = {}) => ({ id: uuidV7(), line: 1, product_id: product.id, quantity: 1, unit_price: 10, discount: 0, total: 10, ...overrides });
const quote = (seller, items) => {
  number += 1;
  const subtotal = items.reduce((sum, i) => sum + i.quantity * i.unit_price, 0);
  return {
    id: uuidV7(), number, seller_id: seller.id, customer_id: null, card_number: null, quoted_at: iso(),
    items, subtotal, discount_total: 0, total: subtotal,
  };
};
const sale = (items, overrides = {}) => {
  saleNumber += 1;
  const total = items.reduce((sum, i) => sum + i.total, 0);
  return {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: null, seller_id: null,
    quote_id: null, sold_at: iso(), fiscal_model: '65', items,
    payments: [{ id: uuidV7(), method: 'cash', amount: total }], subtotal: total, discount_total: 0, total, ...overrides,
  };
};
const quoteRow = async (id) => (await ownerPool.query('SELECT status, converted_sale_id FROM quote WHERE id = $1', [id])).rows[0];
const lookup = async (key) => (await asTerminal('SELECT app.pdv_quote($1) AS q', [key])).q;
const alerts = async (saleId) => (await ownerPool.query(
  "SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'offline_zero_stock'", [saleId],
)).rows.map((r) => r.detail);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  clerk = await person('Balconista');
  manager = await person('Gerente');
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, a.admin.id);
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto ${tag()}`, barcode: gtin() })]);
    await client.query('SELECT app.set_product_price($1, NULL, 10, NULL)', [rows[0].id]);
    await client.query('COMMIT');
    product = { id: rows[0].id };
  } finally {
    client.release();
  }
  session = uuidV7();
  await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: iso(), opening_float: 0 }]]);
});
afterAll(closePools);

describe('estoque negativo', () => {
  it('a permissão passa a se chamar "Vender com estoque negativo"', async () => {
    expect((await ownerPool.query("SELECT name FROM permission WHERE code = 'sales.zero_stock_release'")).rows[0].name).toBe('Vender com estoque negativo');
  });

  it('o orçamento guarda a liberação do item (quem e o saldo) e o caixa recebe junto ao buscar', async () => {
    const q = quote(clerk, [
      item({ zero_stock_release: { supervisor_id: manager.id, stock: -2 } }),
      item({ line: 2 }),
    ]);
    expect(codes(await push([['quote', q]]))).toEqual([['applied', null]]);
    const stored = (await ownerPool.query('SELECT line, stock_released_by, stock_release_balance FROM quote_item WHERE quote_id = $1 ORDER BY line', [q.id])).rows;
    expect(stored.map((r) => [r.line, r.stock_released_by, r.stock_release_balance === null ? null : Number(r.stock_release_balance)])).toEqual([
      [1, manager.id, -2], [2, null, null],
    ]);
    const code = (await ownerPool.query('SELECT code FROM quote WHERE id = $1', [q.id])).rows[0].code;
    const found = await lookup(code);
    expect(found.items.map((i) => i.zero_stock_release)).toEqual([{ supervisor_id: manager.id, stock: -2 }, null]);
  });

  it('liberação do orçamento fora do formato ou de outro grupo: conflito', async () => {
    for (const bad of [
      { supervisor_id: 'x' },
      { stock: 1 },
      { supervisor_id: manager.id, stock: 'muito' },
      'sim',
    ]) {
      expect(codes(await push([['quote', quote(clerk, [item({ zero_stock_release: bad })])]]))).toEqual([['conflict', 'FA883']]);
    }
    expect(codes(await push([['quote', quote(clerk, [item({ zero_stock_release: { supervisor_id: b.admin.id } })])]]))).toEqual([['conflict', 'FA004']]);
  });

  it('venda: liberação com internet (sem minutos) guarda o saldo; quem liberou sem a permissão fica marcado', async () => {
    const online = sale([item({ zero_stock_release: { supervisor_id: manager.id, stock: -1 } })]);
    const withoutRight = sale([item({ zero_stock_release: { supervisor_id: clerk.id, stock: 0 } })]);
    const offline = sale([item({ zero_stock_release: { supervisor_id: manager.id, minutes_offline: 45 } })]);
    expect(codes(await push([['sale', online], ['sale', withoutRight], ['sale', offline]])).map(([s]) => s)).toEqual(['applied', 'applied', 'applied']);
    expect(await alerts(online.id)).toEqual([{ supervisor_id: manager.id, supervisor_allowed: true, minutes_offline: null, stock: -1 }]);
    expect(await alerts(withoutRight.id)).toEqual([{ supervisor_id: clerk.id, supervisor_allowed: false, minutes_offline: null, stock: 0 }]);
    expect(await alerts(offline.id)).toEqual([{ supervisor_id: manager.id, supervisor_allowed: true, minutes_offline: 45, stock: null }]);
    expect(codes(await push([['sale', sale([item({ zero_stock_release: { supervisor_id: manager.id, stock: 'x' } })])]]))).toEqual([['conflict', 'FA962']]);
  });
});

describe('orçamentos juntados no caixa', () => {
  it('cada item fica com o vendedor e o orçamento dele; os dois orçamentos viram a venda', async () => {
    const first = quote(clerk, [item()]);
    const second = quote(manager, [item()]);
    await push([['quote', first], ['quote', second]]);
    const merged = sale([
      item({ seller_id: clerk.id, quote_id: first.id }),
      item({ line: 2, seller_id: manager.id, quote_id: second.id }),
      item({ line: 3 }),
    ], { seller_id: clerk.id, quote_id: first.id });
    expect(codes(await push([['sale', merged]]))).toEqual([['applied', null]]);
    const rows = (await ownerPool.query('SELECT line, seller_id, quote_id FROM sale_item WHERE sale_id = $1 ORDER BY line', [merged.id])).rows;
    // O item sem vendedor próprio fica com o da venda.
    expect(rows).toEqual([
      { line: 1, seller_id: clerk.id, quote_id: first.id },
      { line: 2, seller_id: manager.id, quote_id: second.id },
      { line: 3, seller_id: clerk.id, quote_id: null },
    ]);
    expect(await quoteRow(first.id)).toEqual({ status: 'converted', converted_sale_id: merged.id });
    expect(await quoteRow(second.id)).toEqual({ status: 'converted', converted_sale_id: merged.id });
    expect((await ownerPool.query('SELECT quote_id FROM sale WHERE id = $1', [merged.id])).rows[0].quote_id).toBe(first.id);
    // A retaguarda mostra o vendedor e o orçamento de cada item.
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      const detail = (await client.query('SELECT app.sale_detail($1) AS d', [merged.id])).rows[0].d;
      const codeOf = async (id) => (await ownerPool.query('SELECT code FROM quote WHERE id = $1', [id])).rows[0].code;
      expect(detail.items.map((i) => [i.line, i.seller_name, i.quote_code])).toEqual([
        [1, clerk.name, await codeOf(first.id)], [2, manager.name, await codeOf(second.id)], [3, clerk.name, null],
      ]);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('o vendedor e o orçamento do item, e a liberação do orçamento, não mudam depois de gravados', async () => {
    const q = quote(clerk, [item({ zero_stock_release: { supervisor_id: manager.id, stock: -1 } })]);
    await push([['quote', q]]);
    const s = sale([item({ seller_id: clerk.id, quote_id: q.id })]);
    await push([['sale', s]]);
    await expect(ownerPool.query('UPDATE sale_item SET seller_id = NULL WHERE sale_id = $1', [s.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE sale_item SET quote_id = NULL WHERE sale_id = $1', [s.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE quote_item SET stock_released_by = NULL WHERE quote_id = $1', [q.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE quote_item SET stock_release_balance = 5 WHERE quote_id = $1', [q.id])).rejects.toSatisfy(hasCode('FA104'));
  });

  it('venda juntada cancelada: os dois orçamentos voltam a ficar abertos', async () => {
    const first = quote(clerk, [item()]);
    const second = quote(manager, [item()]);
    await push([['quote', first], ['quote', second]]);
    const merged = sale([item({ seller_id: clerk.id, quote_id: first.id }), item({ line: 2, seller_id: manager.id, quote_id: second.id })],
      { seller_id: clerk.id, quote_id: first.id });
    await push([['sale', merged]]);
    await ownerPool.query("SELECT app.cancel_sale_effects(s, $2, 'Cliente desistiu da compra') FROM sale s WHERE s.id = $1", [merged.id, a.admin.id]);
    expect(await quoteRow(first.id)).toEqual({ status: 'open', converted_sale_id: null });
    expect(await quoteRow(second.id)).toEqual({ status: 'open', converted_sale_id: null });
  });

  it('orçamento do item que já virou outra venda: a venda vale e fica o alerta', async () => {
    const used = quote(clerk, [item()]);
    await push([['quote', used]]);
    await push([['sale', sale([item({ quote_id: used.id })])]]);
    const again = sale([item({ quote_id: used.id, seller_id: clerk.id })]);
    expect(codes(await push([['sale', again]]))).toEqual([['applied', null]]);
    expect((await ownerPool.query("SELECT detail ->> 'status' AS s FROM sale_alert WHERE sale_id = $1 AND kind = 'quote_status'", [again.id])).rows)
      .toEqual([{ s: 'converted' }]);
  });

  it('vendedor ou orçamento do item fora do formato ou de outro grupo: conflito', async () => {
    expect(codes(await push([['sale', sale([item({ seller_id: 'x' })])]]))).toEqual([['conflict', 'FA962']]);
    expect(codes(await push([['sale', sale([item({ quote_id: 'x' })])]]))).toEqual([['conflict', 'FA962']]);
    expect(codes(await push([['sale', sale([item({ seller_id: b.admin.id })])]]))).toEqual([['conflict', 'FA004']]);
    expect(codes(await push([['sale', sale([item({ quote_id: uuidV7() })])]]))).toEqual([['conflict', 'FA004']]);
  });
});
