import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Sangria em três níveis, suprimento e fechamento com conferência cega.
let a;
let operator;
let supervisor;
let manager;
let product;

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
const now = () => new Date().toISOString();

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

const role = async (name, limit) => {
  const created = (await ownerPool.query('INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, name])).rows[0];
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'sales.sell'`, [created.id],
  );
  await ownerPool.query(
    `INSERT INTO role_limit (economic_group_id, role_id, limit_type_id, value)
     SELECT $1, $2, id, $3 FROM limit_type WHERE code = 'cash_withdrawal'`, [a.group.id, created.id, limit],
  );
  return created;
};
const person = async (roleRow) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleRow.name} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, roleRow.id, a.branch1.id]);
  return user;
};
const openSession = async (floatAmount = 100) => {
  const id = uuidV7();
  expect(codes(await push([['cash_session_open', { id, operator_id: operator.id, opened_at: now(), opening_float: floatAmount }]])))
    .toEqual([['applied', null]]);
  return id;
};
let saleNumber = 0;
const sale = (session, payments) => {
  saleNumber += 1;
  const total = payments.reduce((sum, p) => sum + p.amount - (p.change ?? 0), 0);
  return {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: null, sold_at: now(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: product.id, quantity: total / 20, unit_price: 20, discount: 0, total }],
    payments: payments.map((p) => ({ id: uuidV7(), ...p })), subtotal: total, discount_total: 0, total,
  };
};
const movement = (session, overrides = {}) => ({
  id: uuidV7(), cash_session_id: session, kind: 'withdrawal', amount: 50, reason: 'Sangria de rotina', operator_id: operator.id,
  released_by: null, moved_at: now(), ...overrides,
});
const close = (session, counts, overrides = {}) => ({
  cash_session_id: session, closed_by: operator.id, closed_at: now(),
  counts: { cash: 0, credit_card: 0, debit_card: 0, pix: 0, ...counts }, note: null, ...overrides,
});
const alerts = async (session) => (await ownerPool.query(
  'SELECT kind, detail FROM cash_alert WHERE cash_session_id = $1 ORDER BY created_at, id', [session],
)).rows;
const releases = async (movementId) => (await ownerPool.query(
  "SELECT action, requested_by, released_by, value::float, requester_limit::float, releaser_limit::float FROM supervisor_release WHERE reference_id = $1",
  [movementId],
)).rows;

beforeAll(async () => {
  ({ a } = await createFixtures());
  operator = await person(await role(`Caixa ${tag()}`, 100));
  supervisor = await person(await role(`Supervisor ${tag()}`, 500));
  manager = await person(await role(`Gerente de loja ${tag()}`, 2000));
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id)
     SELECT ur.role_id, p.id FROM user_role ur, permission p WHERE ur.user_id = $1 AND p.code = 'sales.view'`, [manager.id],
  );
  const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey: `caixa-${tag()}`, name: 'Produto do caixa',
  })])).rows[0].id;
  product = await committed(a.admin, async (client) => {
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${tag()}`, barcode: gtin(), catalogProductId: catalogId,
    })]);
    await client.query('SELECT app.set_product_price($1, NULL, 20, NULL)', [rows[0].id]);
    return { id: rows[0].id };
  });
});
afterAll(closePools);

describe('sangria em três níveis', () => {
  it('até o limite do operador, sozinho; suprimento não precisa de liberação', async () => {
    const session = await openSession();
    const alone = movement(session, { amount: 100 });
    const supply = movement(session, { kind: 'supply', amount: 30, reason: 'Troco do cofre' });
    // Suprimento acima do limite de sangria do operador também não pede liberação.
    const bigSupply = movement(session, { kind: 'supply', amount: 5000, reason: 'Troco do banco' });
    expect(codes(await push([['cash_movement', alone], ['cash_movement', supply], ['cash_movement', bigSupply]])))
      .toEqual([['applied', null], ['applied', null], ['applied', null]]);
    expect(await releases(bigSupply.id)).toEqual([]);
    expect(await releases(alone.id)).toEqual([]);
    expect(await alerts(session)).toEqual([]);
    const rows = (await ownerPool.query('SELECT kind, amount::float, reason, branch_id FROM cash_movement WHERE cash_session_id = $1 ORDER BY kind', [session])).rows;
    expect(rows.sort((x, y) => x.kind.localeCompare(y.kind) || x.amount - y.amount)).toEqual([
      { kind: 'supply', amount: 30, reason: 'Troco do cofre', branch_id: a.branch1.id },
      { kind: 'supply', amount: 5000, reason: 'Troco do banco', branch_id: a.branch1.id },
      { kind: 'withdrawal', amount: 100, reason: 'Sangria de rotina', branch_id: a.branch1.id },
    ]);
  });

  it('acima: supervisor com limite libera; acima do supervisor, o gerente', async () => {
    const session = await openSession();
    const bySupervisor = movement(session, { amount: 300, released_by: supervisor.id });
    const byManager = movement(session, { amount: 800, released_by: manager.id });
    expect(codes(await push([['cash_movement', bySupervisor], ['cash_movement', byManager]]))).toEqual([['applied', null], ['applied', null]]);
    expect(await releases(bySupervisor.id)).toEqual([{
      action: 'cash.withdrawal', requested_by: operator.id, released_by: supervisor.id, value: 300, requester_limit: 100, releaser_limit: 500,
    }]);
    expect((await releases(byManager.id))[0]).toMatchObject({ released_by: manager.id, releaser_limit: 2000 });
    expect(await alerts(session)).toEqual([]);
  });

  it('sem liberação válida a sangria vale (o dinheiro já saiu) e vira alerta', async () => {
    const session = await openSession();
    const noRelease = movement(session, { amount: 150 });
    const weakRelease = movement(session, { amount: 800, released_by: supervisor.id });
    expect(codes(await push([['cash_movement', noRelease], ['cash_movement', weakRelease]]))).toEqual([['applied', null], ['applied', null]]);
    expect(await releases(noRelease.id)).toEqual([]);
    expect(await releases(weakRelease.id)).toEqual([]);
    const found = await alerts(session);
    expect(found.map((row) => row.kind)).toEqual(['withdrawal_above_limit', 'withdrawal_above_limit']);
    expect(found[1].detail).toEqual({ amount: 800, operator_limit: 100, released_by: supervisor.id, releaser_limit: 500 });
  });

  it('administrador não tem teto', async () => {
    const session = await openSession();
    const big = movement(session, { amount: 5000, operator_id: a.admin.id });
    expect(codes(await push([['cash_movement', big]]))).toEqual([['applied', null]]);
    expect(await alerts(session)).toEqual([]);
  });

  it('fora do formato, de outro terminal ou de turno desconhecido: conflito', async () => {
    const session = await openSession();
    const bad = [
      movement(session, { amount: 0 }),
      movement(session, { amount: '10' }),
      movement(session, { amount: 10.555 }),
      movement(session, { kind: 'transfer' }),
      movement(session, { reason: '  ' }),
      movement(session, { reason: 'x'.repeat(501) }),
      movement(session, { released_by: operator.id }),
      movement(session, { kind: 'supply', released_by: supervisor.id }),
      movement(session, { id: '019a0000-0000-4000-8000-000000000001' }),
      movement(session, { moved_at: 'ontem' }),
      movement(session, { moved_at: '2026-02-30T10:00:00Z' }),
      movement(uuidV7()),
    ];
    expect(codes(await push(bad.map((m) => ['cash_movement', m])))).toEqual(bad.map(() => ['conflict', 'FA995']));
    expect(codes(await push([['cash_movement', movement(session)]], a.terminal2))).toEqual([['conflict', 'FA995']]);
    const foreign = (await createFixtures()).a.admin;
    expect(codes(await push([['cash_movement', movement(session, { amount: 300, released_by: foreign.id })]]))).toEqual([['conflict', 'FA004']]);
    const once = movement(session);
    await push([['cash_movement', once]]);
    expect(codes(await push([['cash_movement', once]]))).toEqual([['conflict', 'FA963']]);
  });

  it('o movimento gravado não muda', async () => {
    const session = await openSession();
    const done = movement(session);
    await push([['cash_movement', done]]);
    await expect(ownerPool.query('UPDATE cash_movement SET amount = 1 WHERE id = $1', [done.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE cash_movement SET released_by = $2 WHERE id = $1', [done.id, manager.id])).rejects.toSatisfy(hasCode('FA104'));
  });
});

describe('fechamento com conferência cega', () => {
  it('a central calcula o esperado, grava a diferença e fecha o turno', async () => {
    const session = await openSession(100);
    expect(codes(await push([
      ['sale', sale(session, [{ method: 'cash', amount: 50, change: 10 }])], // 40 em dinheiro
      ['sale', sale(session, [{ method: 'pix', amount: 20 }, { method: 'credit_card', amount: 40 }])],
      ['sale', sale(session, [{ method: 'debit_card', amount: 20 }])],
      ['cash_movement', movement(session, { kind: 'supply', amount: 50, reason: 'Troco' })],
      ['cash_movement', movement(session, { amount: 60 })],
    ])).map(([status]) => status)).toEqual(['applied', 'applied', 'applied', 'applied', 'applied']);

    // Antes do fechamento, a retaguarda já vê o esperado de agora.
    const open = (await readAs(manager, 'SELECT app.cash_session_detail($1) AS d', [session]))[0].d;
    expect(open.counts.map((c) => [c.method, Number(c.expected), c.counted])).toEqual([
      ['cash', 130, null], ['credit_card', 40, null], ['debit_card', 20, null], ['pix', 20, null],
    ]);

    // Contou R$ 5 a menos no dinheiro e o PIX certo; cartões certos.
    const result = await push([['cash_session_close', close(session, { cash: 125, credit_card: 40, debit_card: 20, pix: 20 }, { note: ' Faltou troco ' })]]);
    expect(codes(result)).toEqual([['applied', null]]);
    const row = (await ownerPool.query('SELECT status, closed_by, closing_note FROM cash_session WHERE id = $1', [session])).rows[0];
    expect(row).toEqual({ status: 'closed', closed_by: operator.id, closing_note: 'Faltou troco' });
    const counts = (await ownerPool.query(
      'SELECT method, counted::float, expected::float, difference::float FROM cash_session_count WHERE cash_session_id = $1 ORDER BY method', [session],
    )).rows;
    expect(counts).toEqual([
      { method: 'cash', counted: 125, expected: 130, difference: -5 },
      { method: 'credit_card', counted: 40, expected: 40, difference: 0 },
      { method: 'debit_card', counted: 20, expected: 20, difference: 0 },
      { method: 'pix', counted: 20, expected: 20, difference: 0 },
    ]);
    expect(await alerts(session)).toEqual([{ kind: 'closing_difference', detail: { cash: -5 } }]);

    // Turno fechado não recebe movimento nem outro fechamento.
    expect(codes(await push([['cash_movement', movement(session)]]))).toEqual([['conflict', 'FA996']]);
    expect(codes(await push([['cash_session_close', close(session, {})]]))).toEqual([['conflict', 'FA996']]);
  });

  it('sem diferença, sem alerta; convênio não entra na conferência', async () => {
    const session = await openSession(0);
    expect(codes(await push([['cash_session_close', close(session, {})]]))).toEqual([['applied', null]]);
    expect(await alerts(session)).toEqual([]);
  });

  it('contagem fora do formato é conflito', async () => {
    const session = await openSession();
    const bad = [
      close(session, {}, { counts: { cash: 1, credit_card: 0, debit_card: 0 } }),
      close(session, { agreement: 0 }),
      close(session, { cash: -1 }),
      close(session, { cash: '1' }),
      close(session, { cash: 1.234 }),
      close(session, {}, { counts: [] }),
      close(session, {}, { note: 'x'.repeat(501) }),
      close(session, {}, { closed_at: 'hoje' }),
      close(session, {}, { closed_by: 'nada' }),
    ];
    expect(codes(await push(bad.map((c) => ['cash_session_close', c])))).toEqual(bad.map(() => ['conflict', 'FA995']));
    expect(codes(await push([['cash_session_close', close(session, {})]], a.terminal2))).toEqual([['conflict', 'FA995']]);
    expect((await ownerPool.query('SELECT status FROM cash_session WHERE id = $1', [session])).rows[0].status).toBe('open');
  });
});

describe('retaguarda', () => {
  it('lista e detalhe para quem vê as vendas da filial', async () => {
    const session = await openSession(10);
    const released = movement(session, { amount: 200, released_by: supervisor.id });
    await push([['cash_movement', released], ['cash_session_close', close(session, { cash: 0 })]]);
    const listed = (await readAs(manager, 'SELECT * FROM app.list_cash_sessions($1, NULL, NULL, $2)', [a.branch1.id, 'closed']))
      .find((row) => row.id === session);
    expect(listed).toMatchObject({ status: 'closed', alert_count: 1 });
    expect([listed.opening_float, listed.withdrawals, listed.counted_total, listed.difference_total].map(Number)).toEqual([10, 200, 0, 190]);
    const open = await readAs(manager, 'SELECT * FROM app.list_cash_sessions(NULL, NULL, NULL, $1)', ['open']);
    expect(open.every((row) => row.status === 'open')).toBe(true);
    const detail = (await readAs(manager, 'SELECT app.cash_session_detail($1) AS d', [session]))[0].d;
    expect(detail.movements).toEqual([expect.objectContaining({ kind: 'withdrawal', amount: 200, released_by_name: supervisor.name })]);
    expect(detail.alerts.map((alert) => alert.kind)).toEqual(['closing_difference']);
    expect(detail.counts[0]).toMatchObject({ method: 'cash', counted: 0, expected: -190, difference: 190 });

    // Sem sales.view, nada.
    expect(await readAs(operator, 'SELECT * FROM app.list_cash_sessions()')).toEqual([]);
    expect((await readAs(operator, 'SELECT app.cash_session_detail($1) AS d', [session]))[0].d).toBeNull();
    expect(await readAs(operator, 'SELECT * FROM v_cash_movement')).toEqual([]);
    expect((await readAs(manager, 'SELECT * FROM v_cash_movement WHERE cash_session_id = $1', [session]))).toHaveLength(1);
  });
});
