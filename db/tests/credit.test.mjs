import { randomBytes, randomInt } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Crediário: contas, parcelas, recebimentos e a descida dos clientes com débito.

let a;
let b;
let operator;
let manager;
let session;
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
const codes = (results) => results.map((r) => [r.status, r.code]);

const newCustomer = async () => (await call(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
  personType: 'individual', document: cpf(), name: `Cliente crediário ${tag()}`,
})]))[0].id;
const openAccount = async (customerId, limit = 100, user = manager) =>
  (await call(user, 'SELECT app.open_credit_account($1, $2, $3, $4) AS id', [customerId, a.branch1.id, limit, null]))[0].id;
const detail = async (customerId, user = manager) =>
  (await call(user, 'SELECT app.credit_account_detail($1) AS d', [customerId]))[0].d;
const schedule = async (amount, count, soldAt = new Date()) => (await ownerPool.query(
  `SELECT app.credit_schedule(app.credit_terms(a), ($2::timestamptz AT TIME ZONE 'America/Sao_Paulo')::date, $3, $4) AS s
     FROM credit_account a JOIN customer c ON c.id = a.customer_id WHERE c.id = $1`,
  [currentCustomer, soldAt.toISOString(), amount, count],
)).rows[0].s;
let currentCustomer;

let productId;
let saleNumber = 0;
/** Venda de um item pago no crediário (e o resto, se houver, em dinheiro). */
async function creditSale(customerId, amount, installments, extra = {}) {
  saleNumber += 1;
  const total = amount + (extra.cash ?? 0);
  const payments = [{ id: uuidV7(), method: 'store_credit', amount, installments, ...(extra.dependent ? { dependent_id: extra.dependent } : {}) }];
  if (extra.cash) payments.push({ id: uuidV7(), method: 'cash', amount: extra.cash });
  const payload = {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId,
    sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: productId, barcode_id: null, quantity: 1, unit_price: total, discount: 0, total, batch_id: null }],
    payments, subtotal: total, discount_total: 0, total, ...extra.overrides,
  };
  return { payload, result: (await push([['sale', payload]]))[0] };
}
const receive = (customerId, amount, extra = {}) => ({
  id: uuidV7(), cash_session_id: session, customer_id: customerId, received_by: operator.id,
  received_at: new Date().toISOString(), method: 'cash', amount, ...extra,
});
// Só os alertas do crediário (o preço do teste varia e dá o alerta de divergência de preço).
const alertsOf = async (saleId) => (await ownerPool.query(
  "SELECT kind, detail FROM sale_alert WHERE sale_id = $1 AND kind LIKE 'credit%' AND kind <> 'credit_release' ORDER BY kind", [saleId],
)).rows;
const installmentsOf = async (saleId) => (await ownerPool.query(
  'SELECT number, due_date::text, amount::float AS amount, dependent_id FROM credit_installment WHERE sale_id = $1 ORDER BY number', [saleId],
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
  operator = await person(`Operador crediário ${tag()}`, 'Operador de caixa');
  manager = await person(`Gerente crediário ${tag()}`, 'Gerente');
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const check = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  const barcode = `${base}${(10 - (check % 10)) % 10}`;
  productId = (await call(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto crediário ${tag()}`, barcode })]))[0].id;
  await call(a.admin, 'SELECT app.set_product_price($1, NULL, $2, NULL)', [productId, 10]);
  await call(a.admin, 'SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: barcode, branchId: a.branch1.id, direction: 'in', quantity: 1000, reason: 'Teste do crediário',
  })]);
  session = uuidV7();
  const opened = await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 100 }]]);
  expect(opened[0].status).toBe('applied');
});
afterAll(closePools);

describe('contas do crediário (casos compartilhados com o PDV)', () => {
  const cases = JSON.parse(readFileSync(new URL('../../packages/credit-cases/cases.json', import.meta.url), 'utf8'));
  for (const item of cases.schedule) {
    it(`vencimentos: ${item.name}`, async () => {
      const { rows } = await ownerPool.query('SELECT app.credit_schedule($1::jsonb, $2::date, $3, $4) AS r',
        [item.terms, item.sold_on, item.amount, item.count]);
      expect(rows[0].r).toEqual(item.expected);
    });
  }
  for (const item of cases.position) {
    it(`encargos: ${item.name}`, async () => {
      const { rows } = await ownerPool.query('SELECT app.credit_position($1::jsonb, $2::date, $3::jsonb) AS r', [item.state, item.at, item.policy]);
      expect(rows[0].r).toEqual(item.expected);
    });
  }
  for (const item of cases.allocate) {
    it(`abatimento: ${item.name}`, async () => {
      const { rows } = await ownerPool.query('SELECT app.credit_allocate($1::jsonb, $2, $3::date, $4::jsonb) AS r',
        [JSON.stringify(item.states), item.amount, item.at, item.policy]);
      expect(rows[0].r).toEqual(item.expected);
    });
  }
});

describe('crediário na retaguarda', () => {
  it('abre a conta com o limite e registra quem abriu e o limite sugerido', async () => {
    const customerId = await newCustomer();
    expect((await detail(customerId)).account).toBeNull();
    await expect(openAccount(customerId, 100, operator)).rejects.toSatisfy(hasCode('FA002'));
    await expect(openAccount(customerId, -1)).rejects.toSatisfy(hasCode('FA838'));
    await openAccount(customerId, 300);
    await expect(openAccount(customerId, 300)).rejects.toSatisfy(hasCode('FA835'));
    const info = await detail(customerId);
    expect(info.account).toMatchObject({ credit_limit: 300, status: 'active', home_branch_id: a.branch1.id, terms: { due_mode: 'closing', own: false } });
    expect(info.summary).toMatchObject({ principal_open: 0, available: 300, overdue_days: 0, blocked_by_overdue: false });
    expect(info.events).toEqual([expect.objectContaining({ kind: 'opened', new_limit: 300, suggested_limit: 0, changed_by_name: manager.name })]);
    expect(info.can_manage).toBe(true);
    // Outro grupo não vê a conta; nem quem não tem a permissão.
    expect((await detail(customerId, b.admin))).toBeNull();
    expect((await detail(customerId, operator)).account).toBeNull();
  });

  it('limite, bloqueio e vencimentos próprios, sempre com o registro', async () => {
    const customerId = await newCustomer();
    const accountId = await openAccount(customerId, 100);
    await expect(call(manager, 'SELECT app.set_credit_limit($1, $2, $3)', [accountId, 200, ' '])).rejects.toSatisfy(hasCode('FA302'));
    await expect(call(operator, 'SELECT app.set_credit_limit($1, $2, $3)', [accountId, 200, 'Aumento'])).rejects.toSatisfy(hasCode('FA834'));
    await expect(call(b.admin, 'SELECT app.set_credit_limit($1, $2, $3)', [accountId, 200, 'Aumento'])).rejects.toSatisfy(hasCode('FA834'));
    await call(manager, 'SELECT app.set_credit_limit($1, $2, $3)', [accountId, 250, 'Cliente antigo, paga em dia']);
    await expect(call(manager, 'SELECT app.set_credit_status($1, $2, $3)', [accountId, 'active', 'Nada'])).rejects.toSatisfy(hasCode('FA836'));
    await expect(call(manager, 'SELECT app.set_credit_status($1, $2, $3)', [accountId, 'blocked', ''])).rejects.toSatisfy(hasCode('FA302'));
    await call(manager, 'SELECT app.set_credit_status($1, $2, $3)', [accountId, 'blocked', 'Pedido do titular']);
    await call(manager, 'SELECT app.set_credit_terms($1, $2::jsonb)', [accountId, JSON.stringify({ due_mode: 'days', interval_days: 15 })]);
    await expect(call(manager, 'SELECT app.set_credit_terms($1, $2::jsonb)', [accountId, JSON.stringify({ due_mode: 'days', interval_days: 3 })]))
      .rejects.toSatisfy(hasCode('FA837'));
    const info = await detail(customerId);
    expect(info.account).toMatchObject({ credit_limit: 250, status: 'blocked', terms: { due_mode: 'days', interval_days: 15, own: true } });
    expect(info.events.map((e) => [e.kind, e.old_limit, e.new_limit, e.reason])).toEqual([
      ['terms', null, null, null], ['blocked', null, null, 'Pedido do titular'],
      ['limit', 100, 250, 'Cliente antigo, paga em dia'], ['opened', null, 100, null],
    ]);
    await call(manager, 'SELECT app.set_credit_terms($1, $2::jsonb)', [accountId, JSON.stringify({ due_mode: null })]);
    expect((await detail(customerId)).account.terms).toMatchObject({ due_mode: 'closing', own: false });
    await expect(ownerPool.query('UPDATE credit_account_event SET reason = $2 WHERE account_id = $1', [accountId, 'outro']))
      .rejects.toSatisfy(hasCode('FA104'));
  });

  it('dependente autorizado a comprar na conta do titular', async () => {
    const customerId = await newCustomer();
    const dependentId = (await call(a.admin, 'SELECT app.add_customer_dependent($1, $2::jsonb) AS id', [customerId, JSON.stringify({ name: 'Filha', relationship: 'child' })]))[0].id;
    await expect(call(manager, 'SELECT app.set_dependent_credit($1, true)', [dependentId])).rejects.toSatisfy(hasCode('FA834'));
    await openAccount(customerId);
    await call(manager, 'SELECT app.set_dependent_credit($1, true)', [dependentId]);
    expect((await detail(customerId)).dependents).toEqual([{ id: dependentId, name: 'Filha', relationship: 'child', credit_allowed: true }]);
  });

  it('parâmetros da filial: só quem define o crediário; dentro dos limites da lei', async () => {
    await expect(call(manager, 'SELECT app.set_credit_policy($1, $2::jsonb)', [a.branch2.id, '{}'])).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(a.admin, 'SELECT app.set_credit_policy($1, $2::jsonb)', [a.branch2.id, JSON.stringify({ late_fee_percent: 2.5 })]))
      .rejects.toSatisfy(hasCode('FA837'));
    await call(a.admin, 'SELECT app.set_credit_policy($1, $2::jsonb)', [a.branch2.id, JSON.stringify({ max_installments: 6, due_mode: 'days' })]);
    await call(a.admin, 'SELECT app.set_credit_policy($1, $2::jsonb)', [a.branch2.id, JSON.stringify({ block_after_days: 10 })]);
    const rows = await call(a.admin, 'SELECT * FROM app.list_credit_policies()');
    expect(rows.find((r) => r.branch_id === a.branch2.id)).toMatchObject({
      customized: true, can_edit: true,
      policy: { max_installments: 6, due_mode: 'days', block_after_days: 10, late_fee_percent: 2, monthly_interest_percent: 1 },
    });
    expect(rows.find((r) => r.branch_id === a.branch1.id)).toMatchObject({ customized: false, policy: { max_installments: 3, closing_day: 25, due_day: 10 } });
    expect((await call(manager, 'SELECT * FROM app.list_credit_policies()')).map((r) => [r.branch_id, r.can_edit])).toEqual([[a.branch1.id, false]]);
  });
});

describe('venda e recebimento vindos do PDV', () => {
  it('venda no crediário grava as parcelas; o cliente com débito desce para toda a rede', async () => {
    currentCustomer = await newCustomer();
    await openAccount(currentCustomer, 100);
    const installments = await schedule(90, 3);
    const { payload, result } = await creditSale(currentCustomer, 90, installments, { cash: 5 });
    expect([result.status, result.code]).toEqual(['applied', null]);
    expect(await installmentsOf(payload.id)).toEqual(installments.map((i) => ({ ...i, dependent_id: null })));
    expect(await alertsOf(payload.id)).toEqual([]);
    const info = await detail(currentCustomer);
    expect(info.summary).toMatchObject({ principal_open: 90, available: 10 });
    expect(info.installments.map((i) => [i.number, i.count, i.amount, i.sale_code])).toEqual(
      installments.map((i) => [i.number, 3, i.amount, expect.any(String)]));
    // Terminal 2 nunca guardou o cliente, mas ele deve: desce com o crediário.
    const targets = (await ownerPool.query('SELECT id FROM app.pdv_targets($1, $2, $3, NULL, NULL) WHERE rank = 5', [a.branch2.id, a.group.id, a.terminal2.id])).rows;
    expect(targets.map((t) => t.id)).toContain(currentCustomer);
    const data = (await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [a.terminal2.id, currentCustomer])).rows[0].data;
    expect(data.credit).toMatchObject({ status: 'active', credit_limit: 100, policy: { max_installments: 3 }, dependents: [] });
    expect(data.credit.installments.map((i) => [i.number, i.principal_open])).toEqual(installments.map((i) => [i.number, i.amount]));
    // Outro grupo não recebe.
    expect((await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [b.terminal1.id, currentCustomer])).rows[0].data).toBeNull();
  });

  it('acima do limite, bloqueado, dependente sem autorização ou vencimentos diferentes: a venda vale e fica o alerta', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    const accountId = await openAccount(customerId, 50);
    const over = await creditSale(customerId, 60, await schedule(60, 1));
    expect(over.result.status).toBe('applied');
    expect((await alertsOf(over.payload.id)).map((al) => [al.kind, al.detail])).toEqual([
      ['credit_limit', { amount: 60, available: 50, credit_limit: 50 }],
    ]);
    const wrongDate = (await schedule(10, 2)).map((i, index) => (index === 1 ? { ...i, due_date: '2099-01-10' } : i));
    const tooMany = await schedule(12, 4);
    const strange = await creditSale(customerId, 10, wrongDate);
    const many = await creditSale(customerId, 12, tooMany);
    expect((await alertsOf(strange.payload.id)).map((al) => al.kind)).toEqual(['credit_limit', 'credit_schedule']);
    expect((await alertsOf(many.payload.id)).map((al) => al.kind)).toEqual(['credit_limit', 'credit_schedule']);
    expect((await installmentsOf(strange.payload.id))[1].due_date).toBe('2099-01-10');

    await call(manager, 'SELECT app.set_credit_limit($1, $2, $3)', [accountId, 5000, 'Teste']);
    await call(manager, 'SELECT app.set_credit_status($1, $2, $3)', [accountId, 'blocked', 'Teste']);
    const dependentId = (await call(a.admin, 'SELECT app.add_customer_dependent($1, $2::jsonb) AS id', [customerId, JSON.stringify({ name: 'Neto', relationship: 'grandchild' })]))[0].id;
    const blocked = await creditSale(customerId, 10, await schedule(10, 1), { dependent: dependentId });
    expect((await alertsOf(blocked.payload.id)).map((al) => al.kind)).toEqual(['credit_blocked', 'credit_dependent']);
    expect((await installmentsOf(blocked.payload.id))[0].dependent_id).toBe(dependentId);
  });

  it('fora do formato ou sem conta: conflito', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    await openAccount(customerId, 500);
    const good = await schedule(30, 2);
    const cases = [
      [good.map((i) => ({ ...i, amount: 10 })), 'FA962'],
      [[], 'FA962'],
      [[good[1], good[0]], 'FA962'],
      [[{ ...good[0], due_date: good[1].due_date }, { ...good[1], due_date: good[0].due_date }], 'FA962'],
      [good.map((i) => ({ ...i, due_date: '2026-02-30' })), 'FA962'],
      [Array.from({ length: 25 }, (_, n) => ({ number: n + 1, due_date: `2090-01-${String(n + 1).padStart(2, '0')}`, amount: 1.2 })), 'FA962'],
    ];
    for (const [installments, code] of cases) {
      expect([(await creditSale(customerId, 30, installments)).result.code]).toEqual([code]);
    }
    const noAccount = await newCustomer();
    expect((await creditSale(noAccount, 30, good)).result.code).toBe('FA834');
    expect((await creditSale(null, 30, good)).result.code).toBe('FA834');
    const other = (await creditSale(customerId, 30, good, { dependent: 'nada' })).result.code;
    expect(other).toBe('FA962');
  });

  it('recebimento abate a parcela mais antiga e entra no esperado do caixa', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    await openAccount(customerId, 200);
    const installments = await schedule(100, 2);
    await creditSale(customerId, 100, installments);
    const expectedBefore = (await ownerPool.query('SELECT expected FROM app.cash_expected($1) WHERE method = $2', [session, 'cash'])).rows[0].expected;
    const payment = receive(customerId, 60);
    expect(codes(await push([['credit_payment', payment]]))).toEqual([['applied', null]]);
    const allocations = (await ownerPool.query(
      `SELECT i.number, al.principal::float AS principal, al.fee::float AS fee, al.accrued_on
         FROM credit_allocation al JOIN credit_installment i ON i.id = al.installment_id WHERE al.payment_id = $1 ORDER BY i.number`, [payment.id],
    )).rows;
    expect(allocations).toEqual([
      { number: 1, principal: installments[0].amount, fee: 0, accrued_on: null },
      { number: 2, principal: 60 - installments[0].amount, fee: 0, accrued_on: null },
    ]);
    const expectedAfter = (await ownerPool.query('SELECT expected FROM app.cash_expected($1) WHERE method = $2', [session, 'cash'])).rows[0].expected;
    expect(Number(expectedAfter) - Number(expectedBefore)).toBe(60);
    const pix = receive(customerId, 5, { method: 'pix' });
    await push([['credit_payment', pix]]);
    expect((await detail(customerId)).summary).toMatchObject({ principal_open: 35, available: 165 });
    expect((await detail(customerId)).payments.map((p) => [p.method, p.amount, p.principal, p.received_by_name])).toEqual([
      ['pix', 5, 5, operator.name], ['cash', 60, 60, operator.name],
    ]);

    // Pago a mais: o dinheiro já entrou, fica o excesso e o alerta do caixa; sem débito, o cliente sai da rede.
    const extra = receive(customerId, 50);
    await push([['credit_payment', extra]]);
    expect(Number((await ownerPool.query('SELECT excess FROM credit_payment WHERE id = $1', [extra.id])).rows[0].excess)).toBe(15);
    expect((await ownerPool.query("SELECT detail FROM cash_alert WHERE kind = 'credit_overpayment' AND detail ->> 'credit_payment_id' = $1", [extra.id])).rows[0].detail)
      .toEqual({ credit_payment_id: extra.id, amount: 50, excess: 15 });
    expect((await ownerPool.query('SELECT app.credit_has_debt($1) AS d', [customerId])).rows[0].d).toBe(false);
    expect((await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [a.terminal2.id, customerId])).rows[0].data).toBeNull();
  });

  it('parcela em atraso: multa e juros na data do recebimento, e o atraso bloqueia', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    await openAccount(customerId, 500);
    const { payload } = await creditSale(customerId, 100, await schedule(100, 1));
    // A parcela venceu há 40 dias (ajuste direto, só para o teste).
    const due = new Date(Date.now() - 40 * 86400000).toISOString().slice(0, 10);
    await ownerPool.query('ALTER TABLE credit_installment DISABLE TRIGGER block_immutable_columns');
    try {
      await ownerPool.query('UPDATE credit_installment SET due_date = $2 WHERE sale_id = $1', [payload.id, due]);
    } finally {
      await ownerPool.query('ALTER TABLE credit_installment ENABLE TRIGGER block_immutable_columns');
    }
    const info = await detail(customerId);
    expect(info.summary).toMatchObject({ principal_open: 100, overdue_principal: 100, blocked_by_overdue: true });
    expect(info.installments[0].position).toMatchObject({ fee: 2, principal: 100 });
    const days = info.summary.overdue_days;
    const interest = Math.round(100 * days / 30) / 100;
    expect(info.installments[0].position.interest).toBe(interest);
    expect((await call(manager, 'SELECT * FROM app.list_credit_accounts($1, NULL)', ['overdue'])).map((r) => r.customer_id)).toContain(customerId);

    const blockedSale = await creditSale(customerId, 10, await schedule(10, 1));
    expect((await alertsOf(blockedSale.payload.id)).map((al) => al.kind)).toEqual(['credit_overdue']);

    const payment = receive(customerId, 10);
    await push([['credit_payment', payment]]);
    const [row] = (await ownerPool.query(
      'SELECT fee::float, interest::float, principal::float, interest_open_after::float, accrued_on::text FROM credit_allocation WHERE payment_id = $1 ORDER BY created_at', [payment.id],
    )).rows;
    expect(row).toEqual({ fee: 2, interest, principal: Math.round((8 - interest) * 100) / 100, interest_open_after: 0, accrued_on: expect.any(String) });
  });

  it('situação da parcela depois de pagar antes e depois do vencimento', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    const accountId = await openAccount(customerId, 500);
    const { payload } = await creditSale(customerId, 100, await schedule(100, 1));
    const early = receive(customerId, 40);
    await push([['credit_payment', early]]);
    const states = async () => (await ownerPool.query('SELECT app.credit_states($1) AS s', [accountId])).rows[0].s;
    // Agora a parcela venceu há 40 dias, e os 40 foram pagos 5 dias antes do vencimento.
    const day = (offset) => new Date(Date.now() + offset * 86400000).toISOString().slice(0, 10);
    await ownerPool.query('ALTER TABLE credit_installment DISABLE TRIGGER block_immutable_columns');
    await ownerPool.query('ALTER TABLE credit_allocation DISABLE TRIGGER block_immutable_columns');
    try {
      await ownerPool.query('UPDATE credit_installment SET due_date = $2 WHERE sale_id = $1', [payload.id, day(-40)]);
      await ownerPool.query('UPDATE credit_allocation SET received_on = $2 WHERE payment_id = $1', [early.id, day(-45)]);
    } finally {
      await ownerPool.query('ALTER TABLE credit_installment ENABLE TRIGGER block_immutable_columns');
      await ownerPool.query('ALTER TABLE credit_allocation ENABLE TRIGGER block_immutable_columns');
    }
    expect(await states()).toEqual([expect.objectContaining({
      principal_open: 60, fee_base: 60, fee_paid: 0, interest_open: 0, accrued_until: day(-40),
    })]);
    // R$ 1,00 não cobre a multa (1,20): os juros do atraso ficam em aberto, contados até hoje.
    const small = receive(customerId, 1);
    await push([['credit_payment', small]]);
    const today = (await ownerPool.query('SELECT app.credit_today()::text AS d')).rows[0].d;
    const days = (Date.parse(today) - Date.parse(day(-40))) / 86400000;
    expect(await states()).toEqual([expect.objectContaining({
      principal_open: 60, fee_base: 60, fee_paid: 1, interest_open: Math.round(60 * days / 30) / 100, accrued_until: today,
    })]);
    await push([['credit_payment', receive(customerId, 100)]]);
    expect(await states()).toEqual([]);
  });

  it('recebimento fora do formato, repetido, de outro turno ou sem conta: conflito', async () => {
    const customerId = await newCustomer();
    await openAccount(customerId, 100);
    const ok = receive(customerId, 1);
    await push([['credit_payment', ok]]);
    const noAccount = await newCustomer();
    expect(codes(await push([
      ['credit_payment', ok],
      ['credit_payment', receive(customerId, 0)],
      ['credit_payment', receive(customerId, 1.234)],
      ['credit_payment', receive(customerId, 1, { method: 'agreement' })],
      ['credit_payment', receive(customerId, 1, { received_at: 'ontem' })],
      ['credit_payment', receive(customerId, 1, { cash_session_id: uuidV7() })],
      ['credit_payment', receive(noAccount, 1)],
    ]))).toEqual([
      ['conflict', 'FA963'], ['conflict', 'FA962'], ['conflict', 'FA962'], ['conflict', 'FA962'], ['conflict', 'FA962'],
      ['conflict', 'FA995'], ['conflict', 'FA834'],
    ]);
    await expect(ownerPool.query('UPDATE credit_payment SET amount = 2 WHERE id = $1', [ok.id])).rejects.toSatisfy(hasCode('FA104'));
  });

  it('acima do limite do operador: precisa da liberação de quem tem limite; sem ela, alerta', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    await openAccount(customerId, 5000);
    const releaseAlert = async (saleId) => (await ownerPool.query(
      "SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'credit_release'", [saleId],
    )).rows.map((r) => r.detail);
    const sell = async (amount, release) => {
      const installments = await schedule(amount, 1);
      saleNumber += 1;
      const payload = {
        id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId,
        sold_at: new Date().toISOString(), fiscal_model: '65',
        items: [{ id: uuidV7(), line: 1, product_id: productId, barcode_id: null, quantity: 1, unit_price: amount, discount: 0, total: amount, batch_id: null }],
        payments: [{ id: uuidV7(), method: 'store_credit', amount, installments, ...(release === undefined ? {} : { release }) }],
        subtotal: amount, discount_total: 0, total: amount,
      };
      const [result] = await push([['sale', payload]]);
      return { payload, result };
    };
    // O operador de caixa não tem limite de crediário (zero): sem liberação, a venda vale e fica o alerta.
    const alone = await sell(100);
    expect(alone.result.status).toBe('applied');
    expect(await releaseAlert(alone.payload.id)).toEqual([{ amount: 100, operator_limit: 0, released_by: null, releaser_limit: null }]);
    // O Gerente libera até R$ 500 (limite de exemplo do perfil).
    const released = await sell(100, { supervisor_id: manager.id, reason: 'Cliente conhecido' });
    expect(await releaseAlert(released.payload.id)).toEqual([]);
    const row = (await ownerPool.query('SELECT * FROM supervisor_release WHERE reference_id = $1', [released.payload.payments[0].id])).rows[0];
    expect(row).toMatchObject({ action: 'sales.store_credit', requested_by: operator.id, released_by: manager.id, reason: 'Cliente conhecido' });
    const tooMuch = await sell(600, { supervisor_id: manager.id });
    expect(await releaseAlert(tooMuch.payload.id)).toEqual([{ amount: 600, operator_limit: 0, released_by: manager.id, releaser_limit: 500 }]);
    const self = await sell(50, { supervisor_id: operator.id });
    expect((await releaseAlert(self.payload.id))[0]).toMatchObject({ released_by: null });
    // Liberação fora do formato, ou em outra forma de pagamento: conflito.
    expect((await sell(10, { supervisor_id: 'nada' })).result.code).toBe('FA962');
  });

  it('devolução de venda no crediário abate o débito; de outra venda, conflito', async () => {
    const customerId = await newCustomer();
    currentCustomer = customerId;
    const accountId = await openAccount(customerId, 500);
    const { payload } = await creditSale(customerId, 80, await schedule(80, 2));
    let returnNumber = 0;
    const refund = (sale, amount, destination = 'store_credit') => {
      returnNumber += 1;
      return {
        id: uuidV7(), number: returnNumber, cash_session_id: session, sale_id: sale.id, operator_id: manager.id, authorized_by: null,
        reason: 'Cliente desistiu', destination, returned_at: new Date().toISOString(),
        items: [{ id: uuidV7(), sale_item_id: sale.items[0].id, quantity: 1, amount }], total: amount,
      };
    };
    // A busca da venda para a devolução diz se foi no crediário.
    const lookup = async (code) => {
      const client = await appPool.connect();
      try {
        await client.query('BEGIN');
        await setTerminal(client, a.terminal1.id);
        return (await client.query('SELECT app.pdv_sale_for_return($1) AS s', [code])).rows[0].s;
      } finally {
        await client.query('ROLLBACK');
        client.release();
      }
    };
    const saleCode = (await ownerPool.query('SELECT code FROM sale WHERE id = $1', [payload.id])).rows[0].code;
    expect(await lookup(saleCode)).toMatchObject({ has_store_credit: true, has_agreement: false });
    const back = refund(payload, 80);
    expect(codes(await push([['sale_return', back]]))).toEqual([['applied', null]]);
    const payment = (await ownerPool.query('SELECT * FROM credit_payment WHERE return_id = $1', [back.id])).rows[0];
    expect(payment).toMatchObject({ method: 'return', account_id: accountId, received_by: manager.id, cash_session_id: session });
    expect(Number(payment.amount)).toBe(80);
    expect((await ownerPool.query('SELECT app.credit_states($1) AS s', [accountId])).rows[0].s).toEqual([]);
    // Devolução não entra no caixa.
    const cashBefore = (await ownerPool.query('SELECT expected FROM app.cash_expected($1) WHERE method = $2', [session, 'cash'])).rows[0].expected;
    expect((await detail(customerId)).payments.map((p) => [p.method, p.principal])).toEqual([['return', 80]]);
    // Venda paga em dinheiro não abate o crediário.
    const plain = await creditSale(customerId, 0.01, await schedule(0.01, 1), {
      overrides: { payments: [{ id: uuidV7(), method: 'cash', amount: 0.01 }] },
    });
    expect(codes(await push([['sale_return', refund(plain.payload, 0.01)]]))).toEqual([['conflict', 'FA846']]);
    const cashAfter = (await ownerPool.query('SELECT expected FROM app.cash_expected($1) WHERE method = $2', [session, 'cash'])).rows[0].expected;
    expect(Number(cashAfter) - Number(cashBefore)).toBeCloseTo(0.01, 2);
    // Devolução maior que o débito: o excesso fica registrado e vira alerta do caixa.
    const small = await creditSale(customerId, 20, await schedule(20, 1));
    await push([['credit_payment', receive(customerId, 15)]]);
    const late = refund(small.payload, 20);
    await push([['sale_return', late]]);
    const excess = (await ownerPool.query('SELECT excess FROM credit_payment WHERE return_id = $1', [late.id])).rows[0].excess;
    expect(Number(excess)).toBe(15);
    const code = (await ownerPool.query('SELECT code FROM sale_return WHERE id = $1', [late.id])).rows[0].code;
    expect((await ownerPool.query("SELECT detail FROM cash_alert WHERE kind = 'credit_overpayment' AND detail ->> 'return_code' = $1", [code])).rows[0].detail)
      .toMatchObject({ amount: 20, excess: 15 });
  });

  it('lista das contas para a retaguarda, com filtro', async () => {
    const rows = await call(manager, 'SELECT * FROM app.list_credit_accounts($1, NULL)', ['all']);
    expect(rows.length).toBeGreaterThan(3);
    expect(rows.every((r) => r.home_branch_name === a.branch1.name)).toBe(true);
    const debt = await call(manager, 'SELECT * FROM app.list_credit_accounts($1, NULL)', ['debt']);
    expect(debt.every((r) => Number(r.principal_open) > 0)).toBe(true);
    const blocked = await call(manager, 'SELECT * FROM app.list_credit_accounts($1, NULL)', ['blocked']);
    expect(blocked.every((r) => r.status === 'blocked' || r.blocked_by_overdue)).toBe(true);
    expect(await call(operator, 'SELECT * FROM app.list_credit_accounts($1, NULL)', ['all'])).toEqual([]);
    expect(await call(b.admin, 'SELECT * FROM app.list_credit_accounts($1, NULL)', ['all'])).toEqual([]);
  });
});
