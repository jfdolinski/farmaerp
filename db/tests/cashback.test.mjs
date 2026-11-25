import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Cashback: ganho pelo motor de regras, uso reservado no caixa, expiração e devolução.

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
async function asTerminal(sql, params = [], terminal = a.terminal1) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows[0];
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
let sequence = 0;
async function push(entries, terminal = a.terminal1) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
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

const newCustomer = async (consent = true) => {
  const id = (await call(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
    personType: 'individual', document: cpf(), name: `Cliente cashback ${tag()}`,
  })]))[0].id;
  if (consent) await call(a.admin, "SELECT app.record_customer_consent($1, 'cashback', true, 'store')", [id]);
  return id;
};
const balance = async (customerId) => (await ownerPool.query('SELECT app.cashback_balance($1) AS b', [customerId])).rows[0].b;
const reserve = (customerId, amount, total) =>
  asTerminal('SELECT app.pdv_cashback_reserve($1, $2, $3) AS r', [customerId, amount, total]).then((r) => r.r);

let saleNumber = 0;
/** Venda de um item a R$ total, paga em dinheiro e, se houver, com o cashback reservado. */
function sale(customerId, total, cashback = null) {
  saleNumber += 1;
  const payments = [];
  if (cashback) payments.push({ id: uuidV7(), method: 'cashback', amount: cashback.amount, reservation_id: cashback.reservation });
  const rest = Math.round((total - (cashback?.amount ?? 0)) * 100) / 100;
  if (rest > 0) payments.push({ id: uuidV7(), method: 'cash', amount: rest });
  return {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId,
    sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: productId, barcode_id: null, quantity: 1, unit_price: total, discount: 0, total, batch_id: null }],
    payments, subtotal: total, discount_total: 0, total,
  };
}
const entries = async (customerId) => (await ownerPool.query(
  'SELECT kind, amount::float AS amount, status FROM cashback_entry WHERE customer_id = $1 ORDER BY created_at, id', [customerId],
)).rows;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const roleOf = async (name) => (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, name])).rows[0].id;
  const person = async (name, role) => {
    const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, name])).rows[0];
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, await roleOf(role), a.branch1.id]);
    return user;
  };
  operator = await person(`Operador cashback ${tag()}`, 'Operador de caixa');
  manager = await person(`Gerente cashback ${tag()}`, 'Gerente');
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const check = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  const barcode = `${base}${(10 - (check % 10)) % 10}`;
  productId = (await call(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto cashback ${tag()}`, barcode })]))[0].id;
  await call(a.admin, 'SELECT app.set_product_price($1, NULL, $2, NULL)', [productId, 10]);
  await call(a.admin, 'SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: barcode, branchId: a.branch1.id, direction: 'in', quantity: 1000, reason: 'Teste do cashback',
  })]);
  // Cashback de 5% neste produto, pelo motor de regras.
  await call(a.admin, 'SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
    typeCode: 'cashback', value: 5, level: 'product', productLookup: barcode,
  })]);
  session = uuidV7();
  const opened = await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 100 }]]);
  expect(opened[0].status).toBe('applied');
});
afterAll(closePools);

describe('cashback', () => {
  it('ganho pelo motor, só com consentimento; carência e validade da rede', async () => {
    const withConsent = await newCustomer();
    const without = await newCustomer(false);
    const sold = sale(withConsent, 100);
    expect((await push([['sale', sold], ['sale', sale(without, 100)]])).map((r) => r.status)).toEqual(['applied', 'applied']);
    expect(await entries(without)).toEqual([]);
    const lot = (await ownerPool.query("SELECT * FROM cashback_entry WHERE sale_id = $1 AND kind = 'earn'", [sold.id])).rows[0];
    expect(Number(lot.amount)).toBe(5);
    expect((lot.expires_at - lot.available_at) / 86400000).toBe(90);
    expect(lot.detail).toMatchObject({ items: [{ line: 1, percent: 5 }], paid_with_cashback: 0 });
    expect(await balance(withConsent)).toMatchObject({ available: 5, waiting: 0 });

    // Carência de 7 dias: o ganho ainda não pode ser usado.
    await expect(call(manager, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ waiting_days: 7 })])).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(a.admin, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ max_use_percent: 0 })])).rejects.toSatisfy(hasCode('FA853'));
    await call(a.admin, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ waiting_days: 7 })]);
    expect((await call(a.admin, 'SELECT app.get_cashback_policy() AS p'))[0].p).toEqual({ waiting_days: 7, validity_days: 90, max_use_percent: 50, can_edit: true });
    const later = await newCustomer();
    await push([['sale', sale(later, 40)]]);
    expect(await balance(later)).toMatchObject({ available: 0, waiting: 2 });
    await call(a.admin, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ waiting_days: 0 })]);
  });

  it('uso no caixa: reserva com consentimento, saldo e máximo; a venda confirma e ganha só sobre o pago sem cashback', async () => {
    const customerId = await newCustomer();
    await push([['sale', sale(customerId, 200)]]);
    expect((await balance(customerId)).available).toBe(10);
    await expect(reserve(customerId, 11, 100)).rejects.toSatisfy(hasCode('FA850'));
    await expect(reserve(customerId, 6, 10)).rejects.toSatisfy(hasCode('FA851'));
    await expect(reserve(await newCustomer(false), 1, 100)).rejects.toSatisfy(hasCode('FA849'));
    const held = await reserve(customerId, 8, 40);
    expect(held.balance).toBe(2);
    expect((await balance(customerId)).available).toBe(2);
    const paid = sale(customerId, 40, { amount: 8, reservation: held.reservation_id });
    expect((await push([['sale', paid]]))[0].status).toBe('applied');
    const use = (await ownerPool.query('SELECT status, sale_id FROM cashback_entry WHERE id = $1', [held.reservation_id])).rows[0];
    expect(use).toEqual({ status: 'confirmed', sale_id: paid.id });
    // Ganho sobre os R$ 32 pagos em dinheiro: R$ 1,60.
    const earn = (await ownerPool.query("SELECT amount::float AS a, detail FROM cashback_entry WHERE sale_id = $1 AND kind = 'earn'", [paid.id])).rows[0];
    expect(earn).toMatchObject({ a: 1.6, detail: { paid_with_cashback: 8 } });
    expect((await balance(customerId)).available).toBe(3.6);
    expect((await ownerPool.query("SELECT count(*)::int AS n FROM sale_alert WHERE sale_id = $1 AND kind = 'cashback_use'", [paid.id])).rows[0].n).toBe(0);
    // Forma cashback sem cliente ou sem a reserva: conflito.
    const noCustomer = sale(null, 10, { amount: 1, reservation: uuidV7() });
    const noReservation = sale(customerId, 10);
    noReservation.payments = [{ id: uuidV7(), method: 'cashback', amount: 10 }];
    expect((await push([['sale', noCustomer], ['sale', noReservation]])).map((r) => r.code)).toEqual(['FA962', 'FA962']);
  });

  it('desistência libera a reserva; reserva vencida não segura o saldo e a venda que chega com ela vira alerta', async () => {
    const customerId = await newCustomer();
    await push([['sale', sale(customerId, 100)]]);
    const held = await reserve(customerId, 2, 10);
    // Outro terminal não libera a reserva deste.
    await expect(asTerminal('SELECT app.pdv_cashback_release($1)', [held.reservation_id], a.terminal2)).rejects.toSatisfy(hasCode('FA852'));
    await asTerminal('SELECT app.pdv_cashback_release($1)', [held.reservation_id]);
    expect((await balance(customerId)).available).toBe(5);
    await expect(asTerminal('SELECT app.pdv_cashback_release($1)', [held.reservation_id])).rejects.toSatisfy(hasCode('FA852'));
    await expect(asTerminal('SELECT app.pdv_cashback_release($1)', [held.reservation_id], a.terminal2)).rejects.toSatisfy(hasCode('FA852'));

    const stale = await reserve(customerId, 3, 10);
    // Reserva de 3 horas atrás (ajuste direto, só para o teste).
    await ownerPool.query('ALTER TABLE cashback_entry DISABLE TRIGGER USER');
    try {
      await ownerPool.query("UPDATE cashback_entry SET created_at = now() - interval '3 hours' WHERE id = $1", [stale.reservation_id]);
    } finally {
      await ownerPool.query('ALTER TABLE cashback_entry ENABLE TRIGGER USER');
    }
    expect((await balance(customerId)).available).toBe(5);
    const late = sale(customerId, 10, { amount: 3, reservation: stale.reservation_id });
    await push([['sale', late]]);
    expect((await ownerPool.query("SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'cashback_use'", [late.id])).rows[0].detail)
      .toEqual({ amount: 3, problem: 'reservation', shortfall: 0 });
    expect((await ownerPool.query('SELECT status FROM cashback_entry WHERE id = $1', [stale.reservation_id])).rows[0].status).toBe('released');
    // Usou 3 do saldo de agora; ganhou 5% sobre os R$ 7 pagos (R$ 0,35).
    expect((await balance(customerId)).available).toBe(2.35);
  });

  it('o que vence sai do saldo por um lançamento de expiração', async () => {
    const customerId = await newCustomer();
    const sold = sale(customerId, 100);
    await push([['sale', sold]]);
    await ownerPool.query('ALTER TABLE cashback_entry DISABLE TRIGGER block_immutable_columns');
    try {
      await ownerPool.query(
        "UPDATE cashback_entry SET available_at = now() - interval '100 days', expires_at = now() - interval '10 days' WHERE sale_id = $1 AND kind = 'earn'",
        [sold.id],
      );
    } finally {
      await ownerPool.query('ALTER TABLE cashback_entry ENABLE TRIGGER block_immutable_columns');
    }
    expect((await balance(customerId)).available).toBe(0);
    await expect(reserve(customerId, 1, 10)).rejects.toSatisfy(hasCode('FA850'));
    // A expiração é gravada na próxima gravação do cliente que der certo (aqui, direto).
    await ownerPool.query('SELECT app.cashback_expire($1)', [customerId]);
    expect((await entries(customerId)).map((e) => [e.kind, e.amount])).toEqual([['earn', 5], ['expire', 5]]);
  });

  it('devolução: estorna o ganho na proporção e o usado volta como cashback; o destino recebe o resto', async () => {
    const customerId = await newCustomer();
    await push([['sale', sale(customerId, 400)]]);
    const held = await reserve(customerId, 10, 50);
    const sold = sale(customerId, 50, { amount: 10, reservation: held.reservation_id });
    await push([['sale', sold]]);
    expect((await ownerPool.query("SELECT amount::float AS a FROM cashback_entry WHERE sale_id = $1 AND kind = 'earn'", [sold.id])).rows[0].a).toBe(2);
    let returnNumber = 0;
    const refund = (amount, destination) => {
      returnNumber += 1;
      return {
        id: uuidV7(), number: returnNumber, cash_session_id: session, sale_id: sold.id, operator_id: manager.id, authorized_by: null,
        reason: 'Cliente desistiu', destination, returned_at: new Date().toISOString(),
        items: [{ id: uuidV7(), sale_item_id: sold.items[0].id, quantity: 0.5, amount }], total: amount,
      };
    };
    const first = refund(25, 'credit');
    expect((await push([['sale_return', first]]))[0].status).toBe('applied');
    const row = (await ownerPool.query('SELECT cashback_refund::float AS c, refund_amount::float AS r, code FROM sale_return WHERE id = $1', [first.id])).rows[0];
    expect([row.c, row.r]).toEqual([5, 20]);
    const kinds = async () => (await ownerPool.query(
      'SELECT kind, amount::float AS a FROM cashback_entry WHERE sale_return_id IS NOT NULL AND sale_id = $1 ORDER BY created_at, id', [sold.id],
    )).rows.map((e) => [e.kind, e.a]);
    expect(await kinds()).toEqual([['reverse', 1], ['refund', 5]]);
    // O crédito de devolução vale o resto (R$ 20), não o total.
    const credit = await asTerminal('SELECT app.pdv_return_credit($1) AS c', [row.code]);
    expect(credit.c).toMatchObject({ total: 20, balance: 20 });
    // Usar R$ 22 desse crédito numa venda passa do valor a devolver: a venda vale e fica o alerta.
    const over = sale(null, 22);
    over.payments = [{ id: uuidV7(), method: 'return_credit', amount: 22, return_id: first.id }];
    await push([['sale', over]]);
    expect((await ownerPool.query("SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'return_credit'", [over.id])).rows[0].detail)
      .toMatchObject({ problem: 'balance', balance: 20 });

    // A segunda metade fecha no centavo com o que foi usado e ganho.
    const second = refund(25, 'cash');
    await push([['sale_return', second]]);
    expect(await kinds()).toEqual([['reverse', 1], ['refund', 5], ['reverse', 1], ['refund', 5]]);
    const code = (await ownerPool.query('SELECT code FROM sale_return WHERE id = $1', [second.id])).rows[0].code;
    const document = await asTerminal('SELECT app.pdv_return($1) AS d', [code]);
    expect(document.d.total).toBe(20);
    // A sangria paga os R$ 20 sem alerta.
    const movement = uuidV7();
    await push([['cash_movement', {
      id: movement, cash_session_id: session, operator_id: manager.id, kind: 'withdrawal', amount: 20, reason: `Devolução ${code}`,
      moved_at: new Date().toISOString(), return_id: second.id,
    }]]);
    expect((await ownerPool.query("SELECT count(*)::int AS n FROM cash_alert WHERE cash_movement_id = $1 AND kind = 'return_payout'", [movement])).rows[0].n).toBe(0);
  });

  it('uso tira primeiro do lote que vence antes', async () => {
    const customerId = await newCustomer();
    const longer = sale(customerId, 100);
    await push([['sale', longer]]);
    await call(a.admin, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ validity_days: 30 })]);
    const shorter = sale(customerId, 40);
    try {
      await push([['sale', shorter]]);
    } finally {
      await call(a.admin, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ validity_days: 90 })]);
    }
    const held = await reserve(customerId, 3, 10);
    const lots = (await ownerPool.query(
      'SELECT l.sale_id, al.amount::float AS a FROM cashback_allocation al JOIN cashback_entry l ON l.id = al.lot_id WHERE al.entry_id = $1 ORDER BY al.created_at, al.id',
      [held.reservation_id],
    )).rows.map((r) => [r.sale_id, r.a]);
    // O lote de 30 dias (R$ 2) acaba primeiro; o resto sai do de 90 dias.
    expect(lots).toEqual([[shorter.id, 2], [longer.id, 1]]);
  });

  it('devolução em partes: a parte do cashback fecha no centavo com o que foi usado', async () => {
    const customerId = await newCustomer();
    await push([['sale', sale(customerId, 400)]]);
    const held = await reserve(customerId, 10, 30);
    const sold = sale(customerId, 30, { amount: 10, reservation: held.reservation_id });
    sold.items[0] = { ...sold.items[0], quantity: 3, unit_price: 10 };
    await push([['sale', sold]]);
    const parts = [];
    for (let n = 1; n <= 3; n += 1) {
      const id = uuidV7();
      await push([['sale_return', {
        id, number: 100 + n, cash_session_id: session, sale_id: sold.id, operator_id: manager.id, authorized_by: null,
        reason: 'Troca', destination: 'credit', returned_at: new Date().toISOString(),
        items: [{ id: uuidV7(), sale_item_id: sold.items[0].id, quantity: 1, amount: 10 }], total: 10,
      }]]);
      parts.push(Number((await ownerPool.query('SELECT cashback_refund FROM sale_return WHERE id = $1', [id])).rows[0].cashback_refund));
    }
    expect(parts).toEqual([3.33, 3.34, 3.33]);
  });

  it('extrato para a retaguarda, só do próprio grupo', async () => {
    const customerId = await newCustomer();
    await push([['sale', sale(customerId, 100)]]);
    const statement = (await call(manager, 'SELECT app.cashback_statement($1) AS s', [customerId]))[0].s;
    expect(statement).toMatchObject({ available: 5, consent: true, entries: [{ kind: 'earn', amount: 5, remaining: 5, branch_name: a.branch1.name }] });
    await expect(call(b.admin, 'SELECT app.cashback_statement($1) AS s', [customerId])).rejects.toSatisfy(hasCode('FA006'));
    await expect(asTerminal('SELECT app.pdv_cashback($1) AS c', [customerId], b.terminal1)).rejects.toSatisfy(hasCode('FA006'));
    expect((await asTerminal('SELECT app.pdv_cashback($1) AS c', [customerId])).c).toMatchObject({
      available: 5, consent: true, policy: { max_use_percent: 50 },
    });
  });
});
