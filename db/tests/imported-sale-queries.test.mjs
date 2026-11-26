import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, branchCnpj, closePools, createFixtures, ownerPool, randomRoot, setUser } from './helpers.mjs';

// Vendas importadas na retaguarda (lista, detalhe, XML) e no histórico do cliente.

let a;
let b;
let job;
const XML = `<nfeProc versao="4.00">${'<y/>'.repeat(40)}</nfeProc>`;

function cpf() {
  const digits = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(digits).size === 1) digits[0] = (digits[0] + 1) % 10;
  for (const size of [9, 10]) {
    const sum = digits.slice(0, size).reduce((total, digit, index) => total + digit * (size + 1 - index), 0);
    const rest = (sum * 10) % 11;
    digits.push(rest === 10 ? 0 : rest);
  }
  return digits.join('');
}
const key = () => Array.from({ length: 44 }, () => randomInt(10)).join('');

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
const asWorker = (sql, params) => run((c) => c.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'import', true)"), sql, params);

const issuerCnpj = branchCnpj(randomRoot(), 1);
const legacy = `Q${randomInt(1e6)}`;
const buyer = cpf();
// Notas recentes, para entrar nos últimos 30 dias do histórico.
const daysAgo = (days) => new Date(Date.now() - days * 86_400_000).toISOString();

function note(overrides = {}) {
  return {
    access_key: key(), model: '65', series: 2, number: randomInt(1, 1e6), emitted_at: daysAgo(3), environment: '1',
    status_code: '100', protocol: '135260000000002',
    issuer: {
      cnpj: issuerCnpj, name: 'FARMACIA IMPORTADA LTDA', trade_name: 'Farmácia Importada', state_registration: 'ISENTO', crt: '1',
      street: 'Rua A', number: '1', district: 'Centro', city: 'São Paulo', city_code: '3550308', uf: 'SP', postal_code: '01001000',
    },
    customer: { document: buyer, name: 'Maria Teste' },
    items: [
      { line: 1, code: legacy, gtin: null, name: 'Vitamina C', ncm: '21069030', quantity: 1, unit_price: 20, discount: 0, total: 20,
        cfop: '5102', tax: { origin: 0, icms_csosn: '102', pis_cst: '49', cofins_cst: '49' } },
    ],
    payments: [{ type: '17', amount: 20 }],
    subtotal: 20, discount: 0, total: 20, change: 0, xml: XML,
    ...overrides,
  };
}
const importNote = (n) => asWorker('SELECT app.import_nfce($1, $2, $3::jsonb) AS r', [job, 'nota.xml', JSON.stringify(n)]).then((r) => r[0].r);

let first;
let second;
let canceled;
let anonymous;
let saleId;
let customerId;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  job = (await asUser(a.admin, 'SELECT app.create_document_import($1, $2) AS id', ['vendas.zip', 10]))[0].id;
  await asUser(a.admin, 'SELECT app.document_import_part($1, 1, 10)', [job]);
  await asUser(a.admin, 'SELECT app.complete_document_import($1)', [job]);
  for (let i = 0; i < 50; i += 1) {
    const claimed = (await asWorker('SELECT app.claim_document_import() AS j'))[0].j;
    if (!claimed || claimed.id === job) break;
    await asWorker('SELECT app.document_import_progress($1, NULL, $2, NULL)', [claimed.id, 'done']);
  }
  first = note();
  second = note({ emitted_at: daysAgo(10), total: 40, subtotal: 40, items: [{ ...note().items[0], quantity: 2, total: 40 }], payments: [{ type: '01', amount: 40 }] });
  canceled = note({ emitted_at: daysAgo(1), total: 99, subtotal: 99, items: [{ ...note().items[0], quantity: 1, unit_price: 99, total: 99 }], payments: [{ type: '01', amount: 99 }] });
  anonymous = note({ customer: null, emitted_at: daysAgo(2) });
  for (const n of [first, second, canceled, anonymous]) expect((await importNote(n)).result).toBe('imported');
  await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [job, 'canc.xml', canceled.access_key, daysAgo(1)]);
  const row = (await ownerPool.query('SELECT id, customer_id FROM imported_sale WHERE access_key = $1', [first.access_key])).rows[0];
  saleId = row.id;
  customerId = row.customer_id;
});
afterAll(closePools);

describe('vendas importadas na retaguarda', () => {
  it('lista por cliente e período, com a cancelada marcada; outro grupo e quem não vê a filial não enxergam', async () => {
    const rows = await asUser(a.admin, 'SELECT * FROM app.list_imported_sales(NULL, NULL, NULL, $1)', [customerId]);
    expect(rows.map((r) => [r.number, Number(r.total), r.canceled_at !== null, r.payment_methods])).toEqual([
      [String(canceled.number), 99, true, ['01']],
      [String(first.number), 20, false, ['17']],
      [String(second.number), 40, false, ['01']],
    ]);
    // Sem o filtro do cliente, a venda sem cliente da mesma filial aparece.
    const branchId = (await ownerPool.query('SELECT branch_id FROM imported_sale WHERE id = $1', [saleId])).rows[0].branch_id;
    const all = await asUser(a.admin, 'SELECT number, customer_id FROM app.list_imported_sales($1)', [branchId]);
    expect(all.map((r) => r.number)).toEqual([canceled, anonymous, first, second].map((n) => String(n.number)));
    expect(all[1].customer_id).toBeNull();
    expect(rows[1]).toMatchObject({ customer_name: 'Maria Teste', model: '65', series: 2, item_count: 1 });
    const day = (iso) => new Date(new Date(iso).getTime() - 3 * 3_600_000).toISOString().slice(0, 10);
    const window = await asUser(a.admin, 'SELECT number FROM app.list_imported_sales(NULL, $1::date, $2::date, $3)', [day(first.emitted_at), day(first.emitted_at), customerId]);
    expect(window.map((r) => r.number)).toEqual([String(first.number)]);
    expect(await asUser(b.admin, 'SELECT * FROM app.list_imported_sales(NULL, NULL, NULL, $1)', [customerId])).toEqual([]);
    expect(await asUser(a.oneBranchUser, 'SELECT * FROM app.list_imported_sales(NULL, NULL, NULL, $1)', [customerId])).toEqual([]);
  });

  it('detalhe com itens (código do sistema anterior) e pagamentos; XML só para quem vê a venda', async () => {
    const detail = (await asUser(a.admin, 'SELECT app.imported_sale_detail($1) AS d', [saleId]))[0].d;
    expect(detail).toMatchObject({
      access_key: first.access_key, number: first.number, series: 2, model: '65', total: 20, customer_name: 'Maria Teste',
      file_name: 'vendas.zip', canceled_at: null,
      items: [{ line: 1, legacy_code: legacy, product_name: 'Vitamina C', quantity: 1, total: 20, cfop: '5102' }],
      payments: [{ method: '17', amount: 20 }],
    });
    expect(detail).not.toHaveProperty('xml');
    expect((await asUser(b.admin, 'SELECT app.imported_sale_detail($1) AS d', [saleId]))[0].d).toBeNull();
    expect((await asUser(a.admin, 'SELECT app.imported_sale_xml($1) AS x', [saleId]))[0].x).toEqual({ access_key: first.access_key, model: '65', xml: XML });
    expect((await asUser(a.oneBranchUser, 'SELECT app.imported_sale_xml($1) AS x', [saleId]))[0].x).toBeNull();
  });
});

describe('histórico do cliente', () => {
  it('soma as importadas não canceladas, mostra o número da nota e conta o produto recorrente', async () => {
    const history = (await asUser(a.admin, 'SELECT app.customer_purchase_history($1) AS h', [customerId]))[0].h;
    expect(history).toMatchObject({ sales_12m: 2, total_12m: 60, average_ticket: 30 });
    expect(history.last_30_days).toEqual([
      expect.objectContaining({ sale_id: saleId, code: `NFC-e 2/${first.number}`, imported: true, total: 20, items: 1, branch_name: expect.any(String) }),
      expect.objectContaining({ code: `NFC-e 2/${second.number}`, imported: true, total: 40 }),
    ]);
    expect(history.recurring).toEqual([expect.objectContaining({ name: 'Vitamina C', purchases: 2, quantity: 3 })]);
  });
});
