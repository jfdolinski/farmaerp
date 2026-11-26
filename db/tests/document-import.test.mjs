import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser } from './helpers.mjs';

// Importação das NFC-e do sistema anterior: envio em partes, fila, cadastros criados pela nota,
// venda importada com saída de estoque, cancelamento e relatório. Notas montadas à mão.

let a;
let b;
let job;
const XML = `<nfeProc versao="4.00">${'<x/>'.repeat(40)}</nfeProc>`;

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
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
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
const importNote = (note, entry = 'nota.xml') => asWorker('SELECT app.import_nfce($1, $2, $3::jsonb) AS r', [job, entry, JSON.stringify(note)]).then((r) => r[0].r);

const issuerCnpj = branchCnpj(randomRoot(), 1);
const legacyA = `A${randomInt(1e6)}`;
const legacyB = `B-${randomInt(1e6)}`;
const gtinA = gtin();
const buyer = cpf();

function note(overrides = {}) {
  return {
    access_key: key(), model: '65', series: 1, number: randomInt(1, 1e6), emitted_at: '2026-06-10T10:00:00-03:00', environment: '1',
    status_code: '100', protocol: '135260000000001',
    issuer: {
      cnpj: issuerCnpj, name: 'DROGARIA ANTIGA LTDA', trade_name: 'Drogaria Antiga', state_registration: 'ISENTO', crt: '1',
      street: 'Rua Velha', number: '10', district: 'Centro', city: 'São Paulo', city_code: '3550308', uf: 'SP', postal_code: '01001000',
    },
    customer: { document: buyer },
    items: [
      { line: 1, code: legacyA, gtin: gtinA, name: 'Dipirona 500 mg', ncm: '30049099', cest: '1300100', quantity: 2, unit_price: 12.5,
        discount: 1, total: 24, cfop: '5405', tax: { origin: 0, icms_csosn: '500', pis_cst: '04', cofins_cst: '04' } },
      { line: 2, code: legacyB, gtin: null, name: 'Produto sem GTIN', ncm: '33049910', quantity: 1, unit_price: 8, discount: 0, total: 8,
        cfop: '5102', tax: { origin: 0, icms_csosn: '102', pis_cst: '49', cofins_cst: '49' } },
    ],
    payments: [{ type: '01', amount: 40 }, { type: '03', amount: 0, card_brand: '01', authorization: 'ABC123' }],
    subtotal: 33, discount: 1, total: 32, change: 8, xml: XML,
    ...overrides,
  };
}
const balanceOf = async (productId) => Number((await ownerPool.query(
  'SELECT COALESCE(sum(quantity), 0) AS q FROM stock_balance WHERE product_id = $1 AND deleted_at IS NULL', [productId],
)).rows[0].q);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  // b.admin faz as vezes do administrador da plataforma nestes testes.
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [b.admin.id]);
});
afterAll(closePools);

describe('envio do arquivo', () => {
  it('só o administrador; arquivo .zip de até 1 GB; partes em ordem; completo entra na fila', async () => {
    await expect(asUser(a.oneBranchUser, 'SELECT app.create_document_import($1, $2)', ['notas.zip', 10])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.admin, 'SELECT app.create_document_import($1, $2)', ['notas.rar', 10])).rejects.toSatisfy(hasCode('FA740'));
    await expect(asUser(a.admin, 'SELECT app.create_document_import($1, $2)', ['notas.zip', 2 * 1024 ** 3])).rejects.toSatisfy(hasCode('FA740'));
    job = (await asUser(a.admin, 'SELECT app.create_document_import($1, $2) AS id', ['notas.zip', 30]))[0].id;
    await expect(asUser(a.admin, 'SELECT app.document_import_part($1, 2, 10)', [job])).rejects.toSatisfy(hasCode('FA741'));
    expect((await asUser(a.admin, 'SELECT app.document_import_part($1, 1, 20) AS n', [job]))[0].n).toBe('20');
    await expect(asUser(a.admin, 'SELECT app.document_import_part($1, 2, 11)', [job])).rejects.toSatisfy(hasCode('FA741'));
    await expect(asUser(a.admin, 'SELECT app.complete_document_import($1)', [job])).rejects.toSatisfy(hasCode('FA741'));
    await asUser(a.admin, 'SELECT app.document_import_part($1, 2, 10)', [job]);
    await expect(asUser(b.admin, 'SELECT app.complete_document_import($1)', [job])).rejects.toSatisfy(hasCode('FA006'));
    await asUser(a.admin, 'SELECT app.complete_document_import($1)', [job]);
    // A API não processa no lugar do processamento.
    await expect(asUser(a.admin, 'SELECT app.claim_document_import()')).rejects.toSatisfy(hasCode('FA002'));
    // Outros arquivos na fila podem vir antes (o banco de teste não é zerado): reserva até chegar neste.
    for (let i = 0; i < 50; i += 1) {
      const claimed = (await asWorker('SELECT app.claim_document_import() AS j'))[0].j;
      if (!claimed || claimed.id === job) break;
      await asWorker('SELECT app.document_import_progress($1, NULL, $2, NULL)', [claimed.id, 'done']);
    }
    expect((await ownerPool.query('SELECT status FROM document_import WHERE id = $1', [job])).rows[0].status).toBe('processing');
  });
});

describe('NFC-e importada', () => {
  let first;

  it('empresa nova espera a plataforma; criada, a nota entra com cliente, produtos, pagamentos e saída de estoque', async () => {
    first = note();
    expect(await importNote(first)).toMatchObject({ result: 'waiting', code: null });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM branch WHERE cnpj = $1', [issuerCnpj])).rows[0].n).toBe(0);
    const pending = (await ownerPool.query('SELECT id FROM import_pending_issuer WHERE economic_group_id = $1 AND cnpj = $2', [a.group.id, issuerCnpj])).rows[0];
    await asUser(b.admin, "SELECT app.platform_resolve_issuer($1, 'create', '{}'::jsonb)", [pending.id]);
    expect(await importNote(first)).toMatchObject({ result: 'imported', code: null });
    const sale = (await ownerPool.query('SELECT * FROM imported_sale WHERE access_key = $1', [first.access_key])).rows[0];
    expect([Number(sale.total), Number(sale.change_amount), sale.series, sale.model]).toEqual([32, 8, 1, '65']);
    const branch = (await ownerPool.query('SELECT b.*, c.economic_group_id, c.tax_regime, c.legal_name FROM branch b JOIN company c ON c.id = b.company_id WHERE b.id = $1', [sale.branch_id])).rows[0];
    expect(branch).toMatchObject({
      cnpj: issuerCnpj, economic_group_id: a.group.id, tax_regime: 1, legal_name: 'DROGARIA ANTIGA LTDA', state: 'SP',
      state_registration: 'ISENTO', city_code: '3550308',
    });
    const customer = (await ownerPool.query('SELECT * FROM customer WHERE id = $1', [sale.customer_id])).rows[0];
    expect([customer.document, customer.name]).toEqual([buyer, `Cliente CPF ***.***.***-${buyer.slice(-2)}`]);

    const products = (await ownerPool.query('SELECT * FROM product WHERE economic_group_id = $1 AND legacy_code = ANY ($2) ORDER BY legacy_code', [a.group.id, [legacyA, legacyB]])).rows;
    expect(products.map((p) => [p.legacy_code, p.display_name, p.own_ncm])).toEqual([[legacyA, 'Dipirona 500 mg', '30049099'], [legacyB, 'Produto sem GTIN', '33049910']]);
    const barcodes = (await ownerPool.query('SELECT p.legacy_code, pb.code, pb.is_internal FROM product_barcode pb JOIN product p ON p.id = pb.product_id WHERE pb.product_id = ANY ($1) ORDER BY p.legacy_code', [products.map((p) => p.id)])).rows;
    expect(barcodes).toEqual([
      { legacy_code: legacyA, code: gtinA, is_internal: false },
      { legacy_code: legacyB, code: legacyB.replace('-', ''), is_internal: true },
    ]);
    expect(Number((await ownerPool.query('SELECT price FROM product_price WHERE product_id = $1 AND branch_id IS NULL', [products[0].id])).rows[0].price)).toBe(12.5);
    const rule = (await ownerPool.query('SELECT * FROM product_tax_rule WHERE product_id = $1', [products[0].id])).rows[0];
    expect(rule).toMatchObject({ tax_regime: 1, state: 'SP', cfop: '5405', icms_csosn: '500', pis_cst: '04' });
    expect(await balanceOf(products[0].id)).toBe(-2);
    const movement = (await ownerPool.query("SELECT movement_type, occurred_at FROM stock_movement WHERE product_id = $1", [products[0].id])).rows[0];
    expect(movement.movement_type).toBe('import');
    expect(movement.occurred_at.toISOString()).toBe('2026-06-10T13:00:00.000Z');
    expect((await ownerPool.query('SELECT method, card_brand FROM imported_sale_payment WHERE imported_sale_id = $1 ORDER BY method', [sale.id])).rows)
      .toEqual([{ method: '01', card_brand: null }, { method: '03', card_brand: '01' }]);
  });

  it('mesma chave é repetida; homologação e sem autorização são ignoradas; CNPJ de outro cliente e dados ruins falham', async () => {
    expect(await importNote(first)).toMatchObject({ result: 'duplicate' });
    expect(await importNote(note({ environment: '2' }))).toMatchObject({ result: 'ignored', reason: 'Nota de homologação, sem valor fiscal.' });
    expect(await importNote(note({ status_code: '110' }))).toMatchObject({ result: 'ignored' });
    expect(await importNote(note({ issuer: { ...first.issuer, cnpj: b.branch1.cnpj } }))).toMatchObject({ result: 'failed', code: 'FA742' });
    expect(await importNote(note({ access_key: '123' }))).toMatchObject({ result: 'failed', code: 'FA743' });
    expect(await importNote(note({ items: [{ ...first.items[0], code: ' ' }] }))).toMatchObject({ result: 'failed', code: 'FA743' });
    expect(await importNote(note({ total: 'muito' }))).toMatchObject({ result: 'failed', code: 'FA743' });
    // Nada ficou pela metade: só a primeira venda existe para esse emitente.
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM imported_sale s JOIN branch b ON b.id = s.branch_id WHERE b.cnpj = $1', [issuerCnpj])).rows[0].n).toBe(1);
  });

  it('a nota mais nova troca a tributação do produto; a mais antiga não', async () => {
    const productA = (await ownerPool.query('SELECT id FROM product WHERE economic_group_id = $1 AND legacy_code = $2', [a.group.id, legacyA])).rows[0].id;
    const newer = note({ emitted_at: '2026-07-01T10:00:00-03:00', items: [{ ...first.items[0], cfop: '5102', tax: { origin: 0, icms_csosn: '102', pis_cst: '49', cofins_cst: '49' } }], payments: [] });
    expect(await importNote(newer)).toMatchObject({ result: 'imported' });
    const older = note({ emitted_at: '2026-01-01T10:00:00-03:00', items: [{ ...first.items[0], cfop: '5405' }], payments: [] });
    expect(await importNote(older)).toMatchObject({ result: 'imported' });
    expect((await ownerPool.query('SELECT cfop, icms_csosn FROM product_tax_rule WHERE product_id = $1', [productA])).rows[0]).toEqual({ cfop: '5102', icms_csosn: '102' });
    // Produto já cadastrado: não cria outro nem troca o preço.
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM product WHERE economic_group_id = $1 AND legacy_code = $2', [a.group.id, legacyA])).rows[0].n).toBe(1);
    expect(await balanceOf(productA)).toBe(-6);
  });

  it('cancelamento desfaz a venda e devolve o estoque; o relatório mostra problemas e a última numeração', async () => {
    const productA = (await ownerPool.query('SELECT id FROM product WHERE economic_group_id = $1 AND legacy_code = $2', [a.group.id, legacyA])).rows[0].id;
    await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [job, 'cancelamento.xml', first.access_key, '2026-06-10T11:00:00-03:00']);
    expect((await ownerPool.query('SELECT canceled_at FROM imported_sale WHERE access_key = $1', [first.access_key])).rows[0].canceled_at).not.toBeNull();
    expect(await balanceOf(productA)).toBe(-4);
    // De novo não devolve duas vezes; cancelamento de nota fora da importação só fica no relatório.
    await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [job, 'cancelamento.xml', first.access_key, null]);
    expect(await balanceOf(productA)).toBe(-4);
    expect((await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4) AS r', [job, 'outro.xml', key(), null]))[0].r).toEqual({ result: 'canceled', found: false, was_waiting: false });

    await asWorker('SELECT app.import_note_result($1, $2, NULL, NULL, $3, $4, $5)', [job, 'lixo.txt', 'ignored', null, 'Arquivo que não é nota']);
    await asWorker('SELECT app.document_import_progress($1, $2::jsonb, $3, NULL)', [job, JSON.stringify({ imported: 3 }), 'done']);
    const [{ r }] = await asUser(a.admin, 'SELECT app.document_import_report($1) AS r', [job]);
    expect(r).toMatchObject({ status: 'done', totals: { imported: 3 } });
    expect(r.problems.map((p) => p.error_code).sort()).toEqual(['FA742', 'FA743', 'FA743', 'FA743']);
    expect(r.last_numbers).toHaveLength(1);
    expect(r.last_numbers[0]).toMatchObject({ model: '65', series: 1 });
    await expect(asUser(b.admin, 'SELECT app.document_import_report($1)', [job])).rejects.toSatisfy(hasCode('FA006'));
    expect((await asUser(a.admin, 'SELECT id FROM app.list_document_imports()')).map((row) => row.id)).toContain(job);
    // Depois de encerrado, nada mais entra nesse arquivo.
    await expect(importNote(note())).rejects.toSatisfy(hasCode('FA006'));
  });

  it('GTIN inválido vira código interno; controlado importado na filial com SNGPC aberto não entra no SNGPC', async () => {
    // Novo arquivo, porque o anterior já foi encerrado.
    job = (await asUser(a.admin, 'SELECT app.create_document_import($1, $2) AS id', ['mais.zip', 1]))[0].id;
    await asUser(a.admin, 'SELECT app.document_import_part($1, 1, 1)', [job]);
    await asUser(a.admin, 'SELECT app.complete_document_import($1)', [job]);
    for (let i = 0; i < 50; i += 1) {
      const claimed = (await asWorker('SELECT app.claim_document_import() AS j'))[0].j;
      if (!claimed || claimed.id === job) break;
      await asWorker('SELECT app.document_import_progress($1, NULL, $2, NULL)', [claimed.id, 'done']);
    }
    const branchId = (await ownerPool.query('SELECT id FROM branch WHERE cnpj = $1', [issuerCnpj])).rows[0].id;
    // Controlado já cadastrado (ligado ao Catálogo) com o código do sistema anterior.
    const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
      sourceKey: `imp-${randomInt(1e9)}`, name: 'Clonazepam importado', controlledClass: 'B1',
    })])).rows[0].id;
    const controlled = (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: 'Clonazepam 2 mg', barcode: gtin(), catalogProductId: catalogId,
    })]))[0].id;
    const controlledCode = `C${randomInt(1e6)}`;
    await ownerPool.query('UPDATE product SET legacy_code = $2 WHERE id = $1', [controlled, controlledCode]);
    await ownerPool.query('INSERT INTO sngpc_branch (economic_group_id, branch_id, opened_by) VALUES ($1, $2, $3)', [a.group.id, branchId, a.admin.id]);

    const invalidGtin = '7891234567890'.slice(0, 12) + '9';
    const legacyC = `G${randomInt(1e6)}`;
    const items = [
      { ...note().items[0], code: legacyC, gtin: invalidGtin, line: 1 },
      { ...note().items[0], code: controlledCode, gtin: null, line: 2 },
    ];
    expect(await importNote(note({ items, payments: [] }))).toMatchObject({ result: 'imported' });
    const barcode = (await ownerPool.query('SELECT pb.code, pb.is_internal FROM product_barcode pb JOIN product p ON p.id = pb.product_id WHERE p.legacy_code = $1', [legacyC])).rows[0];
    expect(barcode).toEqual({ code: legacyC, is_internal: true });
    expect(await balanceOf(controlled)).toBe(-2);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE product_id = $1', [controlled])).rows[0].n).toBe(0);
  });

  it('a venda importada não entra no SNGPC, e a leitura direta fica no grupo', async () => {
    expect((await ownerPool.query("SELECT count(*)::int AS n FROM sngpc_movement m JOIN stock_movement s ON s.id = m.stock_movement_id WHERE s.movement_type = 'import'")).rows[0].n).toBe(0);
    expect(await asUser(b.admin, 'SELECT id FROM v_imported_sale WHERE access_key = $1', [first.access_key])).toEqual([]);
    await expect(asUser(a.admin, 'SELECT xml FROM v_imported_sale LIMIT 1')).rejects.toThrow();
  });
});
