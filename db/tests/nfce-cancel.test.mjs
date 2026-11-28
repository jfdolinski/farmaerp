import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// 8A-3a: cancelamento da NFC-e com a venda (até 30 minutos), reenvio pela central em lotes de
// 30 por hora com aviso da recusada, buracos de numeração e inutilização. A Sefaz fica na API;
// aqui entram os resultados que ela devolveria.

let a;
let b;
let operator;
let product;
let session;
let series;
let series2;
let clockMs = Date.now();
let sequence = 0;
let saleNumber = randomInt(1000, 900000);

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
const key = () => Array.from({ length: 44 }, () => randomInt(10)).join('');
const XML = `<nfeProc versao="4.00">${'x'.repeat(200)}</nfeProc>`;
const EVENT_XML = `<procEventoNFe versao="1.00">${'e'.repeat(200)}</procEventoNFe>`;
const minutesAgo = (minutes) => new Date(Date.now() - minutes * 60_000).toISOString();

async function run(setup, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setup(client);
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
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);
const asWorker = (sql, params) => run((c) => c.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'fiscal', true)"), sql, params);
async function push(terminal, kind, payload) {
  sequence += 1;
  const rows = await run((c) => setTerminal(c, terminal.id), 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
    { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind, payload },
  ])]);
  return rows[0].r.results[0];
}
async function newSale({ terminal = a.terminal1, cashSession = session, quantity = 2 } = {}) {
  saleNumber += 1;
  const id = uuidV7();
  const itemId = uuidV7();
  const result = await push(terminal, 'sale', {
    id, number: saleNumber, cash_session_id: cashSession, operator_id: operator.id, customer_id: null,
    sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: itemId, line: 1, product_id: product, barcode_id: null, quantity, unit_price: 10, discount: 0, total: 10 * quantity, batch_id: null, release: null }],
    payments: [{ id: uuidV7(), method: 'cash', amount: 10 * quantity, change: 0 }], subtotal: 10 * quantity, discount_total: 0, total: 10 * quantity,
  });
  expect(result.status).toBe('applied');
  return { id, itemId };
}
async function document(saleId, overrides = {}, terminal = a.terminal1, docSeries = series) {
  const doc = {
    id: uuidV7(), sale_id: saleId, series: docSeries.series, number: randomInt(1000, 999999), access_key: key(), environment: 2, emission_type: 1,
    status: 'authorized', protocol: String(randomInt(1e9, 9e9)).padEnd(15, '0'), status_code: '100', reason: 'Autorizado o uso da NF-e',
    xml: XML, emitted_at: new Date().toISOString(), authorized_at: new Date().toISOString(), ...overrides,
  };
  expect((await push(terminal, 'nfce', doc)).status).toBe('applied');
  return doc;
}
const balance = async () => Number((await ownerPool.query(
  'SELECT COALESCE(sum(quantity), 0) AS q FROM stock_balance WHERE product_id = $1 AND branch_id = $2 AND deleted_at IS NULL', [product, a.branch1.id],
)).rows[0].q);
const cancelEvent = (overrides = {}) => JSON.stringify({
  reason: 'Cliente desistiu da compra no caixa', protocol: '135260000000888', status_code: '135', xml: EVENT_XML,
  registered_at: new Date().toISOString(), ...overrides,
});

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const roleOf = async (name) => (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, name])).rows[0].id;
  const { rows: [user] } = await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Operador ${randomInt(1e6)}`]);
  for (const branch of [a.branch1, a.branch2]) {
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, await roleOf('Gerente'), branch.id]);
  }
  operator = user;
  product = (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto cancelamento ${randomInt(1e6)}`, barcode: gtin() })]))[0].id;
  await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 10, NULL)', [product]);
  await ownerPool.query(
    "INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, reason) VALUES ($1, $2, $3, 'adjustment', 100, 'teste')",
    [a.group.id, a.branch1.id, product],
  );
  session = uuidV7();
  expect((await push(a.terminal1, 'cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
  series = (await ownerPool.query("SELECT * FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [a.terminal1.id])).rows[0];
  series2 = (await ownerPool.query("SELECT * FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [a.terminal2.id])).rows[0];
});
afterAll(closePools);

describe('cancelamento da NFC-e com a venda', () => {
  it('só a autorizada, até 30 minutos, por quem tem a permissão', async () => {
    const { id } = await newSale();
    const doc = await document(id);
    const [context] = await asUser(a.admin, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [doc.id]);
    expect(context).toMatchObject({ access_key: doc.access_key, protocol: doc.protocol, branch_id: a.branch1.id });
    await expect(asUser(a.oneBranchUser, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [doc.id])).rejects.toSatisfy(hasCode('FA006'));
    await expect(asUser(b.admin, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [doc.id])).rejects.toSatisfy(hasCode('FA006'));
    // Operador sem fiscal.cancel não cancela, mas consulta.
    await expect(asUser(operator, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [doc.id])).rejects.toSatisfy(hasCode('FA006'));
    expect(await asUser(operator, "SELECT id FROM app.fiscal_action_context($1, 'consult')", [doc.id])).toHaveLength(1);
    await expect(asUser(a.admin, "SELECT * FROM app.fiscal_action_context($1, 'apagar')", [doc.id])).rejects.toSatisfy(hasCode('FA005'));

    const late = await newSale();
    const lateDoc = await document(late.id, { authorized_at: minutesAgo(31), emitted_at: minutesAgo(32) });
    await expect(asUser(a.admin, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [lateDoc.id])).rejects.toSatisfy(hasCode('FA748'));
    const pending = await newSale();
    const pendingDoc = await document(pending.id, { status: 'contingency', emission_type: 9, protocol: null, authorized_at: null, status_code: null, reason: null });
    await expect(asUser(a.admin, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [pendingDoc.id])).rejects.toSatisfy(hasCode('FA753'));
  });

  it('venda com devolução não cancela', async () => {
    const sold = await newSale();
    const doc = await document(sold.id);
    expect((await push(a.terminal1, 'sale_return', {
      id: uuidV7(), number: randomInt(1, 1e6), cash_session_id: session, sale_id: sold.id, operator_id: operator.id, authorized_by: null,
      reason: 'Troca', destination: 'cash', returned_at: new Date().toISOString(),
      items: [{ id: uuidV7(), sale_item_id: sold.itemId, quantity: 1, amount: 10 }], total: 10,
    })).status).toBe('applied');
    await expect(asUser(a.admin, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [doc.id])).rejects.toSatisfy(hasCode('FA749'));
    // Cancelada na Sefaz por fora (vista na consulta): a nota fica cancelada, mas a venda não é
    // desfeita (o estoque não volta duas vezes) e fica o aviso.
    const before = await balance();
    expect((await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r).toEqual({ sale_kept: 'FA749' });
    expect(await balance()).toBe(before);
    expect((await ownerPool.query('SELECT deleted_at FROM sale WHERE id = $1', [sold.id])).rows[0].deleted_at).toBeNull();
    const [alert] = await asUser(a.admin, 'SELECT * FROM app.list_fiscal_documents(NULL, NULL, NULL, NULL, true) WHERE id = $1', [doc.id]);
    expect(alert).toMatchObject({ status: 'canceled', alert: true, cancel_note: expect.stringContaining('venda não foi desfeita (FA749)') });
  });

  it('cancelada por fora depois do prazo: a venda fica e vira aviso', async () => {
    const before = await balance();
    const { id } = await newSale({ quantity: 1 });
    const doc = await document(id, { authorized_at: minutesAgo(40), emitted_at: minutesAgo(41) });
    expect((await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r).toEqual({ sale_kept: 'FA748' });
    expect(await balance()).toBe(before - 1);
    expect((await ownerPool.query('SELECT status, cancel_note FROM fiscal_document WHERE id = $1', [doc.id])).rows[0])
      .toMatchObject({ status: 'canceled', cancel_note: expect.stringContaining('FA748') });
  });

  it('cancela: evento guardado, nota e venda canceladas, estoque de volta, pagamento fora do caixa', async () => {
    const before = await balance();
    const { id } = await newSale({ quantity: 3 });
    expect(await balance()).toBe(before - 3);
    const doc = await document(id);
    const effects = (await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r;
    expect(effects).toEqual({ cash: 30, cash_refund: 'same_session' });
    expect(await balance()).toBe(before);
    const reversal = (await ownerPool.query('SELECT movement_type, quantity, reversal_of FROM stock_movement WHERE canceled_sale_id = $1', [id])).rows;
    expect(reversal.map((r) => [r.movement_type, Number(r.quantity), r.reversal_of !== null])).toEqual([['sale', 3, true]]);
    const sale = (await ownerPool.query('SELECT * FROM sale WHERE id = $1', [id])).rows[0];
    expect(sale.canceled_at).not.toBeNull();
    expect(sale.deleted_at).not.toBeNull();
    expect([sale.cancel_reason, sale.canceled_by, sale.fiscal_status]).toEqual(['Cliente desistiu da compra no caixa', a.admin.id, 'canceled']);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sale_payment WHERE sale_id = $1 AND deleted_at IS NULL', [id])).rows[0].n).toBe(0);
    const event = (await ownerPool.query('SELECT * FROM fiscal_event WHERE fiscal_document_id = $1', [doc.id])).rows[0];
    expect(event).toMatchObject({ kind: 'cancellation', protocol: '135260000000888', status_code: '135', requested_by: a.admin.id, xml: EVENT_XML });
    expect((await ownerPool.query('SELECT status FROM fiscal_document WHERE id = $1', [doc.id])).rows[0].status).toBe('canceled');
    // Fora da lista de vendas; o XML do cancelamento junto com a nota.
    expect((await asUser(a.admin, 'SELECT id FROM app.list_sales($1, NULL, NULL)', [a.branch1.id])).map((r) => r.id)).not.toContain(id);
    const files = (await asUser(a.admin, 'SELECT app.fiscal_document_files($1) AS f', [doc.id]))[0].f;
    expect(files).toMatchObject({ status: 'canceled', xml: XML, cancellation: { protocol: '135260000000888', xml: EVENT_XML } });
    // De novo: nada muda.
    expect((await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r).toEqual({ already: true });
    expect(await balance()).toBe(before);
    // O caixa mandando a nota de novo não muda nada nem trava a fila.
    expect((await push(a.terminal1, 'nfce', { ...doc, status: 'authorized' })).status).toBe('applied');
    expect((await ownerPool.query('SELECT status FROM fiscal_document WHERE id = $1', [doc.id])).rows[0].status).toBe('canceled');
  });

  it('turno da venda já fechado: a devolução do dinheiro sai do turno aberto do terminal', async () => {
    const old = uuidV7();
    expect((await push(a.terminal2, 'cash_session_open', { id: old, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
    const { id } = await newSale({ terminal: a.terminal2, cashSession: old, quantity: 1 });
    const doc = await document(id, {}, a.terminal2, series2);
    await ownerPool.query("UPDATE cash_session SET status = 'closed', closed_at = now(), closed_by = $2 WHERE id = $1", [old, operator.id]);
    // Sem turno aberto: fica avisado.
    expect((await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r)
      .toEqual({ cash: 10, cash_refund: 'no_session' });
    const open = uuidV7();
    expect((await push(a.terminal2, 'cash_session_open', { id: open, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
    const another = await newSale({ terminal: a.terminal2, cashSession: open, quantity: 1 });
    const anotherDoc = await document(another.id, {}, a.terminal2, series2);
    await ownerPool.query("UPDATE cash_session SET status = 'closed', closed_at = now(), closed_by = $2 WHERE id = $1", [open, operator.id]);
    const fresh = uuidV7();
    expect((await push(a.terminal2, 'cash_session_open', { id: fresh, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
    expect((await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [anotherDoc.id, cancelEvent()]))[0].r)
      .toEqual({ cash: 10, cash_refund: 'open_session' });
    const movement = (await ownerPool.query('SELECT * FROM cash_movement WHERE canceled_sale_id = $1', [another.id])).rows[0];
    expect(movement).toMatchObject({ cash_session_id: fresh, kind: 'withdrawal', operator_id: a.admin.id });
    expect(Number(movement.amount)).toBe(10);
    // A venda foi desfeita também nesse caso.
    expect((await ownerPool.query('SELECT canceled_at IS NOT NULL AS c, deleted_at IS NOT NULL AS d FROM sale WHERE id = $1', [another.id])).rows[0]).toEqual({ c: true, d: true });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sale_payment WHERE sale_id = $1 AND deleted_at IS NULL', [another.id])).rows[0].n).toBe(0);
  });
});

describe('reenvio pela central', () => {
  const contingency = (hoursAgo) => ({
    status: 'contingency', emission_type: 9, protocol: null, authorized_at: null, status_code: null, reason: null,
    emitted_at: new Date(Date.now() - hoursAgo * 3_600_000).toISOString(),
  });
  let stuck = [];

  it('lote de até 30 notas que passaram da metade do prazo; a nota sai marcada; um lote por hora', async () => {
    for (let i = 0; i < 32; i += 1) stuck.push(await document((await newSale({ quantity: 1 })).id, contingency(13)));
    const recent = await document((await newSale({ quantity: 1 })).id, contingency(1));
    const picked = (await asWorker('SELECT * FROM app.claim_fiscal_resend(100) AS id')).map((r) => r.id);
    expect(picked).toHaveLength(30);
    expect(picked).not.toContain(recent.id);
    const marked = (await ownerPool.query('SELECT count(*)::int AS n FROM fiscal_document WHERE id = ANY ($1) AND resend_attempted_at IS NOT NULL', [picked])).rows[0].n;
    expect(marked).toBe(30);
    // Na mesma hora, nada mais para o grupo.
    expect(await asWorker('SELECT * FROM app.claim_fiscal_resend(30) AS id')).toEqual([]);
    // Só a rotina reserva.
    await expect(asUser(a.admin, 'SELECT * FROM app.claim_fiscal_resend(30)')).rejects.toSatisfy(hasCode('FA002'));
    stuck = picked;
  });

  it('autorizada fica autorizada; recusada vira aviso e não volta; sem Sefaz tenta na próxima hora', async () => {
    const [ok, refused, down] = stuck;
    await asWorker("SELECT app.fiscal_resend_result_checked($1, $2::jsonb)", [ok, JSON.stringify({
      kind: 'authorized', protocol: '135260000000555', authorized_at: new Date().toISOString(), xml: XML, status_code: '100', reason: 'Autorizado',
    })]);
    await asWorker('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [refused, JSON.stringify({ kind: 'rejected', status_code: '778', reason: 'NCM inexistente' })]);
    await asWorker('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [down, JSON.stringify({ kind: 'unavailable', reason: 'Sem conexão' })]);
    const rows = Object.fromEntries((await ownerPool.query('SELECT id, status, resend_status, resend_message FROM fiscal_document WHERE id = ANY ($1)', [[ok, refused, down]])).rows.map((r) => [r.id, r]));
    expect(rows[ok]).toMatchObject({ status: 'authorized', resend_status: 'authorized' });
    expect(rows[refused]).toMatchObject({ status: 'rejected', resend_status: 'refused', resend_message: '778 NCM inexistente' });
    expect(rows[down]).toMatchObject({ status: 'contingency', resend_status: 'unavailable' });
    const alerts = await asUser(a.admin, 'SELECT id, alert FROM app.list_fiscal_documents(NULL, NULL, NULL, NULL, true)');
    expect(alerts.map((r) => r.id).filter((id) => [ok, refused, down].includes(id))).toEqual([refused]);
    // Uma hora depois: as duas que não foram tentadas e a que ficou sem Sefaz; a recusada e a autorizada não.
    await ownerPool.query("UPDATE fiscal_document SET resend_attempted_at = resend_attempted_at - interval '2 hours' WHERE economic_group_id = $1 AND resend_attempted_at IS NOT NULL", [a.group.id]);
    const next = (await asWorker('SELECT * FROM app.claim_fiscal_resend(30) AS id')).map((r) => r.id);
    expect(next).toContain(down);
    expect(next).not.toContain(refused);
    expect(next).not.toContain(ok);
    expect(next).toHaveLength(3);
    // Aviso visto sai do painel.
    await asUser(a.admin, 'SELECT app.dismiss_fiscal_alert($1)', [refused]);
    expect((await asUser(a.admin, 'SELECT id FROM app.list_fiscal_documents(NULL, NULL, NULL, NULL, true)')).map((r) => r.id)).not.toContain(refused);
    // O botão (fiscal.void) pode reenviar a recusada; o operador não.
    expect(await asUser(a.admin, "SELECT id FROM app.fiscal_action_context($1, 'resend')", [refused])).toHaveLength(1);
    await expect(asUser(operator, "SELECT id FROM app.fiscal_action_context($1, 'resend')", [refused])).rejects.toSatisfy(hasCode('FA006'));
    await expect(asUser(a.admin, "SELECT id FROM app.fiscal_action_context($1, 'resend')", [ok])).rejects.toSatisfy(hasCode('FA753'));
    // Resultado repetido de nota já autorizada não muda nada.
    expect((await asWorker('SELECT app.fiscal_resend_result_checked($1, $2::jsonb) AS r', [ok, JSON.stringify({ kind: 'rejected', status_code: '999', reason: 'x' })]))[0].r).toBe('authorized');
  });
});

describe('inutilização', () => {
  it('buracos por série (inclui rejeitadas), faixa conferida, registrada some da lista', async () => {
    const terminal = (await ownerPool.query(
      "INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', 'active', $3) RETURNING *",
      [a.branch2.id, `Caixa inutilização ${randomInt(1e6)}`, `chave-${uuidV7()}`],
    )).rows[0];
    const ownSeries = (await ownerPool.query("SELECT * FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [terminal.id])).rows[0];
    series2 = ownSeries;
    const terminalSession = uuidV7();
    expect((await push(terminal, 'cash_session_open', { id: terminalSession, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
    const make = async (number, overrides = {}) =>
      document((await newSale({ terminal, cashSession: terminalSession, quantity: 1 })).id, { number, ...overrides }, terminal, ownSeries);
    const base = 1000;
    await make(base);
    await make(base + 2);
    await make(base + 3, { status: 'rejected', protocol: null, authorized_at: null, status_code: '778', reason: 'Rejeição' });
    await make(base + 6);
    const gaps = (await asUser(a.admin, 'SELECT * FROM app.fiscal_number_gaps($1)', [a.branch2.id]))
      .filter((g) => g.series === series2.series && Number(g.first_number) >= base);
    expect(gaps.map((g) => [Number(g.first_number) - base, Number(g.last_number) - base, Number(g.quantity), g.rejected])).toEqual([[1, 1, 1, 0], [3, 5, 3, 1]]);
    expect(gaps[0]).toMatchObject({ terminal_id: terminal.id, branch_name: a.branch2.name, safe: false });
    const updated = await ownerPool.query('UPDATE terminal_status SET outbox_pending = 0 WHERE terminal_id = $1', [terminal.id]);
    if (updated.rowCount === 0) await ownerPool.query('INSERT INTO terminal_status (terminal_id, last_seen_at, outbox_pending) VALUES ($1, now(), 0)', [terminal.id]);

    // A faixa não pode ter nota válida; outro grupo e quem não tem a permissão não inutilizam.
    await expect(asUser(a.admin, 'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, base + 1, base + 2])).rejects.toSatisfy(hasCode('FA755'));
    await expect(asUser(operator, 'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, base + 1, base + 1])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(b.admin, 'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, base + 1, base + 1])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.admin, 'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, base + 5, base + 3])).rejects.toSatisfy(hasCode('FA755'));
    const [context] = await asUser(a.admin, 'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, base + 3, base + 5]);
    expect(context).toMatchObject({ branch_id: a.branch2.id, environment: 2 });

    await asUser(a.admin, 'SELECT app.fiscal_void_register($1, $2, $3, $4, $5, $6::jsonb)', [
      a.branch2.id, series2.series, base + 3, base + 5, 'Numeracao pulada no caixa 2',
      JSON.stringify({ protocol: '135260000000999', xml: `<ProcInutNFe>${'v'.repeat(200)}</ProcInutNFe>`, voided_at: new Date().toISOString(), environment: 2 }),
    ]);
    const after = (await asUser(a.admin, 'SELECT * FROM app.fiscal_number_gaps($1)', [a.branch2.id]))
      .filter((g) => g.series === series2.series && Number(g.first_number) >= base);
    expect(after.map((g) => [Number(g.first_number) - base, g.safe])).toEqual([[1, true]]);
    // Não inutiliza de novo a mesma faixa.
    await expect(asUser(a.admin, 'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, base + 4, base + 4])).rejects.toSatisfy(hasCode('FA755'));
    const voids = await asUser(a.admin, 'SELECT * FROM app.list_fiscal_voids($1)', [a.branch2.id]);
    expect(voids[0]).toMatchObject({ series: series2.series, protocol: '135260000000999', requested_by_name: a.admin.name });
    expect(await asUser(b.admin, 'SELECT * FROM app.list_fiscal_voids($1)', [a.branch2.id])).toEqual([]);
  });
});

describe('inutilização desativada pela UF (NT 2023.002)', () => {
  // Numa transação desfeita no fim: a UF da filial muda só aqui.
  async function withState(state, fn) {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query('UPDATE branch SET state = $1 WHERE id = $2', [state, a.branch2.id]);
      await setUser(client, a.admin.id);
      return await fn(client);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  }
  const gapsOf = (client) => client.query('SELECT * FROM app.fiscal_number_gaps($1)', [a.branch2.id])
    .then((r) => r.rows.filter((g) => g.series === series2.series && Number(g.first_number) >= 1000));
  const context = (client) => client.query('SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [a.branch2.id, series2.series, 1001, 1001]);

  it('AC, BA e SP: o buraco aparece só para registro e a inutilização é recusada antes da Sefaz; as outras UFs seguem', async () => {
    for (const state of ['SP', 'BA', 'AC']) {
      await withState(state, async (client) => {
        const gaps = await gapsOf(client);
        expect(gaps.length, state).toBeGreaterThan(0);
        expect(gaps.every((g) => g.voiding_available === false), state).toBe(true);
        await expect(context(client), state).rejects.toSatisfy(hasCode('FA788'));
      });
    }
    for (const state of ['RS', 'PR']) {
      await withState(state, async (client) => {
        expect((await gapsOf(client)).every((g) => g.voiding_available === true), state).toBe(true);
        expect((await context(client)).rows[0], state).toMatchObject({ branch_id: a.branch2.id, state });
      });
    }
    // Sem a permissão continua FA002 (a permissão vem antes da UF).
    await withState('SP', async (client) => {
      await setUser(client, operator.id);
      await expect(context(client)).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('correções do reenvio e conferência no banco (0068)', () => {
  const stale = (hoursAgo) => ({
    status: 'contingency', emission_type: 9, protocol: null, authorized_at: null, status_code: null, reason: null,
    emitted_at: new Date(Date.now() - hoursAgo * 3_600_000).toISOString(),
  });
  // Libera o grupo para um novo lote (como se a hora tivesse passado).
  const nextHour = () => ownerPool.query(
    "UPDATE fiscal_document SET resend_attempted_at = resend_attempted_at - interval '2 hours' WHERE economic_group_id = $1 AND resend_attempted_at IS NOT NULL", [a.group.id],
  );

  it('nunca tentadas vêm antes; falha que não se resolve vira aviso e sai do lote; seis rodadas sem Sefaz também', async () => {
    await nextHour();
    // Tudo o que sobrou dos outros testes sai do caminho.
    await ownerPool.query("UPDATE fiscal_document SET resend_status = 'refused', alert_dismissed_at = now() WHERE economic_group_id = $1 AND status IN ('pending', 'contingency')", [a.group.id]);
    const old = await document((await newSale({ quantity: 1 })).id, stale(30));
    await ownerPool.query("UPDATE fiscal_document SET resend_attempted_at = now() - interval '3 hours', resend_status = 'unavailable', resend_attempts = 1 WHERE id = $1", [old.id]);
    const fresh = await document((await newSale({ quantity: 1 })).id, stale(13));
    const [first] = (await asWorker('SELECT * FROM app.claim_fiscal_resend(1) AS id')).map((r) => r.id);
    expect(first).toBe(fresh.id);
    expect((await ownerPool.query('SELECT resend_attempts FROM fiscal_document WHERE id = $1', [fresh.id])).rows[0].resend_attempts).toBe(1);

    // Sem certificado (falha que não se resolve sozinha): aviso, a nota continua em contingência e não volta.
    await asWorker('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [fresh.id, JSON.stringify({ kind: 'blocked', reason: 'A filial não tem certificado digital válido. (FA943)' })]);
    expect((await ownerPool.query('SELECT status, resend_status, resend_message FROM fiscal_document WHERE id = $1', [fresh.id])).rows[0])
      .toEqual({ status: 'contingency', resend_status: 'refused', resend_message: 'A filial não tem certificado digital válido. (FA943)' });
    const alerts = (await asUser(a.admin, 'SELECT id FROM app.list_fiscal_documents(NULL, NULL, NULL, NULL, true)')).map((r) => r.id);
    expect(alerts).toContain(fresh.id);
    const [row] = await asUser(a.admin, 'SELECT alert FROM app.list_fiscal_documents() WHERE id = $1', [fresh.id]);
    expect(row.alert).toBe(true);
    await nextHour();
    expect((await asWorker('SELECT * FROM app.claim_fiscal_resend(30) AS id')).map((r) => r.id)).toEqual([old.id]);

    // Na sexta rodada sem Sefaz, vira aviso.
    await ownerPool.query('UPDATE fiscal_document SET resend_attempts = 5 WHERE id = $1', [old.id]);
    await asWorker('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [old.id, JSON.stringify({ kind: 'unavailable', reason: 'Sem resposta da Sefaz.' })]);
    expect((await ownerPool.query('SELECT resend_status FROM fiscal_document WHERE id = $1', [old.id])).rows[0].resend_status).toBe('unavailable');
    await ownerPool.query('UPDATE fiscal_document SET resend_attempts = 6 WHERE id = $1', [old.id]);
    await asWorker('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [old.id, JSON.stringify({ kind: 'unavailable', reason: 'Sem resposta da Sefaz.' })]);
    expect((await ownerPool.query('SELECT status, resend_status FROM fiscal_document WHERE id = $1', [old.id])).rows[0]).toEqual({ status: 'contingency', resend_status: 'refused' });
    await nextHour();
    expect(await asWorker('SELECT * FROM app.claim_fiscal_resend(30) AS id')).toEqual([]);
  });

  it('o resultado e o cancelamento conferem quem pede', async () => {
    const pending = await document((await newSale({ quantity: 1 })).id, stale(1));
    const ok = JSON.stringify({ kind: 'authorized', protocol: '135260000000321', authorized_at: new Date().toISOString(), xml: XML, status_code: '100', reason: 'ok' });
    // Outro grupo e quem não pode reenviar não gravam resultado.
    await expect(asUser(b.admin, 'SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [pending.id, ok])).rejects.toSatisfy(hasCode('FA006'));
    await expect(asUser(operator, 'SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [pending.id, ok])).rejects.toSatisfy(hasCode('FA006'));
    // O núcleo não fica exposto.
    await expect(asUser(a.admin, 'SELECT app.fiscal_apply_result($1, $2::jsonb)', [pending.id, ok])).rejects.toMatchObject({ code: '42501' });
    await expect(asUser(a.admin, "SELECT app.fiscal_cancel_apply($1, $2::jsonb, 'sales.view')", [pending.id, cancelEvent()])).rejects.toMatchObject({ code: '42501' });
    expect((await asUser(a.admin, 'SELECT app.fiscal_resend_result_checked($1, $2::jsonb) AS r', [pending.id, ok]))[0].r).toBe('authorized');
    // Quem só consulta grava a consulta, mas não registra cancelamento pela entrada da tela.
    const sold = await newSale({ quantity: 1 });
    const doc = await document(sold.id);
    await expect(asUser(operator, 'SELECT app.fiscal_cancel_register($1, $2::jsonb)', [doc.id, cancelEvent()])).rejects.toSatisfy(hasCode('FA006'));
    expect((await asUser(operator, 'SELECT app.fiscal_consult_canceled($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r).toMatchObject({ cash_refund: 'same_session' });
    expect((await ownerPool.query('SELECT status FROM fiscal_document WHERE id = $1', [doc.id])).rows[0].status).toBe('canceled');
  });
});

describe('cancelamento pedido pelo caixa (0069)', () => {
  const asTerminal = (terminal, sql, params) => run((c) => setTerminal(c, terminal.id), sql, params);

  it('nota do próprio caixa, supervisor com a permissão, no prazo e sem bloqueio', async () => {
    const { id } = await newSale({ quantity: 1 });
    const doc = await document(id);
    // O operador (Gerente) não tem fiscal.cancel; o administrador tem.
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [doc.id, operator.id])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [doc.id, b.admin.id])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, NULL)', [doc.id])).rejects.toSatisfy(hasCode('FA002'));
    // Nota de outro caixa não é vista.
    await expect(asTerminal(a.terminal2, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [doc.id, a.admin.id])).rejects.toSatisfy(hasCode('FA006'));
    const [context] = await asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [doc.id, a.admin.id]);
    expect(context).toMatchObject({ status: 'authorized', access_key: doc.access_key, protocol: doc.protocol });

    const late = await document((await newSale({ quantity: 1 })).id, { authorized_at: minutesAgo(31), emitted_at: minutesAgo(32) });
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [late.id, a.admin.id])).rejects.toSatisfy(hasCode('FA748'));
    const loose = await document((await newSale({ quantity: 1 })).id, { status: 'contingency', emission_type: 9, protocol: null, authorized_at: null, status_code: null, reason: null });
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [loose.id, a.admin.id])).rejects.toSatisfy(hasCode('FA753'));
  });

  it('registra com o terminal e o supervisor, desfaz a venda; repetido responde que já está feito', async () => {
    const before = await balance();
    const { id } = await newSale({ quantity: 2 });
    const doc = await document(id);
    await expect(asTerminal(a.terminal1, 'SELECT app.terminal_cancel_register($1, $2, $3::jsonb)', [doc.id, operator.id, cancelEvent()])).rejects.toSatisfy(hasCode('FA002'));
    const effects = (await asTerminal(a.terminal1, 'SELECT app.terminal_cancel_register($1, $2, $3::jsonb) AS r', [doc.id, a.admin.id, cancelEvent()]))[0].r;
    expect(effects).toEqual({ cash: 20, cash_refund: 'same_session' });
    expect(await balance()).toBe(before);
    const event = (await ownerPool.query('SELECT requested_by, terminal_id FROM fiscal_event WHERE fiscal_document_id = $1', [doc.id])).rows[0];
    expect(event).toEqual({ requested_by: a.admin.id, terminal_id: a.terminal1.id });
    expect((await ownerPool.query('SELECT canceled_by FROM sale WHERE id = $1', [id])).rows[0].canceled_by).toBe(a.admin.id);
    expect((await asTerminal(a.terminal1, 'SELECT app.terminal_cancel_register($1, $2, $3::jsonb) AS r', [doc.id, a.admin.id, cancelEvent()]))[0].r).toEqual({ already: true });
    const [again] = await asTerminal(a.terminal1, 'SELECT status FROM app.terminal_cancel_context($1, $2)', [doc.id, a.admin.id]);
    expect(again.status).toBe('canceled');
    expect(await balance()).toBe(before);
  });

  it('venda com bloqueio: a nota fica cancelada e a venda não é desfeita (aviso)', async () => {
    const sold = await newSale({ quantity: 1 });
    const doc = await document(sold.id);
    expect((await push(a.terminal1, 'sale_return', {
      id: uuidV7(), number: randomInt(1, 1e6), cash_session_id: session, sale_id: sold.id, operator_id: operator.id, authorized_by: null,
      reason: 'Troca', destination: 'cash', returned_at: new Date().toISOString(),
      items: [{ id: uuidV7(), sale_item_id: sold.itemId, quantity: 1, amount: 10 }], total: 10,
    })).status).toBe('applied');
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [doc.id, a.admin.id])).rejects.toSatisfy(hasCode('FA749'));
    expect((await asTerminal(a.terminal1, 'SELECT app.terminal_cancel_register($1, $2, $3::jsonb) AS r', [doc.id, a.admin.id, cancelEvent()]))[0].r).toEqual({ sale_kept: 'FA749' });
    expect((await ownerPool.query('SELECT deleted_at FROM sale WHERE id = $1', [sold.id])).rows[0].deleted_at).toBeNull();
  });
});
