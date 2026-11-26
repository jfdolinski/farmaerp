import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// 8A-3a: efeitos do cancelamento da venda junto com a NFC-e (app.cancel_sale_effects) e o que
// impede desfazer a venda (app.sale_cancel_blocker): cashback ganho e usado, crediário, convênio
// faturado, controlado no SNGPC e orçamento convertido.

let a;
let b;
let operator;
let pharmacist;
let clerk;
let product;
let session;
let series;
const tag = () => randomBytes(4).toString('hex');
let clockMs = Date.now();
let sequence = 0;
let saleNumber = randomInt(1000, 900000);
let quoteNumber = randomInt(1000, 900000);

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
const key = () => Array.from({ length: 44 }, () => randomInt(10)).join('');
const XML = `<nfeProc versao="4.00">${'x'.repeat(200)}</nfeProc>`;
const EVENT_XML = `<procEventoNFe versao="1.00">${'e'.repeat(200)}</procEventoNFe>`;
const spDay = (offset = 0) => new Date(Date.now() + offset * 86400000).toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });

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
const asTerminal = (sql, params, terminal = a.terminal1) => run((c) => setTerminal(c, terminal.id), sql, params);
async function push(kind, payload, terminal = a.terminal1) {
  sequence += 1;
  const rows = await asTerminal('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
    { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind, payload },
  ])], terminal);
  return rows[0].r.results[0];
}

/** Venda de um item vinda do PDV; por padrão R$ 10 em dinheiro, sem cliente. */
async function newSale({ customerId = null, item = product, quantity = 1, unitPrice = 10, payments = null, extra = {}, itemExtra = {} } = {}) {
  saleNumber += 1;
  const total = Math.round(quantity * unitPrice * 100) / 100;
  const payload = {
    id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId,
    sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: item, barcode_id: null, quantity, unit_price: unitPrice, discount: 0, total, batch_id: null, ...itemExtra }],
    payments: payments ?? [{ id: uuidV7(), method: 'cash', amount: total, change: 0 }],
    subtotal: total, discount_total: 0, total, ...extra,
  };
  const result = await push('sale', payload);
  expect([result.status, result.code]).toEqual(['applied', null]);
  return payload;
}
/** NFC-e autorizada agora para a venda, mandada pelo caixa. */
async function document(saleId) {
  const doc = {
    id: uuidV7(), sale_id: saleId, series: series.series, number: randomInt(1000, 999999), access_key: key(), environment: 2, emission_type: 1,
    status: 'authorized', protocol: String(randomInt(1e9, 9e9)).padEnd(15, '0'), status_code: '100', reason: 'Autorizado o uso da NF-e',
    xml: XML, emitted_at: new Date().toISOString(), authorized_at: new Date().toISOString(),
  };
  expect((await push('nfce', doc)).status).toBe('applied');
  return doc;
}
const context = (doc, user = a.admin) => asUser(user, "SELECT * FROM app.fiscal_action_context($1, 'cancel')", [doc.id]);
const cancelEvent = () => JSON.stringify({
  reason: 'Cliente desistiu da compra no caixa', protocol: '135260000000777', status_code: '135', xml: EVENT_XML,
  registered_at: new Date().toISOString(),
});
/** Cancela a NFC-e da venda como a API faria: confere o contexto e registra o evento. */
async function cancel(doc) {
  expect(await context(doc)).toHaveLength(1);
  return (await asUser(a.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [doc.id, cancelEvent()]))[0].r;
}
const saleRow = async (id) => (await ownerPool.query('SELECT * FROM sale WHERE id = $1', [id])).rows[0];

const newCustomer = async (consent = false) => {
  const id = (await asUser(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
    personType: 'individual', document: cpf(), name: `Cliente cancelamento ${tag()}`,
  })]))[0].id;
  if (consent) await asUser(a.admin, "SELECT app.record_customer_consent($1, 'cashback', true, 'store')", [id]);
  return id;
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const roleOf = async (name) => (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, name])).rows[0].id;
  const person = async (roleName) => {
    const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, await roleOf(roleName), a.branch1.id]);
    return user;
  };
  operator = await person('Gerente');
  pharmacist = await person('Farmacêutico');
  clerk = await person('Balconista');
  const barcode = gtin();
  product = (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto efeitos ${tag()}`, barcode })]))[0].id;
  await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 10, NULL)', [product]);
  await asUser(a.admin, 'SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: barcode, branchId: a.branch1.id, direction: 'in', quantity: 1000, reason: 'Teste do cancelamento',
  })]);
  // Cashback de 5% neste produto (só cliente com consentimento ganha); sem carência.
  await asUser(a.admin, 'SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({
    typeCode: 'cashback', value: 5, level: 'product', productLookup: barcode,
  })]);
  await asUser(a.admin, 'SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify({ waiting_days: 0 })]);
  session = uuidV7();
  expect((await push('cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
  series = (await ownerPool.query("SELECT * FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65' AND deleted_at IS NULL", [a.terminal1.id])).rows[0];
});
afterAll(closePools);

describe('cashback', () => {
  const balance = async (customerId) => (await ownerPool.query('SELECT app.cashback_balance($1) AS b', [customerId])).rows[0].b.available;
  const reserve = async (customerId, amount, total) =>
    (await asTerminal('SELECT app.pdv_cashback_reserve($1, $2, $3) AS r', [customerId, amount, total]))[0].r;

  it('ganho na venda: estorno do lote e o saldo volta ao de antes da venda', async () => {
    const customerId = await newCustomer(true);
    await newSale({ customerId, unitPrice: 100 });
    const before = await balance(customerId);
    expect(before).toBe(5);
    const sold = await newSale({ customerId, unitPrice: 40 });
    const lot = (await ownerPool.query("SELECT id, amount::float AS amount FROM cashback_entry WHERE sale_id = $1 AND kind = 'earn'", [sold.id])).rows[0];
    expect(lot.amount).toBe(2);
    expect(await balance(customerId)).toBe(7);

    await cancel(await document(sold.id));
    const reverse = (await ownerPool.query(
      "SELECT id, amount::float AS amount, customer_id, detail FROM cashback_entry WHERE sale_id = $1 AND kind = 'reverse' AND deleted_at IS NULL", [sold.id],
    )).rows;
    expect(reverse).toEqual([{ id: expect.any(String), amount: 2, customer_id: customerId, detail: { reason: 'canceled_sale' } }]);
    const allocation = (await ownerPool.query(
      'SELECT lot_id, amount::float AS amount FROM cashback_allocation WHERE entry_id = $1 AND deleted_at IS NULL', [reverse[0].id],
    )).rows;
    expect(allocation).toEqual([{ lot_id: lot.id, amount: 2 }]);
    expect(await balance(customerId)).toBe(before);
  });

  it('usado na venda: a utilização é liberada e o saldo usado volta ao cliente', async () => {
    const customerId = await newCustomer(true);
    await newSale({ customerId, unitPrice: 400 });
    const before = await balance(customerId);
    expect(before).toBe(20);
    const held = await reserve(customerId, 10, 50);
    const sold = await newSale({
      customerId, unitPrice: 50,
      payments: [
        { id: uuidV7(), method: 'cashback', amount: 10, reservation_id: held.reservation_id },
        { id: uuidV7(), method: 'cash', amount: 40, change: 0 },
      ],
    });
    const use = async () => (await ownerPool.query('SELECT kind, status, sale_id FROM cashback_entry WHERE id = $1', [held.reservation_id])).rows[0];
    expect(await use()).toEqual({ kind: 'use', status: 'confirmed', sale_id: sold.id });
    // Usou 10 e ganhou 5% sobre os 40 em dinheiro.
    expect(await balance(customerId)).toBe(12);

    await cancel(await document(sold.id));
    expect(await use()).toEqual({ kind: 'use', status: 'released', sale_id: sold.id });
    // O usado volta e o ganho desta venda é estornado: o saldo de antes da venda.
    expect(await balance(customerId)).toBe(before);
  });
});

describe('crediário', () => {
  const openAccount = async (customerId, limit) =>
    (await asUser(a.admin, 'SELECT app.open_credit_account($1, $2, $3, $4) AS id', [customerId, a.branch1.id, limit, null]))[0].id;
  const detail = async (customerId) => (await asUser(a.admin, 'SELECT app.credit_account_detail($1) AS d', [customerId]))[0].d;
  const schedule = async (customerId, amount, count) => (await ownerPool.query(
    `SELECT app.credit_schedule(app.credit_terms(a), ($2::timestamptz AT TIME ZONE 'America/Sao_Paulo')::date, $3, $4) AS s
       FROM credit_account a WHERE a.customer_id = $1 AND a.deleted_at IS NULL`,
    [customerId, new Date().toISOString(), amount, count],
  )).rows[0].s;
  const creditSale = async (customerId, amount, count) => newSale({
    customerId, unitPrice: amount,
    payments: [{ id: uuidV7(), method: 'store_credit', amount, installments: await schedule(customerId, amount, count) }],
  });

  it('venda no crediário cancelada: recebimento "cancel" quita todas as parcelas e o débito volta', async () => {
    const customerId = await newCustomer();
    const accountId = await openAccount(customerId, 500);
    const sold = await creditSale(customerId, 90, 3);
    expect((await detail(customerId)).summary).toMatchObject({ principal_open: 90, available: 410 });

    expect(await cancel(await document(sold.id))).toEqual({ cash: 0, cash_refund: 'none' });
    const payments = (await ownerPool.query('SELECT * FROM credit_payment WHERE canceled_sale_id = $1', [sold.id])).rows;
    expect(payments).toHaveLength(1);
    expect(payments[0]).toMatchObject({ method: 'cancel', account_id: accountId, received_by: a.admin.id, cash_session_id: session, deleted_at: null });
    expect(Number(payments[0].amount)).toBe(90);
    const installments = (await ownerPool.query(
      'SELECT id, amount::float AS amount FROM credit_installment WHERE sale_id = $1 AND deleted_at IS NULL ORDER BY number', [sold.id],
    )).rows;
    expect(installments).toHaveLength(3);
    const allocations = (await ownerPool.query(
      'SELECT installment_id, principal::float AS principal, fee::float AS fee, interest::float AS interest FROM credit_allocation WHERE payment_id = $1 AND deleted_at IS NULL',
      [payments[0].id],
    )).rows;
    expect(allocations.sort((x, y) => installments.findIndex((i) => i.id === x.installment_id) - installments.findIndex((i) => i.id === y.installment_id)))
      .toEqual(installments.map((i) => ({ installment_id: i.id, principal: i.amount, fee: 0, interest: 0 })));
    expect((await detail(customerId)).summary).toMatchObject({ principal_open: 0, available: 500 });
    expect((await ownerPool.query('SELECT app.credit_states($1) AS s', [accountId])).rows[0].s).toEqual([]);
  });

  it('parcela da venda já paga: não cancela (FA752)', async () => {
    const customerId = await newCustomer();
    await openAccount(customerId, 500);
    const sold = await creditSale(customerId, 60, 2);
    const doc = await document(sold.id);
    expect(await context(doc)).toHaveLength(1);
    expect((await push('credit_payment', {
      id: uuidV7(), cash_session_id: session, customer_id: customerId, received_by: operator.id,
      received_at: new Date().toISOString(), method: 'cash', amount: 10,
    })).status).toBe('applied');
    await expect(context(doc)).rejects.toSatisfy(hasCode('FA752'));
    expect((await saleRow(sold.id)).canceled_at).toBeNull();
  });
});

describe('convênio', () => {
  it('venda já numa fatura fechada do convênio: não cancela (FA750)', async () => {
    const agreementId = (await asUser(a.admin, 'SELECT app.create_agreement($1, NULL) AS id', [`Convênio ${tag()}`]))[0].id;
    const customerId = await newCustomer();
    await asUser(a.admin, 'SELECT app.link_customer_agreement($1, $2, $3, $4)', [customerId, agreementId, 'M-1', 500]);
    const sold = await newSale({
      customerId, unitPrice: 30,
      payments: [{ id: uuidV7(), method: 'agreement', amount: 30, agreement_id: agreementId, agreement_registration: 'M-1' }],
    });
    const doc = await document(sold.id);
    expect(await context(doc)).toHaveLength(1);
    const today = (await ownerPool.query('SELECT app.local_day(now())::text AS d')).rows[0].d;
    await asUser(a.admin, 'SELECT app.close_agreement_invoice($1, $2)', [agreementId, today]);
    await expect(context(doc)).rejects.toSatisfy(hasCode('FA750'));
  });
});

describe('controlado com SNGPC aberto', () => {
  let controlled;
  let batch;
  const complete = () => ({
    id: uuidV7(), status: 'complete', pharmacist_id: pharmacist.id, batch_id: batch,
    prescription_type: 'notification_b', prescription_number: 'SP-123456', prescription_date: spDay(-2),
    prescriber_name: 'Dra. Ana Prescritora', prescriber_council: 'CRM', prescriber_number: '123456', prescriber_state: 'SP',
    buyer_name: 'Comprador de Teste', buyer_document_type: 'rg', buyer_document: '12.345.678-9', buyer_issuer: 'SSP', buyer_state: 'SP',
  });
  const controlledSale = () => newSale({ item: controlled.id, unitPrice: 20, itemExtra: { batch_id: batch, controlled: complete() } });
  const saleMovements = async (saleId) => (await ownerPool.query(
    `SELECT sm.id, sm.status, m.canceled_sale_id FROM sngpc_movement sm
       JOIN stock_movement m ON m.id = sm.stock_movement_id
       LEFT JOIN sale_item i ON i.id = m.sale_item_id
      WHERE i.sale_id = $1 OR m.canceled_sale_id = $1`, [saleId],
  )).rows;
  const confirm = (ids) => asUser(pharmacist, 'SELECT app.sngpc_confirm($1, $2::uuid[], $3::date) AS n', [a.branch1.id, ids, spDay()]).then((r) => r[0].n);

  beforeAll(async () => {
    const sourceKey = `cancel-${tag()}`;
    const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
      sourceKey, name: `Controlado ${sourceKey}`, controlledClass: 'B1',
    })])).rows[0].id;
    const barcode = gtin();
    controlled = { id: (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${sourceKey}`, barcode, catalogProductId: catalogId,
    })]))[0].id, barcode };
    await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 20, NULL)', [controlled.id]);
    await asUser(a.admin, 'SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
      productLookup: barcode, branchId: a.branch1.id, direction: 'in', quantity: 10, reason: 'Teste', batchNumber: 'L1', expiresOn: '2090-01-31',
      msRegistration: '1234567890123',
    })]);
    batch = (await ownerPool.query('SELECT id FROM product_batch WHERE product_id = $1 AND batch_number = $2 AND branch_id = $3', [controlled.id, 'L1', a.branch1.id])).rows[0].id;
    await asUser(pharmacist, 'SELECT app.sngpc_open($1)', [a.branch1.id]);
    // O inventário conferido, para a saída da venda poder ser conferida depois.
    const inventory = (await ownerPool.query("SELECT id FROM sngpc_movement WHERE branch_id = $1 AND kind = 'inventory' AND status = 'pending'", [a.branch1.id])).rows.map((r) => r.id);
    expect(inventory).toHaveLength(1);
    expect(await confirm(inventory)).toBe(1);
  });

  it('saída ainda pendente: desconsiderada, dispensação apagada e o estorno do estoque fora do SNGPC', async () => {
    const sold = await controlledSale();
    const pending = await saleMovements(sold.id);
    expect(pending.map((m) => m.status)).toEqual(['pending']);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM controlled_dispensing WHERE sale_id = $1 AND deleted_at IS NULL', [sold.id])).rows[0].n).toBe(1);
    const before = (await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE branch_id = $1', [a.branch1.id])).rows[0].n;

    await cancel(await document(sold.id));
    const after = await saleMovements(sold.id);
    expect(after).toEqual([{ id: pending[0].id, status: 'disregarded', canceled_sale_id: null }]);
    const dispensing = (await ownerPool.query('SELECT deleted_at FROM controlled_dispensing WHERE sale_id = $1', [sold.id])).rows;
    expect(dispensing).toHaveLength(1);
    expect(dispensing[0].deleted_at).not.toBeNull();
    // O estoque voltou ao lote, sem movimentação nova no SNGPC.
    const reversal = (await ownerPool.query('SELECT batch_id, quantity::float AS q FROM stock_movement WHERE canceled_sale_id = $1', [sold.id])).rows;
    expect(reversal).toEqual([{ batch_id: batch, q: 1 }]);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE branch_id = $1', [a.branch1.id])).rows[0].n).toBe(before);
  });

  it('saída já conferida no SNGPC: não cancela (FA751)', async () => {
    const sold = await controlledSale();
    const doc = await document(sold.id);
    expect(await context(doc)).toHaveLength(1);
    const [movement] = await saleMovements(sold.id);
    expect(await confirm([movement.id])).toBe(1);
    await expect(context(doc)).rejects.toSatisfy(hasCode('FA751'));
    expect((await saleRow(sold.id)).canceled_at).toBeNull();
  });
});

describe('orçamento', () => {
  it('o orçamento convertido na venda volta a ficar aberto', async () => {
    quoteNumber += 1;
    const quote = {
      id: uuidV7(), number: quoteNumber, seller_id: clerk.id, customer_id: null, card_number: null, quoted_at: new Date().toISOString(),
      items: [{ id: uuidV7(), line: 1, product_id: product, quantity: 1, unit_price: 10, discount: 0, total: 10 }],
      subtotal: 10, discount_total: 0, total: 10,
    };
    expect((await push('quote', quote)).status).toBe('applied');
    const sold = await newSale({ extra: { quote_id: quote.id, seller_id: clerk.id } });
    const row = async () => (await ownerPool.query('SELECT status, converted_sale_id FROM quote WHERE id = $1', [quote.id])).rows[0];
    expect(await row()).toEqual({ status: 'converted', converted_sale_id: sold.id });

    await cancel(await document(sold.id));
    expect(await row()).toEqual({ status: 'open', converted_sale_id: null });
    // A venda cancelada guarda de qual orçamento veio.
    expect((await saleRow(sold.id)).quote_id).toBe(quote.id);
  });
});

describe('outro grupo', () => {
  it('não acha a nota de outro grupo (FA006)', async () => {
    const sold = await newSale();
    const doc = await document(sold.id);
    await expect(context(doc, b.admin)).rejects.toSatisfy(hasCode('FA006'));
    await expect(asUser(b.admin, 'SELECT app.fiscal_cancel_register($1, $2::jsonb)', [doc.id, cancelEvent()])).rejects.toSatisfy(hasCode('FA006'));
    expect((await saleRow(sold.id)).canceled_at).toBeNull();
  });
});
