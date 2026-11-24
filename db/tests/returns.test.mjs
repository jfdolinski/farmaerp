import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Devolução: documento, destino do valor, estoque de volta e a sangria que paga em dinheiro.
let a;
let operator;
let manager;
let session;
let withBatch;
let plain;
let controlled;
let batchL1;

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
const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();
const DAY = 86400000;

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
const readAs = async (user, sql, params = []) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    return (await client.query(sql, params)).rows;
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
const asTerminal = async (sql, params = [], terminal = a.terminal1) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    return (await client.query(sql, params)).rows[0];
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
let sequence = 0;
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
const person = async (roleName) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  return user;
};
const product = async (controlledClass = null) => {
  const sourceKey = `dev-${tag()}`;
  const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey, name: `Produto ${sourceKey}`, ...(controlledClass ? { controlledClass } : {}),
  })])).rows[0].id;
  return committed(a.admin, async (client) => {
    const barcode = gtin();
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${sourceKey}`, barcode, catalogProductId: catalogId,
    })]);
    await client.query('SELECT app.set_product_price($1, NULL, 10, NULL)', [rows[0].id]);
    return { id: rows[0].id, barcode };
  });
};

let saleNumber = 700000 + randomInt(9000);
const sale = (lines, overrides = {}) => {
  saleNumber += 1;
  const items = lines.map((line, index) => ({
    id: uuidV7(), line: index + 1, product_id: line.product.id, quantity: line.quantity, unit_price: 10,
    discount: line.discount ?? 0, total: Math.round((line.quantity * 10 - (line.discount ?? 0)) * 100) / 100,
  }));
  const subtotal = items.reduce((sum, i) => sum + i.quantity * 10, 0);
  const discount = items.reduce((sum, i) => sum + i.discount, 0);
  const total = Math.round((subtotal - discount) * 100) / 100;
  return {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: null, sold_at: iso(),
    fiscal_model: '65', items, payments: [{ id: uuidV7(), method: 'cash', amount: total }],
    subtotal, discount_total: Math.round(discount * 100) / 100, total, ...overrides,
  };
};
let returnNumber = 0;
const refund = (saleRow, items, overrides = {}) => {
  returnNumber += 1;
  const list = items.map(([index, quantity, amount]) => ({ id: uuidV7(), sale_item_id: saleRow.items[index].id, quantity, amount }));
  return {
    id: uuidV7(), number: returnNumber, cash_session_id: session, sale_id: saleRow.id, operator_id: manager.id, authorized_by: null,
    reason: 'Cliente desistiu', destination: 'cash', returned_at: iso(),
    items: list, total: Math.round(list.reduce((sum, i) => sum + i.amount, 0) * 100) / 100, ...overrides,
  };
};
const returnRow = async (id) => (await ownerPool.query('SELECT * FROM sale_return WHERE id = $1', [id])).rows[0];
const batchBalance = async () => Number((await ownerPool.query('SELECT quantity FROM stock_balance WHERE batch_id = $1', [batchL1])).rows[0].quantity);
const alerts = async (saleId) => (await ownerPool.query(
  "SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'return_permission' ORDER BY created_at, id", [saleId],
)).rows.map((r) => r.detail);

beforeAll(async () => {
  ({ a } = await createFixtures());
  operator = await person('Operador de caixa');
  manager = await person('Gerente');
  session = uuidV7();
  await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: iso(), opening_float: 500 }]]);
  withBatch = await product();
  plain = await product();
  controlled = await product('B1');
  const tracked = await ownerPool.query(
    'UPDATE product_branch_status SET tracks_batches = true WHERE product_id = $1 AND branch_id = $2', [withBatch.id, a.branch1.id],
  );
  expect(tracked.rowCount).toBe(1);
  await committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: withBatch.barcode, branchId: a.branch1.id, direction: 'in', quantity: 10, reason: 'Teste', batchNumber: 'DV1', expiresOn: '2090-01-31',
  })]));
  batchL1 = (await ownerPool.query('SELECT id FROM product_batch WHERE product_id = $1', [withBatch.id])).rows[0].id;
});
afterAll(closePools);

describe('devolução', () => {
  it('parcial e depois o resto: valor proporcional, o último fecha no centavo, estoque de volta no lote', async () => {
    const sold = sale([{ product: withBatch, quantity: 3, discount: 0.01 }, { product: plain, quantity: 1 }]);
    expect(codes(await push([['sale', sold]]))).toEqual([['applied', null]]);
    const afterSale = await batchBalance();
    const first = refund(sold, [[0, 1, 10]]);
    const second = refund(sold, [[0, 1, 10], [1, 1, 10]], { destination: 'credit' });
    expect(codes(await push([['sale_return', first], ['sale_return', second]]))).toEqual([['applied', null], ['applied', null]]);
    expect(await batchBalance()).toBe(afterSale + 2);
    const terminalNumber = (await ownerPool.query('SELECT number FROM terminal WHERE id = $1', [a.terminal1.id])).rows[0].number;
    expect(await returnRow(first.id)).toMatchObject({
      code: `D${terminalNumber}-${String(first.number).padStart(6, '0')}`, destination: 'cash', sale_id: sold.id,
      operator_id: manager.id, paid_movement_id: null, reason: 'Cliente desistiu',
    });
    // Último do item: o que falta do total (29,99 - 20,00 = 9,99); a mais, não.
    expect(codes(await push([['sale_return', refund(sold, [[0, 1, 10]])]]))).toEqual([['conflict', 'FA894']]);
    const last = refund(sold, [[0, 1, 9.99]]);
    expect(codes(await push([['sale_return', last]]))).toEqual([['applied', null]]);
    expect(await batchBalance()).toBe(afterSale + 3);
    expect(codes(await push([['sale_return', refund(sold, [[0, 1, 0]])]]))).toEqual([['conflict', 'FA892']]);
    expect(codes(await push([['sale_return', refund(sold, [[1, 1, 0]])]]))).toEqual([['conflict', 'FA892']]);
    expect(await alerts(sold.id)).toEqual([]);
    const movements = (await ownerPool.query(
      "SELECT m.batch_id, m.quantity::float FROM stock_movement m JOIN sale_return_item ri ON ri.id = m.sale_return_item_id WHERE ri.sale_return_id = $1",
      [first.id],
    )).rows;
    expect(movements).toEqual([{ batch_id: batchL1, quantity: 1 }]);
  });

  it('permissão: sem ela, vale com alerta; liberada, sem alerta; fora do prazo, só com a liberação de outra pessoa', async () => {
    const sold = sale([{ product: plain, quantity: 5 }]);
    const old = sale([{ product: plain, quantity: 5 }], { sold_at: iso(-10 * DAY) });
    await push([['sale', sold], ['sale', old]]);
    const byOperator = refund(sold, [[0, 1, 10]], { operator_id: operator.id });
    const released = refund(sold, [[0, 1, 10]], { operator_id: operator.id, authorized_by: manager.id });
    const lateAlone = refund(old, [[0, 1, 10]]);
    const lateReleased = refund(old, [[0, 1, 10]], { operator_id: operator.id, authorized_by: manager.id });
    expect(codes(await push([byOperator, released, lateAlone, lateReleased].map((r) => ['sale_return', r]))).map(([s]) => s))
      .toEqual(['applied', 'applied', 'applied', 'applied']);
    expect(await alerts(sold.id)).toEqual([
      { return_code: (await returnRow(byOperator.id)).code, late: false, operator_id: operator.id, authorized_by: null },
    ]);
    expect(await alerts(old.id)).toEqual([
      { return_code: (await returnRow(lateAlone.id)).code, late: true, operator_id: manager.id, authorized_by: null },
    ]);

    // Liberação de quem não tem a permissão não vale.
    const colleague = await person('Operador de caixa');
    const weak = refund(sold, [[0, 1, 10]], { operator_id: operator.id, authorized_by: colleague.id });
    await push([['sale_return', weak]]);
    expect((await alerts(sold.id)).map((a) => a.return_code)).toContain((await returnRow(weak.id)).code);

    // No último dia do prazo (7 dias), o gerente ainda faz sozinho.
    const edge = sale([{ product: plain, quantity: 1 }], { sold_at: iso(-7 * DAY) });
    await push([['sale', edge], ['sale_return', refund(edge, [[0, 1, 10]])]]);
    expect(await alerts(edge.id)).toEqual([]);
  });

  it('não volta: controlado, venda de outra loja, convênio sem convênio, fora do formato', async () => {
    const sold = sale([{ product: plain, quantity: 2 }, { product: controlled, quantity: 1 }]);
    await push([['sale', sold]]);
    expect(codes(await push([['sale_return', refund(sold, [[1, 1, 10]])]]))).toEqual([['conflict', 'FA893']]);
    const otherSession = uuidV7();
    await push([['cash_session_open', { id: otherSession, operator_id: operator.id, opened_at: iso(), opening_float: 0 }]], a.terminal2);
    expect(codes(await push([['sale_return', refund(sold, [[0, 1, 10]], { cash_session_id: otherSession })]], a.terminal2)))
      .toEqual([['conflict', 'FA891']]);
    expect(codes(await push([['sale_return', refund(sold, [[0, 1, 10]], { destination: 'agreement' })]]))).toEqual([['conflict', 'FA897']]);
    const other = sale([{ product: plain, quantity: 1 }]);
    await push([['sale', other]]);
    const bad = [
      refund(sold, [[0, 1, 10]], { reason: '  ' }),
      refund(sold, [[0, 1, 10]], { destination: 'voucher' }),
      refund(sold, [[0, 1, 9]]),
      refund(sold, [[0, 1, 10]], { total: 20 }),
      refund(sold, [[0, 1, 10]], { authorized_by: manager.id }),
      refund(sold, [[0, 0, 0]]),
      refund(sold, [[0, 1, 10]], { returned_at: 'ontem' }),
      refund(sold, [[0, 1, 10]], { cash_session_id: otherSession }),
      { ...refund(sold, [[0, 1, 10]]), items: [{ id: uuidV7(), sale_item_id: other.items[0].id, quantity: 1, amount: 10 }] },
      { ...refund(sold, [[0, 1, 10]]), items: [] },
    ];
    expect(codes(await push(bad.map((r) => ['sale_return', r])))).toEqual(bad.map(() => ['conflict', 'FA894']));
    // Valores trocados entre os itens: o total bate, mas cada item precisa fechar.
    const twoItems = sale([{ product: plain, quantity: 2 }, { product: plain, quantity: 2 }]);
    await push([['sale', twoItems]]);
    expect(codes(await push([['sale_return', refund(twoItems, [[0, 1, 11], [1, 1, 9]])]]))).toEqual([['conflict', 'FA894']]);
    const twice = refund(sold, [[0, 1, 10]]);
    twice.items.push({ ...twice.items[0], id: uuidV7() });
    twice.total = 20;
    expect(codes(await push([['sale_return', twice]]))).toEqual([['conflict', 'FA894']]);
    const once = refund(sold, [[0, 1, 10]]);
    await push([['sale_return', once]]);
    expect(codes(await push([['sale_return', { ...once, id: uuidV7() }]]))).toEqual([['conflict', 'FA894']]);
    await expect(ownerPool.query('UPDATE sale_return SET total = 1 WHERE id = $1', [once.id])).rejects.toSatisfy(hasCode('FA104'));
  });
});

describe('sangria de devolução', () => {
  const withdrawal = (overrides = {}) => ({
    id: uuidV7(), cash_session_id: session, kind: 'withdrawal', amount: 10, reason: 'Devolução', operator_id: manager.id,
    released_by: null, moved_at: iso(), ...overrides,
  });
  const cashAlerts = async (movementId) => (await ownerPool.query(
    "SELECT detail ->> 'problem' AS problem FROM cash_alert WHERE cash_movement_id = $1 AND kind = 'return_payout'", [movementId],
  )).rows.map((r) => r.problem);

  it('a sangria com o documento paga a devolução em dinheiro; o que não bate vira alerta', async () => {
    const sold = sale([{ product: plain, quantity: 4 }]);
    await push([['sale', sold]]);
    const cash = refund(sold, [[0, 1, 10]]);
    const credit = refund(sold, [[0, 1, 10]], { destination: 'credit' });
    const cashTwo = refund(sold, [[0, 2, 20]]);
    await push([['sale_return', cash], ['sale_return', credit], ['sale_return', cashTwo]]);

    // O PDV acha o documento pelo código; o de crédito não serve.
    const lookup = (code, terminal) => asTerminal('SELECT app.pdv_return($1) AS r', [code], terminal).then((r) => r.r);
    const cashCode = (await returnRow(cash.id)).code;
    expect(await lookup(cashCode.toLowerCase())).toMatchObject({ id: cash.id, total: 10, sale_code: expect.any(String) });
    await expect(lookup((await returnRow(credit.id)).code)).rejects.toSatisfy(hasCode('FA896'));
    await expect(lookup('D9-999999')).rejects.toSatisfy(hasCode('FA896'));
    await expect(lookup(cashCode, a.terminal2)).rejects.toSatisfy(hasCode('FA896'));

    const pays = withdrawal({ return_id: cash.id });
    const again = withdrawal({ return_id: cash.id });
    const onCredit = withdrawal({ return_id: credit.id });
    const wrongAmount = withdrawal({ return_id: cashTwo.id, amount: 15 });
    expect(codes(await push([pays, again, onCredit, wrongAmount].map((m) => ['cash_movement', m]))).map(([s]) => s))
      .toEqual(['applied', 'applied', 'applied', 'applied']);
    expect((await returnRow(cash.id)).paid_movement_id).toBe(pays.id);
    expect(await cashAlerts(pays.id)).toEqual([]);
    expect(await cashAlerts(again.id)).toEqual(['already_paid']);
    expect(await cashAlerts(onCredit.id)).toEqual(['not_cash']);
    expect(await cashAlerts(wrongAmount.id)).toEqual(['amount']);
    expect((await returnRow(cashTwo.id)).paid_movement_id).toBeNull();
    await expect(lookup(cashCode)).rejects.toSatisfy(hasCode('FA896'));
    expect(codes(await push([['cash_movement', withdrawal({ kind: 'supply', return_id: cashTwo.id })]]))).toEqual([['conflict', 'FA995']]);
    expect(codes(await push([['cash_movement', withdrawal({ return_id: uuidV7() })]]))).toEqual([['conflict', 'FA004']]);
  });
});

describe('PDV e retaguarda', () => {
  it('venda para devolver pelo código, com o que ainda pode voltar', async () => {
    const sold = sale([{ product: plain, quantity: 3 }, { product: controlled, quantity: 1 }]);
    await push([['sale', sold], ['sale_return', refund(sold, [[0, 1, 10]])]]);
    const code = (await ownerPool.query('SELECT code FROM sale WHERE id = $1', [sold.id])).rows[0].code;
    const found = (await asTerminal('SELECT app.pdv_sale_for_return($1) AS s', [code])).s;
    expect(found).toMatchObject({ id: sold.id, late: false, return_days: 7, has_agreement: false });
    expect(found.items.map((i) => [i.line, i.quantity, i.returned_quantity, i.controlled])).toEqual([[1, 3, 1, false], [2, 1, 0, true]]);
    await expect(asTerminal('SELECT app.pdv_sale_for_return($1) AS s', [code], a.terminal2)).rejects.toSatisfy(hasCode('FA891'));
    await expect(asTerminal('SELECT app.pdv_sale_for_return($1) AS s', ['9-999999'])).rejects.toSatisfy(hasCode('FA891'));
  });

  it('lista, detalhe e a venda com as devoluções, para quem vê as vendas', async () => {
    const sold = sale([{ product: plain, quantity: 2 }]);
    const done = refund(sold, [[0, 1, 10]], { operator_id: operator.id, authorized_by: manager.id });
    await push([['sale', sold], ['sale_return', done]]);
    const listed = (await readAs(a.admin, 'SELECT * FROM app.list_returns($1, NULL, NULL)', [a.branch1.id])).find((r) => r.id === done.id);
    expect(listed).toMatchObject({ destination: 'cash', paid: false, item_count: 1, alert: false, authorized_by_name: manager.name });
    const detail = (await readAs(a.admin, 'SELECT app.return_detail($1) AS d', [done.id]))[0].d;
    expect(detail).toMatchObject({ code: listed.code, total: 10, items: [{ line: 1, quantity: 1, amount: 10 }] });
    const saleDetail = (await readAs(a.admin, 'SELECT app.sale_detail($1) AS d', [sold.id]))[0].d;
    expect(saleDetail.returns).toEqual([expect.objectContaining({ code: listed.code, destination: 'cash', paid: false })]);
    expect(await readAs(operator, 'SELECT * FROM app.list_returns()')).toEqual([]);
    expect((await readAs(operator, 'SELECT app.return_detail($1) AS d', [done.id]))[0].d).toBeNull();
  });

  it('prazo da filial: quem mexe na estrutura; desce nos dados fiscais', async () => {
    await expect(committed(operator, (client) => client.query('SELECT app.set_branch_return_days($1, 10)', [a.branch1.id])))
      .rejects.toSatisfy(hasCode('FA002'));
    for (const days of [-1, 366, null]) {
      await expect(committed(a.admin, (client) => client.query('SELECT app.set_branch_return_days($1, $2)', [a.branch1.id, days])))
        .rejects.toSatisfy(hasCode('FA899'));
    }
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_return_days($1, 15)', [a.branch1.id]));
    const fiscal = (await ownerPool.query('SELECT app.pdv_fiscal_data($1, $2) AS d', [a.branch1.id, a.terminal1.id])).rows[0].d;
    expect(fiscal).toMatchObject({ return_days: 15 });
    expect(Number(fiscal.last_return_number)).toBeGreaterThan(0);
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_return_days($1, 7)', [a.branch1.id]));
  });
});
