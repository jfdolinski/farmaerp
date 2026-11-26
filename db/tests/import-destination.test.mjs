import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser } from './helpers.mjs';

// Parte B do lote de 26/11: a NFC-e de empresa ou filial que o cliente ainda não tem espera o
// administrador da plataforma (criar ou recusar); produtos nascem só das NFC-e, e o item de NF-e
// sem produto fica de fora. Notas montadas à mão.

let a;
let b;
let platform;
const XML = `<nfeProc versao="4.00">${'<z/>'.repeat(40)}</nfeProc>`;

const key = (model) => {
  const digits = Array.from({ length: 44 }, () => randomInt(10));
  digits[20] = Number(model[0]);
  digits[21] = Number(model[1]);
  return digits.join('');
};
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

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

/** Arquivo novo do grupo A, já reservado para o processamento. */
async function newJob() {
  const id = (await asUser(a.admin, 'SELECT app.create_document_import($1, $2) AS id', ['destino.zip', 1]))[0].id;
  await asUser(a.admin, 'SELECT app.document_import_part($1, 1, 1)', [id]);
  await asUser(a.admin, 'SELECT app.complete_document_import($1)', [id]);
  for (let i = 0; i < 50; i += 1) {
    const claimed = (await asWorker('SELECT app.claim_document_import() AS j'))[0].j;
    if (!claimed || claimed.id === id) break;
    await asWorker('SELECT app.document_import_progress($1, NULL, $2, NULL)', [claimed.id, 'done']);
  }
  return id;
}
const finish = (job, totals) => asWorker('SELECT app.document_import_progress($1, $2::jsonb, $3, NULL)', [job, JSON.stringify(totals), 'done']);
const importNfce = (job, n, entry = 'nfce.xml') => asWorker('SELECT app.import_nfce($1, $2, $3::jsonb) AS r', [job, entry, JSON.stringify(n)]).then((r) => r[0].r);
const importNfe = (job, n, entry = 'nfe.xml') => asWorker('SELECT app.import_nfe($1, $2, $3::jsonb) AS r', [job, entry, JSON.stringify(n)]).then((r) => r[0].r);
const pendingList = () => asUser(platform, 'SELECT * FROM app.platform_pending_issuers()');
const resolve = (id, decision, data = {}) =>
  asUser(platform, 'SELECT app.platform_resolve_issuer($1, $2, $3::jsonb) AS r', [id, decision, JSON.stringify(data)]).then((r) => r[0].r);
const pendingOf = async (cnpj) => (await ownerPool.query('SELECT * FROM import_pending_issuer WHERE economic_group_id = $1 AND cnpj = $2', [a.group.id, cnpj])).rows[0];
const noteRow = async (job, k) => (await ownerPool.query("SELECT result, reason FROM document_import_note WHERE import_id = $1 AND access_key = $2 AND result <> 'duplicate'", [job, k])).rows[0];
const totalsOf = async (job) => (await ownerPool.query('SELECT totals FROM document_import WHERE id = $1', [job])).rows[0].totals;

const issuerOf = (cnpj, overrides = {}) => ({
  cnpj, name: 'DROGARIA NOVA LTDA', trade_name: 'Drogaria Nova', state_registration: 'ISENTO', crt: '1',
  street: 'Rua Nova', number: '5', district: 'Centro', city: 'São Paulo', city_code: '3550308', uf: 'SP', postal_code: '01001000', ...overrides,
});
function nfce(issuer, overrides = {}) {
  return {
    access_key: key('65'), model: '65', series: 1, number: randomInt(1, 1e6), emitted_at: '2026-06-10T10:00:00-03:00', environment: '1',
    status_code: '100', protocol: '135260000000001', issuer,
    items: [{ line: 1, code: `N${randomInt(1e9)}`, gtin: null, name: 'Produto da NFC-e', quantity: 1, unit_price: 5, discount: 0, total: 5, cfop: '5102' }],
    payments: [{ type: '01', amount: 5 }], subtotal: 5, discount: 0, total: 5, change: 0, xml: XML, ...overrides,
  };
}
const party = (cnpj, name) => ({ cnpj, name, uf: 'SP' });
function nfeItem(overrides = {}) {
  return {
    line: 1, code: `F${randomInt(1e9)}`, gtin: null, tax_gtin: null, name: 'Item de compra', ncm: '30049099', unit: 'CX', quantity: 2,
    unit_price: 10, products_value: 20, discount: 0, freight: 0, insurance: 0, other: 0, ipi: 0, st: 0, fcp_st: 0, total: 20, cfop: '5102',
    batches: [], ...overrides,
  };
}
const supplierCnpj = branchCnpj(randomRoot(), 1);
function nfe(overrides = {}) {
  return {
    access_key: key('55'), model: '55', series: 1, number: randomInt(1, 1e6), emitted_at: '2026-05-10T10:00:00-03:00', environment: '1',
    status_code: '100', protocol: '135260000000009', operation: '1',
    issuer: party(supplierCnpj, 'DISTRIBUIDORA DESTINO SA'), dest: party(a.branch1.cnpj, 'Filial'),
    items: [nfeItem()], payments: [], subtotal: 20, discount: 0, total: 20, change: 0, xml: XML, ...overrides,
  };
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  // Administrador da plataforma fora dos clientes.
  platform = (await ownerPool.query("INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Plataforma') RETURNING *", [b.group.id])).rows[0];
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [platform.id]);
});
afterAll(closePools);

describe('empresa nova espera a plataforma', () => {
  const cnpj = branchCnpj(randomRoot(), 1);
  let job;
  let first;
  let second;

  it('as notas esperam, sem criar nada; a mesma chave não espera duas vezes', async () => {
    job = await newJob();
    first = nfce(issuerOf(cnpj), { emitted_at: '2026-06-01T10:00:00-03:00' });
    second = nfce(issuerOf(cnpj), { emitted_at: '2026-06-20T10:00:00-03:00' });
    expect(await importNfce(job, first)).toMatchObject({ result: 'waiting', reason: expect.stringContaining('administrador da plataforma') });
    expect((await importNfce(job, first)).result).toBe('duplicate');
    expect((await importNfce(job, second)).result).toBe('waiting');
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM branch WHERE cnpj = $1', [cnpj])).rows[0].n).toBe(0);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM company WHERE cnpj_root = $1', [cnpj.slice(0, 8)])).rows[0].n).toBe(0);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM imported_sale WHERE access_key = $1', [first.access_key])).rows[0].n).toBe(0);
    const pending = await pendingOf(cnpj);
    expect(pending).toMatchObject({ status: 'pending', branch_id: null });
    expect(pending.issuer).toMatchObject({ cnpj, name: 'DROGARIA NOVA LTDA' });
    expect(await noteRow(job, first.access_key)).toMatchObject({ result: 'waiting' });
  });

  it('a plataforma vê o CNPJ com o cliente e a contagem; o cliente não decide nem vê a lista', async () => {
    const row = (await pendingList()).find((p) => p.cnpj === cnpj);
    expect(row).toMatchObject({
      group_id: a.group.id, group_name: a.group.name, name: 'DROGARIA NOVA LTDA', trade_name: 'Drogaria Nova', state: 'SP', tax_regime: 1,
      kind: 'company', company_name: null, notes: 2,
    });
    expect(row.first_emitted_at.toISOString()).toBe('2026-06-01T13:00:00.000Z');
    expect(row.last_emitted_at.toISOString()).toBe('2026-06-20T13:00:00.000Z');
    await expect(asUser(a.admin, 'SELECT * FROM app.platform_pending_issuers()')).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.admin, "SELECT app.platform_resolve_issuer($1, 'create', '{}'::jsonb)", [row.id])).rejects.toSatisfy(hasCode('FA002'));
    // O relatório do cliente mostra o que espera.
    const report = (await asUser(a.admin, 'SELECT app.document_import_report($1) AS r', [job]))[0].r;
    expect(report.waiting).toEqual([{ cnpj, name: 'DROGARIA NOVA LTDA', status: 'pending', notes: 2 }]);
  });

  it('criar: empresa e filial no cliente com os dados revisados; as notas entram pela rotina, NFC-e primeiro', async () => {
    const pending = await pendingOf(cnpj);
    await expect(resolve(pending.id, 'talvez')).rejects.toSatisfy(hasCode('FA005'));
    await expect(resolve(pending.id, 'create', { taxRegime: '9' })).rejects.toSatisfy(hasCode('FA005'));
    await expect(resolve('019a0000-0000-7000-8000-0000000000ff', 'create')).rejects.toSatisfy(hasCode('FA006'));
    // A NF-e de compra para a filial que espera também espera.
    const seed = gtin();
    const purchase = nfe({ dest: party(cnpj, 'Drogaria Nova'), items: [nfeItem({ gtin: seed })] });
    expect((await importNfe(job, purchase)).result).toBe('waiting');
    await finish(job, { imported: 0, waiting: 3 });
    // Nada a reservar enquanto não há decisão.
    expect((await asWorker('SELECT app.claim_released_import_notes(50) AS n'))[0].n.filter((n) => n.import_id === job)).toEqual([]);

    const decided = await resolve(pending.id, 'create', { legalName: 'DROGARIA NOVA COMERCIO LTDA', tradeName: 'Nova Centro', taxRegime: '3' });
    expect(decided).toMatchObject({ status: 'created', notes: 3 });
    const branch = (await ownerPool.query(
      'SELECT b.*, c.economic_group_id, c.legal_name, c.trade_name, c.tax_regime FROM branch b JOIN company c ON c.id = b.company_id WHERE b.cnpj = $1', [cnpj],
    )).rows[0];
    expect(branch).toMatchObject({ id: decided.branch_id, economic_group_id: a.group.id, legal_name: 'DROGARIA NOVA COMERCIO LTDA', trade_name: 'Nova Centro', tax_regime: 3, state: 'SP' });
    expect(await pendingOf(cnpj)).toMatchObject({ status: 'created', branch_id: branch.id, decided_by: platform.id });
    await expect(resolve(pending.id, 'refuse')).rejects.toSatisfy(hasCode('FA758'));
    expect((await pendingList()).some((p) => p.cnpj === cnpj)).toBe(false);

    // Só o processamento reserva; a NFC-e (que cria o produto) vem antes da NF-e.
    await expect(asUser(a.admin, 'SELECT app.claim_released_import_notes(50)')).rejects.toSatisfy(hasCode('FA002'));
    const claimed = (await asWorker('SELECT app.claim_released_import_notes(50) AS n'))[0].n.filter((n) => n.import_id === job);
    expect(claimed.map((n) => n.model)).toEqual(['65', '65', '55']);
    expect(claimed[0]).toMatchObject({ entry: 'nfce.xml', note: { access_key: first.access_key } });
    // Reservadas: não voltam na próxima rodada.
    expect((await asWorker('SELECT app.claim_released_import_notes(50) AS n'))[0].n.filter((n) => n.import_id === job)).toEqual([]);
    // O produto da compra nasce da NFC-e da mesma filial nova.
    first.items[0].gtin = seed;
    for (const n of claimed) {
      const fn = n.model === '55' ? 'import_nfe' : 'import_nfce';
      await asWorker(`SELECT app.${fn}($1, $2, $3::jsonb)`, [n.import_id, n.entry, JSON.stringify(n.model === '65' && n.note.access_key === first.access_key ? first : n.note)]);
    }
    expect(await noteRow(job, first.access_key)).toEqual({ result: 'imported', reason: null });
    expect(await noteRow(job, second.access_key)).toEqual({ result: 'imported', reason: null });
    expect(await noteRow(job, purchase.access_key)).toEqual({ result: 'imported', reason: null });
    expect(await totalsOf(job)).toMatchObject({ waiting: 0, imported: 3 });
    expect((await ownerPool.query('SELECT branch_id FROM imported_sale WHERE access_key = $1', [first.access_key])).rows[0].branch_id).toBe(branch.id);
    expect((await ownerPool.query("SELECT count(*)::int AS n FROM import_waiting_note WHERE import_id = $1 AND status <> 'done'", [job])).rows[0].n).toBe(0);
    // Nota nova do mesmo CNPJ entra direto.
    const later = await newJob();
    expect((await importNfce(later, nfce(issuerOf(cnpj)))).result).toBe('imported');
  });
});

describe('filial nova de empresa do cliente e recusa', () => {
  it('filial nova (mesma raiz) espera; criada, fica na empresa que já existe', async () => {
    const cnpj = branchCnpj(a.root, 7);
    const job = await newJob();
    expect((await importNfce(job, nfce(issuerOf(cnpj)))).result).toBe('waiting');
    const row = (await pendingList()).find((p) => p.cnpj === cnpj);
    expect(row).toMatchObject({ kind: 'branch', company_name: expect.any(String) });
    const companies = (await ownerPool.query('SELECT count(*)::int AS n FROM company WHERE economic_group_id = $1', [a.group.id])).rows[0].n;
    const decided = await resolve(row.id, 'create');
    const branch = (await ownerPool.query('SELECT company_id FROM branch WHERE id = $1', [decided.branch_id])).rows[0];
    expect(branch.company_id).toBe(a.branch1.company_id);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM company WHERE economic_group_id = $1', [a.group.id])).rows[0].n).toBe(companies);
  });

  it('recusar: as notas ficam ignoradas com o motivo, a conta muda, e as próximas do CNPJ também são ignoradas', async () => {
    const cnpj = branchCnpj(randomRoot(), 1);
    const job = await newJob();
    const waiting = [nfce(issuerOf(cnpj)), nfce(issuerOf(cnpj))];
    for (const n of waiting) expect((await importNfce(job, n)).result).toBe('waiting');
    await finish(job, { imported: 0, waiting: 2, ignored: 0 });
    const pending = await pendingOf(cnpj);
    expect(await resolve(pending.id, 'refuse')).toEqual({ status: 'refused', notes: 2 });
    for (const n of waiting) {
      expect(await noteRow(job, n.access_key)).toEqual({ result: 'ignored', reason: 'O administrador da plataforma recusou a empresa deste CNPJ.' });
    }
    expect(await totalsOf(job)).toMatchObject({ waiting: 0, ignored: 2 });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM branch WHERE cnpj = $1', [cnpj])).rows[0].n).toBe(0);
    expect(await pendingOf(cnpj)).toMatchObject({ status: 'refused', decided_by: platform.id });
    const later = await newJob();
    expect(await importNfce(later, nfce(issuerOf(cnpj)))).toMatchObject({ result: 'ignored', reason: expect.stringContaining('recusou') });
    // NF-e para o CNPJ recusado: não é filial do cliente.
    expect(await importNfe(later, nfe({ dest: party(cnpj, 'Recusada') }))).toMatchObject({ result: 'ignored', reason: expect.stringContaining('Nenhuma filial do cliente') });
  });

  it('CNPJ de outro cliente ou inválido continua recusando a NFC-e na hora', async () => {
    const job = await newJob();
    expect(await importNfce(job, nfce(issuerOf(b.branch1.cnpj)))).toMatchObject({ result: 'failed', code: 'FA742' });
    expect(await importNfce(job, nfce(issuerOf(branchCnpj(b.root, 8))))).toMatchObject({ result: 'failed', code: 'FA742' });
    expect(await importNfce(job, nfce(issuerOf('11111111111111')))).toMatchObject({ result: 'failed', code: 'FA743' });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM import_pending_issuer WHERE cnpj = ANY ($1)', [[b.branch1.cnpj, '11111111111111']])).rows[0].n).toBe(0);
  });
});

describe('cancelamento da nota que espera', () => {
  it('na mesma importação: a nota sai da espera como cancelada, e o processamento desconta', async () => {
    const cnpj = branchCnpj(randomRoot(), 1);
    const job = await newJob();
    const n = nfce(issuerOf(cnpj));
    expect((await importNfce(job, n)).result).toBe('waiting');
    const [{ r }] = await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, NULL) AS r', [job, 'canc.xml', n.access_key]);
    expect(r).toEqual({ result: 'canceled', found: true, was_waiting: true });
    expect(await noteRow(job, n.access_key)).toEqual({ result: 'canceled', reason: 'Nota cancelada enquanto esperava o destino do CNPJ.' });
    expect((await ownerPool.query('SELECT status FROM import_waiting_note WHERE access_key = $1', [n.access_key])).rows[0].status).toBe('done');
  });

  it('em importação posterior: a conta da importação que esperava muda', async () => {
    const cnpj = branchCnpj(randomRoot(), 1);
    const job = await newJob();
    const n = nfce(issuerOf(cnpj));
    expect((await importNfce(job, n)).result).toBe('waiting');
    await finish(job, { waiting: 1, canceled: 0 });
    const later = await newJob();
    const [{ r }] = await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, NULL) AS r', [later, 'canc.xml', n.access_key]);
    expect(r).toEqual({ result: 'canceled', found: true, was_waiting: false });
    expect(await totalsOf(job)).toMatchObject({ waiting: 0, canceled: 1 });
    expect((await ownerPool.query("SELECT reason FROM document_import_note WHERE import_id = $1 AND entry_name = 'canc.xml'", [later])).rows[0].reason)
      .toBe('Cancelamento de nota que esperava o destino do CNPJ.');
  });
});

describe('produtos nascem só das NFC-e', () => {
  let job;
  const known = gtin();

  beforeAll(async () => {
    job = await newJob();
    const seed = nfce({ cnpj: a.branch1.cnpj, name: 'Filial 1', uf: 'SP' }, {
      items: [{ line: 1, code: `K${randomInt(1e9)}`, gtin: known, name: 'Produto conhecido', quantity: 1, unit_price: 5, discount: 0, total: 5, cfop: '5102' }],
    });
    expect((await importNfce(job, seed)).result).toBe('imported');
  });

  it('compra: o item sem produto fica de fora (anotado), o outro entra; nenhum produto novo', async () => {
    const products = (await ownerPool.query('SELECT count(*)::int AS n FROM product WHERE economic_group_id = $1', [a.group.id])).rows[0].n;
    const unknown = nfeItem({ line: 2, code: 'SEM-PRODUTO', gtin: gtin(), name: 'Item que ninguém tem', quantity: 3 });
    const note = nfe({ items: [nfeItem({ gtin: known }), unknown] });
    expect(await importNfe(job, note)).toMatchObject({ result: 'imported', reason: '1 item(ns) sem produto cadastrado ficaram de fora.' });
    const stored = (await ownerPool.query('SELECT id, skipped_items FROM imported_stock_note WHERE access_key = $1', [note.access_key])).rows[0];
    expect(stored.skipped_items).toEqual([{ line: 2, code: 'SEM-PRODUTO', name: 'Item que ninguém tem', gtin: unknown.gtin, quantity: 3 }]);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM imported_stock_note_item WHERE note_id = $1', [stored.id])).rows[0].n).toBe(1);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM product WHERE economic_group_id = $1', [a.group.id])).rows[0].n).toBe(products);
  });

  it('nenhum item com produto: a nota não entra, com o motivo', async () => {
    const note = nfe({ items: [nfeItem({ code: 'X1' }), nfeItem({ line: 2, code: 'X2' })] });
    expect(await importNfe(job, note)).toMatchObject({ result: 'ignored', reason: expect.stringContaining('Nenhum item da nota tem produto cadastrado') });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM imported_stock_note WHERE access_key = $1', [note.access_key])).rows[0].n).toBe(0);
  });

  it('nota emitida pelo cliente (venda a empresa) também não cria produto', async () => {
    const sale = nfe({
      issuer: party(a.branch1.cnpj, 'Filial 1'), dest: party(branchCnpj(randomRoot(), 1), 'CLINICA LTDA'),
      items: [nfeItem({ gtin: known }), nfeItem({ line: 2, code: 'PROPRIO-NOVO', name: 'Próprio sem cadastro' })],
      payments: [{ type: '15', amount: 40 }], subtotal: 40, total: 40,
    });
    expect(await importNfe(job, sale)).toMatchObject({ result: 'imported', kind: 'sale', reason: '1 item(ns) sem produto cadastrado ficaram de fora.' });
    const row = (await ownerPool.query('SELECT id, skipped_items FROM imported_sale WHERE access_key = $1', [sale.access_key])).rows[0];
    expect(row.skipped_items.map((i) => i.code)).toEqual(['PROPRIO-NOVO']);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM imported_sale_item WHERE imported_sale_id = $1', [row.id])).rows[0].n).toBe(1);
  });

  it('o relatório lista os itens de fora e o total', async () => {
    const report = (await asUser(a.admin, 'SELECT app.document_import_report($1) AS r', [job]))[0].r;
    expect(report.skipped_total).toBe(2);
    expect(report.skipped_items.map((i) => i.code).sort()).toEqual(['PROPRIO-NOVO', 'SEM-PRODUTO']);
    expect(report.skipped_items[0]).toMatchObject({ note_number: expect.any(Number), access_key: expect.stringMatching(/^\d{44}$/) });
  });
});
