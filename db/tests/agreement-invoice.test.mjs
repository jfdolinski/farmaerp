import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Fatura do convênio: fechamento por período, devoluções como abatimento, pagamento e cancelamento,
// e o limite do cliente.

let a;
let b;
let operator;
let manager;
let session;
let productId;
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
// CPF de teste, gerado ao acaso (nunca de pessoa real).
function cpf() {
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits) => {
    const rest = (digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0) * 10) % 11;
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
const call = (user, sql, params = []) => committed(user, (client) => client.query(sql, params).then((r) => r.rows));
let sequence = 0;
async function push(entries) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, a.terminal1.id);
    const items = entries.map(([kind, payload]) => {
      sequence += 1;
      return { id: uuidV7(), sequence, kind, payload };
    });
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(items)]);
    await client.query('COMMIT');
    return rows[0].r.results;
  } finally {
    client.release();
  }
}
const day = (offset) => new Date(Date.now() + offset * 86400000).toISOString().slice(0, 10);
const today = async () => (await ownerPool.query('SELECT app.local_day(now())::text AS d')).rows[0].d;
const shift = (text, days) => new Date(Date.parse(`${text}T12:00:00Z`) + days * 86400000).toISOString().slice(0, 10);

let saleNumber = 0;
function sale(customerId, agreementId, amount, soldAt = new Date()) {
  saleNumber += 1;
  return {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId,
    sold_at: soldAt.toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: productId, barcode_id: null, quantity: 1, unit_price: amount, discount: 0, total: amount, batch_id: null }],
    payments: [{ id: uuidV7(), method: 'agreement', amount, agreement_id: agreementId, agreement_registration: 'M-1' }],
    subtotal: amount, discount_total: 0, total: amount,
  };
}

async function newAgreement(limit = 500) {
  const agreementId = (await call(a.admin, 'SELECT app.create_agreement($1, NULL) AS id', [`Convênio ${tag()}`]))[0].id;
  const customerId = (await call(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
    personType: 'individual', document: cpf(), name: `Funcionário ${tag()}`,
  })]))[0].id;
  await call(a.admin, 'SELECT app.link_customer_agreement($1, $2, $3, $4)', [customerId, agreementId, 'M-1', limit]);
  return { agreementId, customerId };
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const roleOf = async (name) => (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, name])).rows[0].id;
  const person = async (name, role) => {
    const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, name])).rows[0];
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, await roleOf(role), a.branch1.id]);
    return user;
  };
  operator = await person(`Operador convênio ${tag()}`, 'Operador de caixa');
  manager = await person(`Gerente convênio ${tag()}`, 'Gerente');
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const check = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  const barcode = `${base}${(10 - (check % 10)) % 10}`;
  productId = (await call(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto convênio ${tag()}`, barcode })]))[0].id;
  await call(a.admin, 'SELECT app.set_product_price($1, NULL, $2, NULL)', [productId, 10]);
  await call(a.admin, 'SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: barcode, branchId: a.branch1.id, direction: 'in', quantity: 1000, reason: 'Teste do convênio',
  })]);
  await call(a.admin, 'SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
    typeCode: 'cashback', value: 5, level: 'product', productLookup: barcode,
  })]);
  session = uuidV7();
  const opened = await push([['cash_session_open', {
    id: session, operator_id: operator.id, opened_at: new Date(Date.now() - 5 * 86400000).toISOString(), opening_float: 0,
  }]]);
  expect(opened[0].status).toBe('applied');
});
afterAll(closePools);

describe('fatura do convênio', () => {
  it('fecha o período com as vendas; o que já foi faturado não entra de novo; paga muda o limite usado', async () => {
    const { agreementId, customerId } = await newAgreement();
    const now = await today();
    const older = sale(customerId, agreementId, 40, new Date(Date.now() - 2 * 86400000));
    const newer = sale(customerId, agreementId, 25);
    expect((await push([['sale', older], ['sale', newer]])).map((r) => r.status)).toEqual(['applied', 'applied']);
    expect(Number((await ownerPool.query('SELECT app.agreement_used($1, $2) AS u', [customerId, agreementId])).rows[0].u)).toBe(65);

    const preview = (await call(a.admin, 'SELECT app.agreement_invoice_preview($1, $2) AS p', [agreementId, shift(now, -1)]))[0].p;
    expect(preview.items.map((i) => [i.kind, i.amount, i.registration])).toEqual([['sale', 40, 'M-1']]);
    await expect(call(a.admin, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, shift(now, 1)])).rejects.toSatisfy(hasCode('FA857'));
    await expect(call(manager, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, now])).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(b.admin, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, now])).rejects.toSatisfy(hasCode('FA006'));
    const first = (await call(a.admin, 'SELECT app.close_agreement_invoice($1, $2) AS id', [agreementId, shift(now, -1)]))[0].id;
    await expect(call(a.admin, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, shift(now, -1)])).rejects.toSatisfy(hasCode('FA857'));
    const second = (await call(a.admin, 'SELECT app.close_agreement_invoice($1, $2) AS id', [agreementId, now]))[0].id;
    const detail = (await call(a.admin, 'SELECT app.agreement_invoice_detail($1) AS d', [second]))[0].d;
    expect(detail).toMatchObject({ status: 'closed', total: 25, period_start: now, period_end: now });
    expect(detail.items.map((i) => [i.kind, i.amount, i.sale_code])).toEqual([['sale', 25, expect.any(String)]]);
    expect(detail.customers).toEqual([{ customer_name: expect.any(String), registration: 'M-1', total: 25 }]);
    const list = await call(a.admin, 'SELECT * FROM app.list_agreement_invoices($1)', [agreementId]);
    expect(list.map((i) => [i.id, i.status, Number(i.total), i.item_count])).toEqual([[second, 'closed', 25, 1], [first, 'closed', 40, 1]]);

    // Fatura paga: o limite usado deixa de contar as compras dela.
    await expect(call(a.admin, 'SELECT app.pay_agreement_invoice($1, $2, $3)', [first, shift(now, 1), ''])).rejects.toSatisfy(hasCode('FA857'));
    await call(a.admin, 'SELECT app.pay_agreement_invoice($1, $2, $3)', [first, now, 'TED da empresa']);
    await expect(call(a.admin, 'SELECT app.pay_agreement_invoice($1, $2, $3)', [first, now, ''])).rejects.toSatisfy(hasCode('FA858'));
    expect(Number((await ownerPool.query('SELECT app.agreement_used($1, $2) AS u', [customerId, agreementId])).rows[0].u)).toBe(25);
    await expect(ownerPool.query('UPDATE agreement_invoice SET total = 1 WHERE id = $1', [first])).rejects.toSatisfy(hasCode('FA104'));
  });

  it('devolução depois do fechamento entra na fatura seguinte como abatimento, pelo valor do destino', async () => {
    const { agreementId, customerId } = await newAgreement();
    const now = await today();
    const sold = sale(customerId, agreementId, 30, new Date(Date.now() - 2 * 86400000));
    await push([['sale', sold]]);
    await call(a.admin, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, shift(now, -1)]);
    await push([['sale_return', {
      id: uuidV7(), number: 500, cash_session_id: session, sale_id: sold.id, operator_id: manager.id, authorized_by: null,
      reason: 'Troca', destination: 'agreement', returned_at: new Date().toISOString(),
      items: [{ id: uuidV7(), sale_item_id: sold.items[0].id, quantity: 1, amount: 30 }], total: 30,
    }]]);
    const preview = (await call(a.admin, 'SELECT app.agreement_invoice_preview($1, $2) AS p', [agreementId, now]))[0].p;
    expect(preview.items.map((i) => [i.kind, i.amount])).toEqual([['return', -30]]);
    expect(preview.total).toBe(-30);
    expect(Number((await ownerPool.query('SELECT app.agreement_used($1, $2) AS u', [customerId, agreementId])).rows[0].u)).toBe(0);
  });

  it('venda com cashback e convênio: a devolução abate só a parte que volta para o convênio', async () => {
    const { agreementId, customerId } = await newAgreement();
    await call(a.admin, "SELECT app.record_customer_consent($1, 'cashback', true, 'store')", [customerId]);
    // Compra em dinheiro que gera R$ 20 de cashback.
    const earned = sale(customerId, agreementId, 400);
    earned.payments = [{ id: uuidV7(), method: 'cash', amount: 400 }];
    await push([['sale', earned]]);
    const client = await appPool.connect();
    let held;
    try {
      await client.query('BEGIN');
      await setTerminal(client, a.terminal1.id);
      held = (await client.query('SELECT app.pdv_cashback_reserve($1, $2, $3) AS r', [customerId, 10, 50])).rows[0].r;
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    const sold = sale(customerId, agreementId, 50);
    sold.payments = [
      { id: uuidV7(), method: 'cashback', amount: 10, reservation_id: held.reservation_id },
      { id: uuidV7(), method: 'agreement', amount: 40, agreement_id: agreementId, agreement_registration: 'M-1' },
    ];
    expect((await push([['sale', sold]]))[0].status).toBe('applied');
    expect((await push([['sale_return', {
      id: uuidV7(), number: 600, cash_session_id: session, sale_id: sold.id, operator_id: manager.id, authorized_by: null,
      reason: 'Troca', destination: 'agreement', returned_at: new Date().toISOString(),
      items: [{ id: uuidV7(), sale_item_id: sold.items[0].id, quantity: 0.5, amount: 25 }], total: 25,
    }]]))[0].status).toBe('applied');
    const preview = (await call(a.admin, 'SELECT app.agreement_invoice_preview($1, $2) AS p', [agreementId, await today()]))[0].p;
    expect(preview.items.map((i) => [i.kind, i.amount])).toEqual([['sale', 40], ['return', -20]]);
    expect(Number((await ownerPool.query('SELECT app.agreement_used($1, $2) AS u', [customerId, agreementId])).rows[0].u)).toBe(20);
  });

  it('cancelar a última fatura fechada devolve as vendas para o próximo fechamento', async () => {
    const { agreementId, customerId } = await newAgreement();
    const now = await today();
    await push([['sale', sale(customerId, agreementId, 10, new Date(Date.now() - 2 * 86400000))], ['sale', sale(customerId, agreementId, 15)]]);
    const first = (await call(a.admin, 'SELECT app.close_agreement_invoice($1, $2) AS id', [agreementId, shift(now, -1)]))[0].id;
    const second = (await call(a.admin, 'SELECT app.close_agreement_invoice($1, $2) AS id', [agreementId, now]))[0].id;
    await expect(call(a.admin, 'SELECT app.cancel_agreement_invoice($1, $2)', [first, 'Erro'])).rejects.toSatisfy(hasCode('FA858'));
    await expect(call(a.admin, 'SELECT app.cancel_agreement_invoice($1, $2)', [second, ' '])).rejects.toSatisfy(hasCode('FA302'));
    await call(a.admin, 'SELECT app.cancel_agreement_invoice($1, $2)', [second, 'Valor conferido errado']);
    const preview = (await call(a.admin, 'SELECT app.agreement_invoice_preview($1, $2) AS p', [agreementId, now]))[0].p;
    expect(preview.items.map((i) => i.amount)).toEqual([15]);
    const again = (await call(a.admin, 'SELECT app.close_agreement_invoice($1, $2) AS id', [agreementId, now]))[0].id;
    expect((await call(a.admin, 'SELECT app.agreement_invoice_detail($1) AS d', [again]))[0].d.total).toBe(15);
    expect((await call(a.admin, 'SELECT app.agreement_invoice_detail($1) AS d', [second]))[0].d).toMatchObject({
      status: 'cancelled', cancel_reason: 'Valor conferido errado', items: [{ amount: 15 }],
    });
    await expect(call(a.admin, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, now])).rejects.toSatisfy(hasCode('FA857'));
  });

  it('venda acima do limite do convênio (PDV sem internet) vale e vira alerta; o PDV recebe o usado', async () => {
    const { agreementId, customerId } = await newAgreement(50);
    await push([['sale', sale(customerId, agreementId, 40)]]);
    const over = sale(customerId, agreementId, 20);
    await push([['sale', over]]);
    expect((await ownerPool.query("SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'agreement_limit'", [over.id])).rows[0].detail)
      .toEqual({ agreement_id: agreementId, amount: 20, used: 60 });
    await ownerPool.query('INSERT INTO pdv_customer_cache (economic_group_id, terminal_id, customer_id) VALUES ($1, $2, $3)', [a.group.id, a.terminal1.id, customerId]);
    const data = (await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [a.terminal1.id, customerId])).rows[0].data;
    expect(data.agreements).toEqual([expect.objectContaining({ agreement_id: agreementId, credit_limit: 50, used: 60 })]);
  });

  it('dia de fechamento e último fechamento sugerido', async () => {
    const { agreementId } = await newAgreement();
    await expect(call(a.admin, 'SELECT app.set_agreement_closing_day($1, 30)', [agreementId])).rejects.toSatisfy(hasCode('FA860'));
    await call(a.admin, 'SELECT app.set_agreement_closing_day($1, 10)', [agreementId]);
    const last = async (closing, when) => (await ownerPool.query('SELECT app.agreement_last_closing($1::smallint, $2::date)::text AS d', [closing, when])).rows[0].d;
    expect(await last(10, '2026-11-25')).toBe('2026-11-10');
    expect(await last(10, '2026-11-10')).toBe('2026-11-10');
    expect(await last(25, '2026-11-24')).toBe('2026-10-25');
    expect(await last(25, '2027-01-03')).toBe('2026-12-25');
    const preview = (await call(a.admin, 'SELECT app.agreement_invoice_preview($1) AS p', [agreementId]))[0].p;
    expect(preview).toMatchObject({ closing_day: 10, items: [], total: 0 });
    expect(day(0) >= preview.period_end).toBe(true);
  });
});
