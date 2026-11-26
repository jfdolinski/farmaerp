import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Envio do SNGPC: credencial da filial, remessas montadas pela rotina (inventário primeiro),
// arquivo guardado como foi enviado, resultado da Anvisa e recusa que volta para o farmacêutico.

let a;
let b;
let operator;
let pharmacist;
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
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const today = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
const day = (offset) => new Date(Date.now() + offset * 86400000).toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });

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
const person = async (roleName) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  return user;
};
const product = async (controlledClass) => {
  const sourceKey = `sngpc-${tag()}`;
  const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey, name: `Controlado ${sourceKey}`, ...(controlledClass ? { controlledClass } : {}),
  })])).rows[0].id;
  return committed(a.admin, async (client) => {
    const barcode = gtin();
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${sourceKey}`, barcode, catalogProductId: catalogId,
    })]);
    await client.query('SELECT app.set_product_price($1, NULL, 20, NULL)', [rows[0].id]);
    return { id: rows[0].id, barcode };
  });
};
const stockIn = (item, batchNumber, quantity, ms = '1234567890123', branch = a.branch1) => call(a.admin, 'SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
  productLookup: item.barcode, branchId: branch.id, direction: 'in', quantity, reason: 'Teste', batchNumber, expiresOn: '2090-01-31',
  ...(ms ? { msRegistration: ms } : {}),
})]);
const batchOf = async (item, number, branch = a.branch1) =>
  (await ownerPool.query('SELECT id FROM product_batch WHERE product_id = $1 AND batch_number = $2 AND branch_id = $3', [item.id, number, branch.id])).rows[0].id;
const complete = (overrides = {}) => ({
  id: uuidV7(), status: 'complete', pharmacist_id: pharmacist.id,
  prescription_type: 'notification_b', prescription_number: 'SP-123456', prescription_date: day(-2),
  prescriber_name: 'Dra. Ana Prescritora', prescriber_council: 'CRM', prescriber_number: '123456', prescriber_state: 'SP',
  buyer_name: 'João Comprador', buyer_document_type: 'rg', buyer_document: '12.345.678-9', buyer_issuer: 'SSP', buyer_state: 'SP',
  ...overrides,
});
let number = 0;
const sale = (item, quantity, batch, controlled) => {
  number += 1;
  return {
    id: uuidV7(), number, cash_session_id: session, operator_id: operator.id, customer_id: null, sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: item.id, quantity, unit_price: 20, discount: 0, total: 20 * quantity, batch_id: batch, controlled }],
    payments: [{ id: uuidV7(), method: 'cash', amount: 20 * quantity }], subtotal: 20 * quantity, discount_total: 0, total: 20 * quantity,
  };
};
const movements = (status = 'pending', branch = a.branch1) => call(pharmacist, 'SELECT * FROM app.sngpc_movements($1, $2)', [branch.id, status]);
const check = (ids) => call(pharmacist, 'SELECT movement_id, problem, suggested_on::text, balance::float FROM app.sngpc_check($1, $2::uuid[])', [a.branch1.id, ids]);
const problems = async (ids) => (await check(ids)).map((p) => p.problem);
const confirm = (ids, sendOn = today()) => call(pharmacist, 'SELECT app.sngpc_confirm($1, $2::uuid[], $3::date) AS n', [a.branch1.id, ids, sendOn]).then((r) => r[0].n);

async function asWorker(sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'sngpc', true)");
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
const next = () => asWorker('SELECT app.sngpc_next_submission($1) AS s', [a.branch1.id]).then((r) => r[0].s);
const claim = () => asWorker('SELECT * FROM app.sngpc_claim_branches(50)');
const release = () => asWorker('SELECT app.sngpc_release_branch($1)', [a.branch1.id]);
const sent = (id, payload = '<sngpc/>') => asWorker('SELECT app.sngpc_mark_sent($1, $2, $3, $4)', [id, payload, 'a'.repeat(64), `P-${tag()}`]);
const result = (id, accepted, reason = null) => asWorker('SELECT app.sngpc_mark_result($1, $2, $3)', [id, accepted, reason]);
const statusOf = async (id) => (await ownerPool.query('SELECT status, submission_id, status_reason FROM sngpc_movement WHERE id = $1', [id])).rows[0];

let b1;
let b2;
let batchL1;
let batchL2;
let inventory;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  pharmacist = await person('Farmacêutico');
  session = uuidV7();
  await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 }]]);
  b1 = await product('B1');
  b2 = await product('B2');
  await stockIn(b1, 'L1', 10);
  await stockIn(b2, 'L2', 10);
  batchL1 = await batchOf(b1, 'L1');
  batchL2 = await batchOf(b2, 'L2');
  await call(pharmacist, 'SELECT app.sngpc_open($1)', [a.branch1.id]);
  inventory = (await movements()).map((r) => r.id);
});
afterAll(closePools);

describe('envio do SNGPC', () => {
  it('credencial da filial: só quem confere o SNGPC; a tela vê só a data', async () => {
    await expect(call(operator, 'SELECT app.set_sngpc_credential($1, $2, $3)', [a.branch1.id, Buffer.from('u'), Buffer.from('p')])).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(b.admin, 'SELECT app.set_sngpc_credential($1, $2, $3)', [a.branch1.id, Buffer.from('u'), Buffer.from('p')])).rejects.toSatisfy(hasCode('FA006'));
    expect((await call(pharmacist, 'SELECT app.sngpc_send_info($1) AS i', [a.branch1.id]))[0].i).toMatchObject({ credential_at: null, rejected: 0 });
    // Sem credencial, a rotina não pega a filial.
    await confirm(inventory);
    expect((await claim()).map((r) => r.branch_id)).not.toContain(a.branch1.id);
    await call(pharmacist, 'SELECT app.set_sngpc_credential($1, $2, $3)', [a.branch1.id, Buffer.from('usuario-cifrado'), Buffer.from('senha-cifrada')]);
    await call(pharmacist, 'SELECT app.set_sngpc_credential($1, $2, $3)', [a.branch1.id, Buffer.from('usuario-cifrado-2'), Buffer.from('senha-cifrada-2')]);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_credential WHERE branch_id = $1 AND deleted_at IS NULL', [a.branch1.id])).rows[0].n).toBe(1);
    expect((await call(pharmacist, 'SELECT app.sngpc_send_info($1) AS i', [a.branch1.id]))[0].i.credential_at).toEqual(expect.any(String));
  });

  it('só a rotina monta e envia; inventário primeiro; o arquivo enviado não muda', async () => {
    await expect(call(pharmacist, 'SELECT * FROM app.sngpc_claim_branches(10)')).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(pharmacist, 'SELECT app.sngpc_next_submission($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA002'));
    // Uma venda conferida junto: fica para depois do inventário aceito.
    await push([['sale', sale(b1, 2, batchL1, complete({ batch_id: batchL1 }))]]);
    const saleRow = (await movements()).find((r) => r.kind === 'sale');
    expect(await confirm([saleRow.id])).toBe(1);

    const claimed = await claim();
    const mine = claimed.find((r) => r.branch_id === a.branch1.id);
    expect(mine).toMatchObject({ cnpj: a.branch1.cnpj });
    expect(Buffer.from(mine.encrypted_username).toString()).toBe('usuario-cifrado-2');
    // Reservada: outra instância não pega de novo.
    expect((await claim()).map((r) => r.branch_id)).not.toContain(a.branch1.id);
    await release();

    const first = await next();
    expect(first).toMatchObject({ kind: 'inventory', status: 'built', branch: { id: a.branch1.id } });
    expect(first.movements.map((m) => [m.kind, m.batch_number, Number(m.quantity), m.ms_registration])).toEqual([
      ['inventory', 'L1', 10, '1234567890123'], ['inventory', 'L2', 10, '1234567890123'],
    ]);
    // Em aberto: a próxima chamada devolve a mesma.
    expect((await next()).id).toBe(first.id);
    await asWorker('SELECT app.sngpc_mark_failed($1, $2)', [first.id, 'Tempo esgotado']);
    expect((await call(pharmacist, 'SELECT * FROM app.list_sngpc_submissions($1)', [a.branch1.id]))[0]).toMatchObject({ status: 'built', attempts: 1, last_error: 'Tempo esgotado' });

    await sent(first.id, '<inventario/>');
    expect((await statusOf(inventory[0])).status).toBe('sent');
    await expect(ownerPool.query("UPDATE sngpc_submission SET payload = '<outro/>' WHERE id = $1", [first.id])).rejects.toSatisfy(hasCode('FA720'));
    await expect(sent(first.id)).rejects.toSatisfy(hasCode('FA720'));
    expect((await next()).id).toBe(first.id);
    await result(first.id, true);
    await expect(result(first.id, true)).rejects.toSatisfy(hasCode('FA720'));
    expect((await statusOf(inventory[0])).status).toBe('accepted');

    const second = await next();
    expect(second).toMatchObject({ kind: 'movements' });
    expect(second.movements).toEqual([expect.objectContaining({
      kind: 'sale', batch_number: 'L1', quantity: 2,
      prescription: expect.objectContaining({ type: 'notification_b', number: 'SP-123456', buyer_name: 'João Comprador' }),
    })]);
    const file = (await call(pharmacist, 'SELECT app.sngpc_submission_file($1) AS f', [first.id]))[0].f;
    expect(file.payload).toBe('<inventario/>');
    await expect(call(operator, 'SELECT app.sngpc_submission_file($1)', [first.id])).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(b.admin, 'SELECT app.sngpc_submission_file($1)', [first.id])).rejects.toSatisfy(hasCode('FA006'));
    await expect(call(pharmacist, 'SELECT app.sngpc_submission_file($1)', [second.id])).rejects.toSatisfy(hasCode('FA006'));
    await sent(second.id);
    await result(second.id, true);
  });

  it('recusa: volta ao farmacêutico, segura o produto e entra de novo depois de corrigida', async () => {
    await push([
      ['sale', sale(b1, 1, batchL1, complete({ batch_id: batchL1 }))],
      ['sale', sale(b2, 1, batchL2, complete({ batch_id: batchL2 }))],
    ]);
    const rows = await movements();
    const onB1 = rows.find((r) => r.batch_number === 'L1').id;
    const onB2 = rows.find((r) => r.batch_number === 'L2').id;
    expect(await confirm([onB1, onB2])).toBe(2);
    const third = await next();
    expect(third.movements.map((m) => m.batch_number).sort()).toEqual(['L1', 'L2']);
    await sent(third.id);
    await result(third.id, false, 'Receita sem número de registro do prescritor');
    expect(await statusOf(onB1)).toMatchObject({ status: 'rejected', status_reason: 'Receita sem número de registro do prescritor' });
    expect((await call(pharmacist, 'SELECT * FROM app.sngpc_movements($1, $2)', [a.branch1.id, 'rejected'])).length).toBe(2);
    expect((await call(pharmacist, 'SELECT app.sngpc_send_info($1) AS i', [a.branch1.id]))[0].i.rejected).toBe(2);

    // Nova venda de B1, conferida: fica segura enquanto B1 tem recusa.
    await push([['sale', sale(b1, 1, batchL1, complete({ batch_id: batchL1 }))]]);
    const newB1 = (await movements()).find((r) => r.batch_number === 'L1').id;
    expect(await confirm([newB1])).toBe(1);
    // B2 reaberta e conferida de novo: vai sozinha.
    await expect(call(operator, 'SELECT app.sngpc_reopen($1)', [onB2])).rejects.toSatisfy(hasCode('FA002'));
    await call(pharmacist, 'SELECT app.sngpc_reopen($1)', [onB2]);
    await expect(call(pharmacist, 'SELECT app.sngpc_reopen($1)', [onB2])).rejects.toSatisfy(hasCode('FA863'));
    expect(await statusOf(onB2)).toEqual({ status: 'pending', submission_id: null, status_reason: null });
    expect(await confirm([onB2])).toBe(1);
    const fourth = await next();
    expect(fourth.movements.map((m) => m.id)).toEqual([onB2]);
    await sent(fourth.id);
    await result(fourth.id, true);
    // B1 corrigida e conferida de novo: aí as duas de B1 saem juntas.
    await call(pharmacist, 'SELECT app.sngpc_reopen($1)', [onB1]);
    expect(await confirm([onB1])).toBe(1);
    const fifth = await next();
    expect(fifth.movements.map((m) => m.id).sort()).toEqual([onB1, newB1].sort());
    await sent(fifth.id);
    await result(fifth.id, true);
  });

  it('data de envio no futuro espera; sem nada a enviar, nada é montado', async () => {
    await push([['sale', sale(b2, 1, batchL2, complete({ batch_id: batchL2 }))]]);
    const row = (await movements()).find((r) => r.kind === 'sale');
    expect(await confirm([row.id], day(3))).toBe(1);
    expect(await next()).toBeNull();
    expect((await ownerPool.query("SELECT count(*)::int AS n FROM sngpc_submission WHERE branch_id = $1 AND deleted_at IS NULL AND status = 'built'", [a.branch1.id])).rows[0].n).toBe(0);
  });
});
