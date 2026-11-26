import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Entreposto do SNGPC: abertura com inventário, movimentações por trigger, dados que faltam,
// simulação do saldo por lote e conferência.

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

let b1;
let common;
let batchL1;
let inventory;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  pharmacist = await person('Farmacêutico');
  session = uuidV7();
  await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 }]]);
  b1 = await product('B1');
  common = await product(null);
  await stockIn(b1, 'L1', 5);
  batchL1 = await batchOf(b1, 'L1');
  // Produto comum com lote: não entra no inventário do SNGPC.
  await call(a.admin, 'SELECT app.set_batch_tracking($1, $2, true)', [common.id, a.branch1.id]);
  await stockIn(common, 'C-1', 5);
});
afterAll(closePools);

describe('SNGPC', () => {
  it('abre a filial com o inventário dos lotes de controlado; só o farmacêutico; uma vez', async () => {
    // Antes de abrir, nada entra no entreposto.
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE branch_id = $1', [a.branch1.id])).rows[0].n).toBe(0);
    await expect(call(operator, 'SELECT app.sngpc_open($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA002'));
    await expect(call(b.admin, 'SELECT app.sngpc_open($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA006'));
    await expect(call(pharmacist, 'SELECT * FROM app.sngpc_movements($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA862'));
    const opened = (await call(pharmacist, 'SELECT app.sngpc_open($1) AS r', [a.branch1.id]))[0].r;
    expect(opened).toEqual({ inventory_lines: 1, unbatched: [] });
    await expect(call(pharmacist, 'SELECT app.sngpc_open($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA861'));
    const rows = await movements();
    expect(rows.map((r) => [r.kind, r.batch_number, Number(r.quantity), r.ms_registration])).toEqual([['inventory', 'L1', 5, '1234567890123']]);
    inventory = rows[0].id;
    const branches = await call(pharmacist, 'SELECT * FROM app.sngpc_branches()');
    expect(branches).toEqual([expect.objectContaining({ branch_id: a.branch1.id, inventory_pending: 1, pending: 1, confirmed: 0 })]);
    expect(await call(operator, 'SELECT * FROM app.sngpc_branches()')).toEqual([]);
  });

  it('inventário: corrige a quantidade e confere antes do resto', async () => {
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [inventory, JSON.stringify({ quantity: 0 })])).rejects.toSatisfy(hasCode('FA865'));
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [inventory, JSON.stringify({ reportedOn: day(-1) })])).rejects.toSatisfy(hasCode('FA866'));
    await call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [inventory, JSON.stringify({ quantity: 4 })]);
    // Produto comum não entra; controlado entra como ajuste.
    await stockIn(b1, 'L1', 1);
    await stockIn(common, 'C-1', 1);
    const rows = await movements();
    expect(rows.map((r) => [r.kind, Number(r.quantity)])).toEqual([['inventory', 4], ['adjustment_in', 1]]);
    const adjustment = rows[1].id;
    expect(await problems([adjustment])).toEqual(['adjustment_in', 'earlier_pending', 'inventory_pending']);
    await expect(call(pharmacist, 'SELECT app.sngpc_disregard($1, $2)', [adjustment, ' '])).rejects.toSatisfy(hasCode('FA302'));
    await call(pharmacist, 'SELECT app.sngpc_disregard($1, $2)', [adjustment, 'Contagem do inventário já inclui']);
    expect(await problems([inventory])).toEqual([]);
    await expect(confirm([inventory], day(-1))).rejects.toSatisfy(hasCode('FA866'));
    await expect(call(operator, 'SELECT app.sngpc_confirm($1, $2::uuid[], $3::date)', [a.branch1.id, [inventory], today()])).rejects.toSatisfy(hasCode('FA002'));
    expect(await confirm([inventory])).toBe(1);
    const done = (await movements('confirmed'))[0];
    expect(done).toMatchObject({ id: inventory, ms_registration: '1234567890123', confirmed_by_name: pharmacist.name });
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [inventory, JSON.stringify({ quantity: 3 })])).rejects.toSatisfy(hasCode('FA863'));
    await expect(ownerPool.query('UPDATE sngpc_movement SET quantity = 3 WHERE id = $1', [inventory])).rejects.toSatisfy(hasCode('FA863'));
    await expect(ownerPool.query("UPDATE sngpc_movement SET status = 'pending', confirmed_by = NULL, confirmed_at = NULL, send_on = NULL WHERE id = $1", [inventory]))
      .rejects.toSatisfy(hasCode('FA863'));
    await expect(call(pharmacist, 'SELECT app.sngpc_add_inventory($1, $2, 1)', [a.branch1.id, batchL1])).rejects.toSatisfy(hasCode('FA863'));
  });

  it('venda: ordem por produto, saldo do lote e MS na conferência', async () => {
    const first = sale(b1, 3, batchL1, complete({ batch_id: batchL1 }));
    const second = sale(b1, 2, batchL1, complete({ batch_id: batchL1 }));
    expect((await push([['sale', first], ['sale', second]])).map((r) => r.status)).toEqual(['applied', 'applied']);
    const rows = await movements();
    expect(rows.map((r) => [r.kind, Number(r.quantity), r.dispensing_status])).toEqual([['sale', 3, 'complete'], ['sale', 2, 'complete']]);
    expect(rows[0].counterpart).toMatch(/^Venda /);
    expect(rows[0].buyer).toBe('João Comprador · *********8-9');
    expect(rows[0].prescription).toBe(`notification_b SP-123456 de ${day(-2).split('-').reverse().join('/')}`);
    const [early, late] = rows.map((r) => r.id);
    expect(await problems([late])).toEqual(['earlier_pending']);
    // Inventário de 4: a segunda deixaria o lote em -1.
    expect(await check([early, late])).toEqual(expect.arrayContaining([{ movement_id: late, problem: 'negative_balance', suggested_on: null, balance: -1 }]));
    await expect(confirm([early, late])).rejects.toSatisfy(hasCode('FA864'));
    expect(await confirm([early])).toBe(1);
    // A entrada que faltava, antes da segunda venda (mesmo dia, entradas antes das saídas).
    await stockIn(b1, 'L1', 1);
    const entry = (await movements()).find((r) => r.kind === 'adjustment_in').id;
    expect(await problems([late])).toEqual(['earlier_pending', 'negative_balance']);
    await call(pharmacist, 'SELECT app.sngpc_disregard($1, $2)', [entry, 'Teste de saldo']);
    expect(await check([late])).toEqual([{ movement_id: late, problem: 'negative_balance', suggested_on: null, balance: -1 }]);
  });

  it('saída antes da entrada do lote: sugere a data; perda precisa de motivo', async () => {
    await stockIn(b1, 'L2', 3);
    const batchL2 = await batchOf(b1, 'L2');
    await call(a.admin, 'SELECT app.register_stock_loss($1::jsonb)', [JSON.stringify({
      productLookup: b1.barcode, branchId: a.branch1.id, quantity: 1, reason: 'Quebrou', batchNumber: 'L2',
    })]);
    const rows = await movements();
    const loss = rows.find((r) => r.kind === 'loss');
    expect(loss).toMatchObject({ counterpart: 'Quebrou', batch_id: batchL2, origin_batch: true });
    await expect(call(pharmacist, 'SELECT app.sngpc_disregard($1, $2)', [loss.id, 'Não'])).rejects.toSatisfy(hasCode('FA868'));
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [loss.id, JSON.stringify({ lossReason: 'sumiu' })])).rejects.toSatisfy(hasCode('FA865'));
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [loss.id, JSON.stringify({ batchId: batchL1 })])).rejects.toSatisfy(hasCode('FA865'));
    // Sem nenhuma entrada do lote na escolha nem conferida.
    expect(await problems([loss.id])).toEqual(['earlier_pending', 'missing_loss_reason', 'out_before_entry']);
    // Com a entrada do lote, mas a perda com data anterior: sugere a data da entrada.
    const entry = rows.find((r) => r.kind === 'adjustment_in' && r.batch_id === batchL2);
    await call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [loss.id, JSON.stringify({ lossReason: 'damage', reportedOn: day(-1) })]);
    const found = (await check([entry.id, loss.id])).filter((p) => p.movement_id === loss.id);
    expect(found.find((p) => p.problem === 'out_before_entry')).toMatchObject({ suggested_on: today() });
    expect(found.map((p) => p.problem)).not.toContain('missing_loss_reason');
    const transferred = await call(a.admin, 'SELECT app.transfer_stock($1::jsonb) AS id', [JSON.stringify({
      productLookup: b1.barcode, fromBranchId: a.branch1.id, toBranchId: a.branch2.id, quantity: 1, reason: 'Reposição', batchNumber: 'L2',
    })]);
    expect(transferred[0].id).toBeTruthy();
    const out = (await movements()).find((r) => r.kind === 'transfer_out');
    expect(out.counterpart).toBe(a.branch2.name);
    // A filial 2 não tem SNGPC aberto: nada entra lá.
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE branch_id = $1', [a.branch2.id])).rows[0].n).toBe(0);
  });

  it('venda liberada pendente: lote e receita na manutenção; a dispensação original não muda', async () => {
    // Produto sem estoque: a venda sai sem lote.
    const empty = await product('B2');
    const pending = sale(empty, 1, null, { id: uuidV7(), status: 'pending', pharmacist_id: pharmacist.id, pending_reason: 'Sem lote' });
    await push([['sale', pending]]);
    await stockIn(empty, 'E1', 2);
    const batchE1 = await batchOf(empty, 'E1');
    const row = (await movements()).find((r) => r.dispensing_status === 'pending');
    expect(row).toMatchObject({ batch_id: null, origin_batch: false });
    expect(await problems([row.id])).toEqual(expect.arrayContaining(['missing_batch', 'missing_prescription']));
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [row.id, JSON.stringify({ batchId: batchE1 })])).rejects.toSatisfy(hasCode('FA865'));
    await expect(call(pharmacist, 'SELECT app.sngpc_complete_sale($1, $2::jsonb)', [row.id, JSON.stringify({ batchId: batchL1 })])).rejects.toSatisfy(hasCode('FA865'));
    const data = {
      batchId: batchE1, prescriptionType: 'notification_b', prescriptionNumber: 'SP-9', prescriptionDate: day(-40),
      prescriberName: 'Dr. Carlos', prescriberCouncil: 'CRM', prescriberNumber: '999', prescriberState: 'sp',
      buyerName: 'Maria Compradora', buyerDocumentType: 'rg', buyerDocument: '99.888.777-6', buyerIssuer: 'SSP', buyerState: 'sp',
    };
    await expect(call(pharmacist, 'SELECT app.sngpc_complete_sale($1, $2::jsonb)', [row.id, JSON.stringify(data)])).rejects.toSatisfy(hasCode('FA987'));
    await expect(call(pharmacist, 'SELECT app.sngpc_complete_sale($1, $2::jsonb)', [row.id, JSON.stringify({ ...data, prescriptionDate: day(-1), prescriptionNumber: '' })]))
      .rejects.toSatisfy(hasCode('FA865'));
    await call(pharmacist, 'SELECT app.sngpc_complete_sale($1, $2::jsonb)', [row.id, JSON.stringify({ ...data, prescriptionDate: day(-1) })]);
    await call(pharmacist, 'SELECT app.sngpc_complete_sale($1, $2::jsonb)', [row.id, JSON.stringify({ ...data, prescriptionDate: day(-1), buyerName: 'Maria Correta' })]);
    const after = (await movements()).find((r) => r.id === row.id);
    expect(after).toMatchObject({ dispensing_status: 'complemented', batch_id: batchE1, buyer: 'Maria Correta · *********7-6' });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_dispensing_complement WHERE deleted_at IS NULL AND dispensing_id = (SELECT dispensing_id FROM sngpc_movement WHERE id = $1)', [row.id])).rows[0].n).toBe(1);
    expect((await ownerPool.query('SELECT status, batch_id FROM controlled_dispensing WHERE sale_id = $1', [pending.id])).rows[0]).toEqual({ status: 'pending', batch_id: null });
    expect(await problems([row.id])).not.toContain('missing_prescription');
    const complete2 = (await movements()).find((r) => r.dispensing_status === 'complete');
    await expect(call(pharmacist, 'SELECT app.sngpc_complete_sale($1, $2::jsonb)', [complete2.id, JSON.stringify(data)])).rejects.toSatisfy(hasCode('FA867'));
  });

  it('data corrigida, MS que falta e lote sem MS', async () => {
    const other = await product('C1');
    await stockIn(other, 'N1', 2, null);
    const row = (await movements()).find((r) => r.product_id === other.id);
    expect(await problems([row.id])).toEqual(expect.arrayContaining(['adjustment_in', 'missing_ms']));
    await expect(call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [row.id, JSON.stringify({ reportedOn: day(1) })])).rejects.toSatisfy(hasCode('FA866'));
    await call(pharmacist, 'SELECT app.sngpc_update_movement($1, $2::jsonb)', [row.id, JSON.stringify({ reportedOn: day(-3) })]);
    const found = await check([row.id]);
    expect(found.find((p) => p.problem === 'date_before_start')).toMatchObject({ suggested_on: today() });
    await expect(call(pharmacist, 'SELECT app.sngpc_confirm($1, $2::uuid[], $3::date)', [a.branch1.id, [uuidV7()], today()])).rejects.toSatisfy(hasCode('FA865'));
    await expect(call(pharmacist, 'SELECT app.sngpc_confirm($1, $2::uuid[], $3::date)', [a.branch1.id, [], today()])).rejects.toSatisfy(hasCode('FA865'));
  });
});
