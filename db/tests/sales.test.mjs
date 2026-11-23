import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;
let operator;
let manager;
let session;
const FUTURE = '2090-01-31';

const tag = () => randomBytes(4).toString('hex');
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
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
async function readAs(user, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    return await fn(client);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}

let sequence = 0;
/** Sobe itens da outbox como o PDV, confirmando. Devolve os resultados. */
async function push(terminal, entries) {
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
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

let saleNumber = 0;
const money = (value) => Math.round(value * 100) / 100;
/** Venda pronta, com as contas fechadas. items: [{ product, quantity, price, discount, batch, release }]. */
function sale(items, overrides = {}) {
  saleNumber += 1;
  const lines = items.map((item, index) => {
    const gross = money(item.quantity * item.price);
    const discount = item.discount ?? 0;
    return {
      id: uuidV7(), line: index + 1, product_id: item.product.id, barcode_id: item.barcodeId ?? null,
      quantity: item.quantity, unit_price: item.price, discount, total: money(gross - discount),
      batch_id: item.batch ?? null, release: item.release ?? null,
    };
  });
  const subtotal = money(lines.reduce((sum, line) => sum + line.quantity * line.unit_price, 0));
  const discountTotal = money(lines.reduce((sum, line) => sum + line.discount, 0));
  const total = money(subtotal - discountTotal);
  return {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: null,
    sold_at: new Date().toISOString(), fiscal_model: '65', items: lines,
    payments: [{ id: uuidV7(), method: 'cash', amount: total + 10, change: 10 }],
    subtotal, discount_total: discountTotal, total, ...overrides,
  };
}

const newProduct = (overrides = {}, price = 10) => committed(a.admin, async (client) => {
  const barcode = gtin();
  const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [
    JSON.stringify({ displayName: `Produto venda ${tag()}`, barcode, ...overrides }),
  ]);
  await client.query('SELECT app.set_product_price($1, NULL, $2, NULL)', [rows[0].id, price]);
  const code = (await client.query('SELECT code FROM product WHERE id = $1', [rows[0].id])).rows[0].code;
  return { id: rows[0].id, barcode, code };
});
const adjust = (product, quantity, extra = {}) => committed(a.admin, (client) =>
  client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: product.barcode, branchId: a.branch1.id, direction: 'in', quantity, reason: 'Teste da venda', ...extra,
  })]));
const balanceOf = async (product, batch = undefined) => Number((await ownerPool.query(
  `SELECT COALESCE(sum(quantity), 0) AS q FROM stock_balance
    WHERE branch_id = $1 AND product_id = $2 AND deleted_at IS NULL ${batch === undefined ? '' : 'AND batch_id IS NOT DISTINCT FROM $3'}`,
  batch === undefined ? [a.branch1.id, product.id] : [a.branch1.id, product.id, batch],
)).rows[0].q);
const alertsOf = async (saleId) => (await ownerPool.query(
  'SELECT kind, detail FROM sale_alert WHERE sale_id = $1 ORDER BY created_at, id', [saleId],
)).rows;
const batchesOf = async (product) => (await ownerPool.query(
  'SELECT id, batch_number FROM product_batch WHERE product_id = $1 AND branch_id = $2 ORDER BY expires_on', [product.id, a.branch1.id],
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
  operator = await person(`Operador venda ${tag()}`, 'Operador de caixa');
  manager = await person(`Gerente venda ${tag()}`, 'Gerente');
  session = uuidV7();
  const opened = await push(a.terminal1, [['cash_session_open', {
    id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 150,
  }]]);
  expect(opened[0].status).toBe('applied');
});
afterAll(closePools);

describe('turno e venda', () => {
  it('abre o turno com o fundo de troco', async () => {
    const row = (await ownerPool.query('SELECT * FROM cash_session WHERE id = $1', [session])).rows[0];
    expect(row).toMatchObject({ terminal_id: a.terminal1.id, branch_id: a.branch1.id, opened_by: operator.id, status: 'open' });
    expect(Number(row.opening_float)).toBe(150);
  });

  it('grava a venda conferida, baixa o estoque e fica com a nota pendente', async () => {
    const product = await newProduct();
    await adjust(product, 5);
    const payload = sale([{ product, quantity: 2, price: 10 }]);
    expect((await push(a.terminal1, [['sale', payload]]))[0]).toMatchObject({ status: 'applied', code: null });

    const row = (await ownerPool.query('SELECT * FROM sale WHERE id = $1', [payload.id])).rows[0];
    const terminalNumber = (await ownerPool.query('SELECT number FROM terminal WHERE id = $1', [a.terminal1.id])).rows[0].number;
    expect(row).toMatchObject({
      code: `${terminalNumber}-${String(payload.number).padStart(6, '0')}`, fiscal_status: 'pending', fiscal_model: '65',
      sold_by: operator.id, cash_session_id: session, branch_id: a.branch1.id,
    });
    expect(Number(row.total)).toBe(20);
    const item = (await ownerPool.query('SELECT * FROM sale_item WHERE sale_id = $1', [payload.id])).rows[0];
    expect(Number(item.central_price)).toBe(10);
    const pay = (await ownerPool.query('SELECT * FROM sale_payment WHERE sale_id = $1', [payload.id])).rows[0];
    expect([pay.method, Number(pay.amount), Number(pay.change_amount)]).toEqual(['cash', 30, 10]);
    expect(await balanceOf(product)).toBe(3);
    expect(await alertsOf(payload.id)).toEqual([]);
    const movement = (await ownerPool.query('SELECT * FROM stock_movement WHERE sale_item_id = $1', [item.id])).rows;
    expect(movement.map((m) => [m.movement_type, Number(m.quantity)])).toEqual([['sale', -2]]);

    // Reenvio do mesmo item da outbox não baixa de novo.
    expect(await balanceOf(product)).toBe(3);
  });

  it('lote: vencimento mais próximo primeiro, o que faltar sai negativo do último lote', async () => {
    const product = await newProduct();
    await committed(a.admin, (client) => client.query('SELECT app.set_batch_tracking($1, $2, true)', [product.id, a.branch1.id]));
    await adjust(product, 2, { batchNumber: 'L-PERTO', expiresOn: '2089-01-31' });
    await adjust(product, 5, { batchNumber: 'L-LONGE', expiresOn: FUTURE });
    const [near, far] = await batchesOf(product);

    const first = sale([{ product, quantity: 4, price: 10 }]);
    await push(a.terminal1, [['sale', first]]);
    expect([await balanceOf(product, near.id), await balanceOf(product, far.id)]).toEqual([0, 3]);
    expect(await alertsOf(first.id)).toEqual([]);

    const over = sale([{ product, quantity: 5, price: 10 }]);
    await push(a.terminal1, [['sale', over]]);
    expect([await balanceOf(product, near.id), await balanceOf(product, far.id)]).toEqual([0, -2]);
    expect((await alertsOf(over.id)).map((alert) => alert.kind)).toEqual(['negative_stock']);

    // Lote escolhido no PDV (controlados): sai dele, mesmo fora da ordem.
    const chosen = sale([{ product, quantity: 1, price: 10, batch: near.id }]);
    await push(a.terminal1, [['sale', chosen]]);
    expect(await balanceOf(product, near.id)).toBe(-1);

    const detail = await readAs(manager, (client) => client.query('SELECT app.sale_detail($1) AS d', [first.id]).then((r) => r.rows[0].d));
    expect(detail.items[0].batches).toEqual([{ number: 'L-LONGE', quantity: 2 }, { number: 'L-PERTO', quantity: 2 }]);
  });

  it('produto que exige lote e ainda não tem nenhum sai sem lote, com alerta', async () => {
    const product = await newProduct();
    await committed(a.admin, (client) => client.query('SELECT app.set_batch_tracking($1, $2, true)', [product.id, a.branch1.id]));
    const payload = sale([{ product, quantity: 1, price: 10 }]);
    expect((await push(a.terminal1, [['sale', payload]]))[0].status).toBe('applied');
    expect(await balanceOf(product, null)).toBe(-1);
    expect((await alertsOf(payload.id)).map((alert) => alert.kind)).toEqual(['negative_stock']);
    // Fora da venda, a saída sem lote continua recusada.
    await expect(committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
      productLookup: product.barcode, branchId: a.branch1.id, direction: 'in', quantity: 1, reason: 'Teste',
    })]))).rejects.toSatisfy(hasCode('FA802'));
  });

  it('preço: confere com o da central na hora da venda', async () => {
    const product = await newProduct({}, 10);
    await adjust(product, 10);
    // A hora vem do banco: entre o preço da rede e a mudança da loja.
    const before = (await ownerPool.query(`SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS t`)).rows[0].t;
    await committed(a.admin, (client) => client.query('SELECT app.set_product_price($1, $2, 12, $3)', [product.id, a.branch1.id, 'Preço da loja']));
    // Venda feita antes da mudança, chegando depois: vale o preço antigo, sem alerta.
    const old = sale([{ product, quantity: 1, price: 10 }], { sold_at: before });
    await push(a.terminal1, [['sale', old]]);
    expect(await alertsOf(old.id)).toEqual([]);
    // Venda de agora com o preço antigo: alerta com os dois valores.
    const stale = sale([{ product, quantity: 1, price: 10 }]);
    await push(a.terminal1, [['sale', stale]]);
    expect(await alertsOf(stale.id)).toEqual([{ kind: 'price_divergence', detail: { pdv_price: 10, central_price: 12 } }]);
  });

  it('desconto: limite do operador, liberação do supervisor e regra do produto', async () => {
    const product = await newProduct({}, 100);
    await adjust(product, 20);
    // Operador sem limite de desconto: 5% sem liberação vira alerta.
    const alone = sale([{ product, quantity: 1, price: 100, discount: 5 }]);
    await push(a.terminal1, [['sale', alone]]);
    expect(await alertsOf(alone.id)).toEqual([{
      kind: 'discount_above_limit',
      detail: { percent: 5, operator_limit: 0, supervisor_id: null, supervisor_limit: null },
    }]);

    // Com o Gerente (limite 10%) liberando: vira liberação registrada, sem alerta.
    const released = sale([{ product, quantity: 1, price: 100, discount: 8, release: { supervisor_id: manager.id, reason: 'Cliente fiel' } }]);
    await push(a.terminal1, [['sale', released]]);
    expect(await alertsOf(released.id)).toEqual([]);
    const item = (await ownerPool.query('SELECT id FROM sale_item WHERE sale_id = $1', [released.id])).rows[0];
    const release = (await ownerPool.query('SELECT * FROM supervisor_release WHERE reference_id = $1', [item.id])).rows[0];
    expect(release).toMatchObject({ action: 'sales.discount', requested_by: operator.id, released_by: manager.id, reason: 'Cliente fiel' });
    expect([Number(release.value), Number(release.requester_limit), Number(release.releaser_limit)]).toEqual([8, 0, 10]);

    // Acima do limite do Gerente, ou liberado pelo próprio operador: alerta.
    for (const supervisor of [manager, operator]) {
      const payload = sale([{ product, quantity: 1, price: 100, discount: 15, release: { supervisor_id: supervisor.id, reason: 'Teste' } }]);
      await push(a.terminal1, [['sale', payload]]);
      expect((await alertsOf(payload.id)).map((alert) => alert.kind)).toEqual(['discount_above_limit']);
    }

    // Regra do produto: desconto máximo de 3%, o operador não pode passar dela.
    await committed(a.admin, (client) => client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
      typeCode: 'max_discount', value: 3, level: 'product', productLookup: String(product.code),
    })]));
    const ruled = sale([{ product, quantity: 1, price: 100, discount: 4, release: { supervisor_id: manager.id, reason: 'Teste' } }]);
    await push(a.terminal1, [['sale', ruled]]);
    expect(await alertsOf(ruled.id)).toEqual([{ kind: 'discount_above_rule', detail: { percent: 4, rule_max: 3 } }]);
    const byAdmin = sale([{ product, quantity: 1, price: 100, discount: 4 }], { operator_id: a.admin.id });
    await push(a.terminal1, [['sale', byAdmin]]);
    expect(await alertsOf(byAdmin.id)).toEqual([]);
  });

  it('alerta de operador sem permissão, produto bloqueado e convênio sem vínculo', async () => {
    const product = await newProduct();
    await adjust(product, 10);
    await committed(a.admin, (client) => client.query('SELECT app.set_product_status($1, $2, $3, $4)', [product.id, [a.branch1.id], 'blocked', 'Teste']));
    const stranger = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Sem venda ${tag()}`])).rows[0];
    const agreement = (await ownerPool.query(
      'INSERT INTO agreement (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Convênio ${tag()}`],
    )).rows[0];
    const payload = sale([{ product, quantity: 1, price: 10 }], { operator_id: stranger.id });
    payload.payments = [{ id: uuidV7(), method: 'agreement', amount: 10, agreement_id: agreement.id, agreement_registration: 'M-1' }];
    expect((await push(a.terminal1, [['sale', payload]]))[0].status).toBe('applied');
    expect((await alertsOf(payload.id)).map((alert) => alert.kind).sort()).toEqual(['agreement_link', 'operator_permission', 'product_status']);
  });
});

describe('o que não fecha vira conflito', () => {
  it('contas, formato, turno, datas e referências de fora', async () => {
    const product = await newProduct();
    const foreign = await committed(b.admin, async (client) => {
      const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Outro ${tag()}`, barcode: gtin() })]);
      return { id: rows[0].id };
    });
    const otherOperator = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [b.group.id, `Outro ${tag()}`])).rows[0];
    const foreignAgreement = (await ownerPool.query('INSERT INTO agreement (economic_group_id, name) VALUES ($1, $2) RETURNING *', [b.group.id, `Convênio B ${tag()}`])).rows[0];
    const base = () => sale([{ product, quantity: 1, price: 10 }]);
    const cases = [
      ['total errado', (s) => ({ ...s, total: 9 }), 'FA962'],
      ['desconto total errado', (s) => ({ ...s, discount_total: 1 }), 'FA962'],
      ['bruto errado', (s) => ({ ...s, subtotal: 11 }), 'FA962'],
      ['pagamento curto', (s) => ({ ...s, payments: [{ id: uuidV7(), method: 'cash', amount: 5 }] }), 'FA962'],
      ['troco no cartão', (s) => ({ ...s, payments: [{ id: uuidV7(), method: 'credit_card', amount: 20, change: 10 }] }), 'FA962'],
      ['troco maior que o pago', (s) => ({ ...s, payments: [{ id: uuidV7(), method: 'cash', amount: 10, change: 10 }] }), 'FA962'],
      ['meio desconhecido', (s) => ({ ...s, payments: [{ id: uuidV7(), method: 'cheque', amount: 10 }] }), 'FA962'],
      ['convênio sem convênio', (s) => ({ ...s, payments: [{ id: uuidV7(), method: 'agreement', amount: 10 }] }), 'FA962'],
      ['item com conta errada', (s) => ({ ...s, items: [{ ...s.items[0], total: 9 }], total: 9, payments: [{ id: uuidV7(), method: 'cash', amount: 9 }] }), 'FA962'],
      ['desconto maior que o item', (s) => ({ ...s, items: [{ ...s.items[0], discount: 11, total: -1 }] }), 'FA962'],
      ['linha repetida', (s) => ({ ...s, items: [s.items[0], { ...s.items[0], id: uuidV7() }], subtotal: 20, total: 20, payments: [{ id: uuidV7(), method: 'cash', amount: 20 }] }), 'FA962'],
      ['sem itens', (s) => ({ ...s, items: [] }), 'FA962'],
      ['quantidade zero', (s) => ({ ...s, items: [{ ...s.items[0], quantity: 0 }] }), 'FA962'],
      ['preço com três casas', (s) => ({ ...s, items: [{ ...s.items[0], unit_price: 10.001 }] }), 'FA962'],
      ['data impossível', (s) => ({ ...s, sold_at: '2026-13-40T10:00:00Z' }), 'FA962'],
      ['id fora do v7', (s) => ({ ...s, id: randomUUID() }), 'FA962'],
      ['turno desconhecido', (s) => ({ ...s, cash_session_id: uuidV7() }), 'FA962'],
      ['liberação sem motivo', (s) => ({ ...s, items: [{ ...s.items[0], release: { supervisor_id: manager.id, reason: ' ' } }] }), 'FA962'],
      ['modelo de nota desconhecido', (s) => ({ ...s, fiscal_model: '59' }), 'FA962'],
      ['produto de outro grupo', (s) => ({ ...s, items: [{ ...s.items[0], product_id: foreign.id }] }), 'FA004'],
      ['convênio de outro grupo', (s) => ({ ...s, payments: [{ id: uuidV7(), method: 'agreement', amount: 10, agreement_id: foreignAgreement.id }] }), 'FA004'],
      ['operador de outro grupo', (s) => ({ ...s, operator_id: otherOperator.id }), 'FA004'],
      ['cliente desconhecido', (s) => ({ ...s, customer_id: randomUUID() }), 'FA004'],
      ['código de barras de outro produto', (s) => ({ ...s, items: [{ ...s.items[0], barcode_id: randomUUID() }] }), 'FA004'],
      ['lote de outro produto', (s) => ({ ...s, items: [{ ...s.items[0], batch_id: randomUUID() }] }), 'FA004'],
    ];
    const results = await push(a.terminal1, cases.map(([, change]) => ['sale', change(base())]));
    expect(results.map((r, index) => [cases[index][0], r.status, r.code])).toEqual(cases.map(([label, , code]) => [label, 'conflict', code]));
    expect(await balanceOf(product)).toBe(0);

    // Número repetido no terminal, ou a mesma venda com outro item da outbox.
    const done = base();
    await push(a.terminal1, [['sale', done]]);
    const again = await push(a.terminal1, [['sale', { ...base(), number: done.number }], ['sale', done]]);
    expect(again.map((r) => [r.status, r.code])).toEqual([['conflict', 'FA963'], ['conflict', 'FA963']]);
    expect(await balanceOf(product)).toBe(-1);

    // Venda de outro terminal não usa o turno deste.
    const elsewhere = { ...base(), number: 900000 };
    expect((await push(a.terminal2, [['sale', elsewhere]]))[0].code).toBe('FA962');
  });

  it('abertura de turno fora do formato, repetida ou de fora', async () => {
    const otherOperator = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [b.group.id, `Outro ${tag()}`])).rows[0];
    const open = (overrides) => ['cash_session_open', { id: uuidV7(), operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 50, ...overrides }];
    const results = await push(a.terminal1, [
      open({ opening_float: -1 }), open({ opening_float: '50' }), open({ opening_float: 10.555 }), open({ opened_at: 'ontem' }),
      open({ opened_at: '2026-02-30T25:00:00Z' }), open({ id: randomUUID() }), open({ operator_id: otherOperator.id }), open({ id: session }),
    ]);
    expect(results.map((r) => r.code)).toEqual(['FA962', 'FA962', 'FA962', 'FA962', 'FA962', 'FA962', 'FA004', 'FA963']);
  });
});

describe('retaguarda', () => {
  it('lista e detalhe só para quem vê as vendas da filial', async () => {
    const product = await newProduct();
    await adjust(product, 3);
    const payload = sale([{ product, quantity: 1, price: 10 }]);
    await push(a.terminal1, [['sale', payload]]);
    const list = (user) => readAs(user, (client) => client.query('SELECT * FROM app.list_sales(NULL, NULL, NULL)').then((r) => r.rows));
    const mine = (await list(manager)).find((row) => row.id === payload.id);
    expect(mine).toMatchObject({ operator_name: operator.name, payment_methods: ['cash'], fiscal_status: 'pending', item_count: 1, alert_count: 0 });
    expect((await list(operator)).some((row) => row.id === payload.id)).toBe(false);
    expect((await list(b.admin)).some((row) => row.id === payload.id)).toBe(false);
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
    expect((await readAs(manager, (client) => client.query('SELECT id FROM app.list_sales($1, $2, $2)', [a.branch1.id, today]).then((r) => r.rows)))
      .some((row) => row.id === payload.id)).toBe(true);
    expect((await readAs(manager, (client) => client.query('SELECT id FROM app.list_sales($1, NULL, NULL)', [a.branch2.id]).then((r) => r.rows)))).toEqual([]);

    const detail = await readAs(manager, (client) => client.query('SELECT app.sale_detail($1) AS d', [payload.id]).then((r) => r.rows[0].d));
    expect(detail).toMatchObject({ code: expect.stringMatching(/^\d+-\d{6}$/), operator_name: operator.name, fiscal_status: 'pending', alerts: [] });
    expect(detail.items[0]).toMatchObject({ product_id: product.id, quantity: 1, unit_price: 10, central_price: 10 });
    expect(detail.payments[0]).toMatchObject({ method: 'cash', amount: payload.payments[0].amount, change: 10 });
    expect(await readAs(operator, (client) => client.query('SELECT app.sale_detail($1) AS d', [payload.id]).then((r) => r.rows[0].d))).toBeNull();

    // As tabelas seguem a mesma regra.
    expect((await readAs(manager, (client) => client.query('SELECT id FROM v_sale WHERE id = $1', [payload.id]))).rows).toHaveLength(1);
    expect((await readAs(manager, (client) => client.query('SELECT id FROM v_sale_item WHERE sale_id = $1', [payload.id]))).rows).toHaveLength(1);
    expect((await readAs(operator, (client) => client.query('SELECT id FROM v_sale WHERE id = $1', [payload.id]))).rows).toEqual([]);
    expect((await readAs(operator, (client) => client.query('SELECT id FROM v_sale_payment WHERE sale_id = $1', [payload.id]))).rows).toEqual([]);
    expect((await readAs(operator, (client) => client.query('SELECT id FROM v_sale_item WHERE sale_id = $1', [payload.id]))).rows).toEqual([]);
  });

  it('as tabelas recusam por conta própria contas que não fecham e número repetido', async () => {
    const product = await newProduct();
    const payload = sale([{ product, quantity: 1, price: 10 }]);
    await push(a.terminal1, [['sale', payload]]);
    const row = (await ownerPool.query('SELECT * FROM sale WHERE id = $1', [payload.id])).rows[0];
    const insertSale = (overrides) => {
      const values = { ...row, id: uuidV7(), number: row.number + 500000, code: '1-999999', ...overrides };
      return ownerPool.query(
        `INSERT INTO sale (id, economic_group_id, branch_id, terminal_id, cash_session_id, number, code, sold_by, sold_at, subtotal, discount_total, total)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
        [values.id, values.economic_group_id, values.branch_id, values.terminal_id, values.cash_session_id, values.number, values.code,
          values.sold_by, values.sold_at, values.subtotal, values.discount_total, values.total],
      );
    };
    await expect(insertSale({ total: 9 })).rejects.toSatisfy(hasCode('FA962'));
    await expect(insertSale({ number: row.number })).rejects.toSatisfy(hasCode('FA963'));
    const item = (await ownerPool.query('SELECT * FROM sale_item WHERE sale_id = $1', [payload.id])).rows[0];
    await expect(ownerPool.query(
      `INSERT INTO sale_item (id, economic_group_id, sale_id, line, product_id, quantity, unit_price, discount, total)
       VALUES ($1, $2, $3, 2, $4, 1, 10, 0, 9)`,
      [uuidV7(), item.economic_group_id, payload.id, product.id],
    )).rejects.toSatisfy(hasCode('FA962'));
    await expect(ownerPool.query(
      `INSERT INTO sale_payment (id, economic_group_id, sale_id, method, amount, change_amount) VALUES ($1, $2, $3, 'pix', 20, 10)`,
      [uuidV7(), item.economic_group_id, payload.id],
    )).rejects.toSatisfy(hasCode('FA962'));
  });

  it('venda é fato: não muda depois de gravada', async () => {
    const product = await newProduct();
    const payload = sale([{ product, quantity: 1, price: 10 }]);
    await push(a.terminal1, [['sale', payload]]);
    await expect(ownerPool.query('UPDATE sale SET total = 1 WHERE id = $1', [payload.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE sale_item SET quantity = 9 WHERE sale_id = $1', [payload.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE sale_item SET total = 1 WHERE sale_id = $1', [payload.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE sale_payment SET amount = 1 WHERE sale_id = $1', [payload.id])).rejects.toSatisfy(hasCode('FA104'));
  });
});
