import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser } from './helpers.mjs';

// Importação do NF-e 55: compras (entrada direta com custo), vendas, transferências, devoluções e
// outras saídas, pela direção do CNPJ e pelo CFOP. Notas montadas à mão.

let a;
let b;
let job;
const XML = `<nfeProc versao="4.00">${'<w/>'.repeat(40)}</nfeProc>`;
const key = () => {
  const digits = Array.from({ length: 44 }, () => randomInt(10));
  // Modelo 55 nas posições 21 e 22 da chave.
  digits[20] = 5;
  digits[21] = 5;
  return digits.join('');
};
/** Chave com o dígito verificador (módulo 11), como a nota de compra exige. */
function validKey() {
  const base = key().slice(0, 43);
  let weight = 2;
  let sum = 0;
  for (let i = base.length - 1; i >= 0; i -= 1) {
    sum += Number(base[i]) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const dv = 11 - (sum % 11);
  return base + String(dv >= 10 ? 0 : dv);
}
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
const importNfe = (note, entry = 'nfe.xml') => asWorker('SELECT app.import_nfe($1, $2, $3::jsonb) AS r', [job, entry, JSON.stringify(note)]).then((r) => r[0].r);

const supplierCnpj = branchCnpj(randomRoot(), 1);
const companyCustomer = branchCnpj(randomRoot(), 1);
const party = (cnpj, name) => ({ cnpj, name, uf: 'SP', city_code: '3550308', city: 'São Paulo', postal_code: '01001000', street: 'Rua X', number: '1' });

function item(overrides = {}) {
  return {
    line: 1, code: `F${randomInt(1e9)}`, gtin: null, tax_gtin: null, name: 'Item de compra', ncm: '30049099', unit: 'CX', quantity: 2,
    unit_price: 10, products_value: 20, discount: 0, freight: 2, insurance: 0, other: 0, ipi: 0, st: 0, fcp_st: 0, total: 20, cfop: '5102',
    batches: [], ...overrides,
  };
}
function nfe(overrides = {}) {
  return {
    access_key: key(), model: '55', series: 1, number: randomInt(1, 1e6), emitted_at: '2026-05-10T10:00:00-03:00', environment: '1',
    status_code: '100', protocol: '135260000000009', operation: '1',
    issuer: party(supplierCnpj, 'DISTRIBUIDORA TESTE SA'), dest: party(a.branch1.cnpj, 'Filial'),
    items: [item()], payments: [], subtotal: 20, discount: 0, total: 22, change: 0, xml: XML,
    ...overrides,
  };
}
const balance = async (productId, branchId) => Number((await ownerPool.query(
  'SELECT COALESCE(sum(quantity), 0) AS q FROM stock_balance WHERE product_id = $1 AND branch_id = $2 AND deleted_at IS NULL', [productId, branchId],
)).rows[0].q);
const noteByKey = async (k) => (await ownerPool.query('SELECT * FROM imported_stock_note WHERE access_key = $1', [k])).rows[0];
const itemsOf = async (noteId) => (await ownerPool.query('SELECT * FROM imported_stock_note_item WHERE note_id = $1 ORDER BY line', [noteId])).rows;
const costOf = async (productId, branchId) => (await ownerPool.query(
  'SELECT average_cost FROM product_cost WHERE product_id = $1 AND branch_id = $2 AND deleted_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1',
  [productId, branchId],
)).rows[0]?.average_cost ?? null;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  job = (await asUser(a.admin, 'SELECT app.create_document_import($1, $2) AS id', ['nfe.zip', 10]))[0].id;
  await asUser(a.admin, 'SELECT app.document_import_part($1, 1, 10)', [job]);
  await asUser(a.admin, 'SELECT app.complete_document_import($1)', [job]);
  for (let i = 0; i < 50; i += 1) {
    const claimed = (await asWorker('SELECT app.claim_document_import() AS j'))[0].j;
    if (!claimed || claimed.id === job) break;
    await asWorker('SELECT app.document_import_progress($1, NULL, $2, NULL)', [claimed.id, 'done']);
  }
});
afterAll(closePools);

describe('compra recebida', () => {
  const code = `C${randomInt(1e9)}`;
  const boxGtin = gtin();
  let first;
  let productId;

  it('entra no estoque com fornecedor, produto novo pelo GTIN, vínculo do código, custo e lotes', async () => {
    first = nfe({
      items: [
        item({ code, gtin: boxGtin, batches: [{ number: 'L1', quantity: 2, manufactured_on: '2026-01-01', expires_on: '2027-01-01' }] }),
        item({ line: 2, code: `${code}-B`, cfop: '5910', products_value: 5, freight: 0, total: 5, quantity: 1 }),
      ],
    });
    expect(await importNfe(first)).toMatchObject({ result: 'imported', kind: 'purchase' });
    const note = await noteByKey(first.access_key);
    expect(note).toMatchObject({ kind: 'purchase', own_issued: false, branch_id: a.branch1.id, party_document: supplierCnpj, counterpart_branch_id: null });
    const supplier = (await ownerPool.query('SELECT * FROM supplier WHERE id = $1', [note.supplier_id])).rows[0];
    expect([supplier.cnpj, supplier.legal_name, supplier.economic_group_id]).toEqual([supplierCnpj, 'DISTRIBUIDORA TESTE SA', a.group.id]);
    const items = await itemsOf(note.id);
    productId = items[0].product_id;
    expect(items.map((i) => [i.supplier_code, Number(i.quantity), i.unit_cost === null ? null : Number(i.unit_cost)])).toEqual([
      [code, 2, 11], [`${code}-B`, 1, null],
    ]);
    expect(items[0].batches).toEqual([{ number: 'L1', quantity: 2, manufactured_on: '2026-01-01', expires_on: '2027-01-01' }]);
    expect((await ownerPool.query('SELECT code, is_internal FROM product_barcode WHERE product_id = $1', [productId])).rows).toEqual([{ code: boxGtin, is_internal: false }]);
    expect((await ownerPool.query('SELECT legacy_code, own_ncm FROM product WHERE id = $1', [productId])).rows[0]).toEqual({ legacy_code: null, own_ncm: '30049099' });
    expect((await ownerPool.query('SELECT supplier_code FROM product_supplier WHERE product_id = $1 AND supplier_id = $2', [productId, note.supplier_id])).rows)
      .toEqual([{ supplier_code: code }]);
    expect(await balance(productId, a.branch1.id)).toBe(2);
    expect(await balance(items[1].product_id, a.branch1.id)).toBe(1);
    // Bonificação (5910) entra no estoque, sem custo.
    expect(Number(await costOf(productId, a.branch1.id))).toBe(11);
    expect(await costOf(items[1].product_id, a.branch1.id)).toBeNull();
    const movement = (await ownerPool.query('SELECT movement_type, occurred_at FROM stock_movement WHERE product_id = $1', [productId])).rows[0];
    expect(movement.movement_type).toBe('import');
    expect(movement.occurred_at.toISOString()).toBe('2026-05-10T13:00:00.000Z');
    // Fora do SNGPC.
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sngpc_movement WHERE product_id = $1', [productId])).rows[0].n).toBe(0);
  });

  it('próxima compra acha pelo vínculo; custo da mais recente vale, a mais antiga não troca; fracionamento do vínculo', async () => {
    const newer = nfe({ emitted_at: '2026-06-10T10:00:00-03:00', items: [item({ code, products_value: 30, freight: 0, quantity: 2 })] });
    await importNfe(newer);
    expect((await itemsOf((await noteByKey(newer.access_key)).id))[0].product_id).toBe(productId);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(15);
    const older = nfe({ emitted_at: '2026-04-10T10:00:00-03:00', items: [item({ code, products_value: 100, freight: 0, quantity: 2 })] });
    await importNfe(older);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(15);
    expect(await balance(productId, a.branch1.id)).toBe(6);
    // Caixa com 10 unidades: o vínculo diz o fracionamento.
    await ownerPool.query('UPDATE product_supplier SET fraction_quantity = 10 WHERE product_id = $1 AND supplier_code = $2', [productId, code]);
    const boxed = nfe({ emitted_at: '2026-07-10T10:00:00-03:00', items: [item({ code, products_value: 50, freight: 0, quantity: 1 })] });
    await importNfe(boxed);
    expect(Number((await itemsOf((await noteByKey(boxed.access_key)).id))[0].quantity)).toBe(10);
    expect(await balance(productId, a.branch1.id)).toBe(16);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(5);
  });

  it('produto que exige lote na filial entra e sai sem lote (o histórico não vira saldo por lote)', async () => {
    const tracked = `${code}-L`;
    const first = nfe({ items: [item({ code: tracked, quantity: 3 })] });
    await importNfe(first);
    const trackedId = (await itemsOf((await noteByKey(first.access_key)).id))[0].product_id;
    await ownerPool.query(
      `INSERT INTO product_branch_status (economic_group_id, product_id, branch_id, tracks_batches) VALUES ($1, $2, $3, true)
       ON CONFLICT DO NOTHING`, [a.group.id, trackedId, a.branch1.id],
    );
    await ownerPool.query('UPDATE product_branch_status SET tracks_batches = true WHERE product_id = $1 AND branch_id = $2', [trackedId, a.branch1.id]);
    expect(await importNfe(nfe({ items: [item({ code: tracked, quantity: 2 })] }))).toMatchObject({ result: 'imported' });
    expect(await balance(trackedId, a.branch1.id)).toBe(5);
  });

  it('GTIN de produto que já existe liga a ele, pelo código da unidade tributável também', async () => {
    const known = gtin();
    const client = await ownerPool.connect();
    let existing;
    try {
      await client.query('BEGIN');
      existing = (await client.query(
        "INSERT INTO product (economic_group_id, display_name) VALUES ($1, 'Já cadastrado') RETURNING id", [a.group.id],
      )).rows[0].id;
      await client.query('SELECT app.insert_product_barcode($1, $2, $3, false, true, true, true, NULL, NULL)', [a.group.id, existing, known]);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    const other = `${code}-T`;
    // GTIN do item inválido; o da unidade tributável acha o produto.
    const note = nfe({ items: [item({ code: other, gtin: '7890000000001', tax_gtin: known })] });
    await importNfe(note);
    expect((await itemsOf((await noteByKey(note.access_key)).id))[0].product_id).toBe(existing);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM product_supplier WHERE product_id = $1 AND supplier_code = $2', [existing, other])).rows[0].n).toBe(1);
  });

  it('custo de uma compra lançada no próprio sistema não é trocado pela importada', async () => {
    // Na filial 2 o custo é por filial: entra o da compra importada.
    const note = nfe({ dest: party(a.branch2.cnpj, 'Filial 2'), emitted_at: '2026-08-10T10:00:00-03:00', items: [item({ code, products_value: 70, freight: 0, quantity: 1 })] });
    await importNfe(note);
    expect(Number(await costOf(productId, a.branch2.id))).toBe(7);
    // Compra lançada no próprio sistema na filial 2 (montada direto no banco).
    const supplierId = (await noteByKey(note.access_key)).supplier_id;
    const invoice = (await ownerPool.query(
      `INSERT INTO purchase_invoice (economic_group_id, branch_id, supplier_id, access_key, series, number, issued_at, operation_type,
         purpose, environment, protocol_number, authorized_at, emitter_cnpj, emitter_name, products_total, invoice_total, status)
       VALUES ($1, $2, $3, $4, 1, 1, now(), 1, 1, 1, '135260000000077', now(), $5, 'DISTRIBUIDORA TESTE SA', 1, 1, 'posted') RETURNING id`,
      [a.group.id, a.branch2.id, supplierId, validKey(), supplierCnpj],
    )).rows[0].id;
    const invoiceItem = (await ownerPool.query(
      `INSERT INTO purchase_invoice_item (economic_group_id, branch_id, invoice_id, item_number, supplier_code, description, cfop, unit,
         quantity, unit_price, products_value, product_id, match_source)
       VALUES ($1, $2, $3, 1, $4, 'Item', '5102', 'UN', 1, 1, 1, $5, 'manual') RETURNING id`,
      [a.group.id, a.branch2.id, invoice, code, productId],
    )).rows[0].id;
    await ownerPool.query(
      `INSERT INTO product_cost (economic_group_id, branch_id, product_id, average_cost, stock_before, entry_quantity, entry_cost, purchase_invoice_item_id)
       VALUES ($1, $2, $3, 1.5, 0, 1, 1.5, $4)`,
      [a.group.id, a.branch2.id, productId, invoiceItem],
    );
    const newer = nfe({ dest: party(a.branch2.cnpj, 'Filial 2'), emitted_at: '2026-10-10T10:00:00-03:00', items: [item({ code, products_value: 80, freight: 0, quantity: 1 })] });
    await importNfe(newer);
    expect(Number(await costOf(productId, a.branch2.id))).toBe(1.5);
  });

  it('cancelamento devolve o estoque e tira o custo da compra cancelada', async () => {
    const before = await balance(productId, a.branch1.id);
    const cancelable = nfe({ emitted_at: '2026-09-10T10:00:00-03:00', items: [item({ code, products_value: 90, freight: 0, quantity: 1 })] });
    await importNfe(cancelable);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(9);
    expect(await balance(productId, a.branch1.id)).toBe(before + 10);
    await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [job, 'canc.xml', cancelable.access_key, '2026-09-11T10:00:00-03:00']);
    expect((await noteByKey(cancelable.access_key)).canceled_at).not.toBeNull();
    expect(await balance(productId, a.branch1.id)).toBe(before);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(5);
    // Cancelar de novo não devolve duas vezes.
    await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [job, 'canc2.xml', cancelable.access_key, null]);
    expect(await balance(productId, a.branch1.id)).toBe(before);
    const result = (await ownerPool.query("SELECT model, result FROM document_import_note WHERE entry_name = 'canc.xml' AND import_id = $1", [job])).rows[0];
    expect(result).toEqual({ model: '55', result: 'canceled' });
    // Com a de setembro cancelada, uma de agosto passa a ser a mais recente que vale.
    const august = nfe({ emitted_at: '2026-08-20T10:00:00-03:00', items: [item({ code, products_value: 60, freight: 0, quantity: 1 })] });
    await importNfe(august);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(6);
    // Cancelar uma compra cujo custo já foi substituído por outra mais nova não mexe no custo.
    const late = nfe({ emitted_at: '2026-11-01T10:00:00-03:00', items: [item({ code, products_value: 40, freight: 0, quantity: 1 })] });
    await importNfe(late);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(4);
    await asWorker('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [job, 'canc3.xml', august.access_key, null]);
    expect(Number(await costOf(productId, a.branch1.id))).toBe(4);
  });
});

describe('notas emitidas pelo cliente', () => {
  const ownCode = `P${randomInt(1e9)}`;
  const own = (overrides = {}) => nfe({ issuer: party(a.branch1.cnpj, 'Filial 1'), ...overrides });
  const productByCode = async () => (await ownerPool.query('SELECT id FROM product WHERE economic_group_id = $1 AND legacy_code = $2', [a.group.id, ownCode])).rows[0]?.id;

  it('venda a empresa vira venda importada (modelo 55) com o cliente e baixa o estoque', async () => {
    const sale = own({
      dest: { ...party(companyCustomer, 'CLINICA EXEMPLO LTDA') },
      items: [item({ code: ownCode, name: 'Produto próprio', cfop: '5102', quantity: 3, unit_price: 10, total: 30 })],
      payments: [{ type: '15', amount: 30 }], subtotal: 30, total: 30,
    });
    expect(await importNfe(sale)).toMatchObject({ result: 'imported', kind: 'sale' });
    const row = (await ownerPool.query('SELECT * FROM imported_sale WHERE access_key = $1', [sale.access_key])).rows[0];
    expect([row.model, row.branch_id, Number(row.total)]).toEqual(['55', a.branch1.id, 30]);
    const customer = (await ownerPool.query('SELECT document, name, person_type FROM customer WHERE id = $1', [row.customer_id])).rows[0];
    expect(customer).toEqual({ document: companyCustomer, name: 'CLINICA EXEMPLO LTDA', person_type: 'company' });
    expect(await balance(await productByCode(), a.branch1.id)).toBe(-3);
    expect(await noteByKey(sale.access_key)).toBeUndefined();
  });

  it('transferência entre filiais tira de uma e põe na outra; filial nova da mesma raiz é cadastrada', async () => {
    const transfer = own({ dest: party(a.branch2.cnpj, 'Filial 2'), items: [item({ code: ownCode, cfop: '5152', quantity: 4, total: 40 })] });
    expect(await importNfe(transfer)).toMatchObject({ result: 'imported', kind: 'transfer' });
    const note = await noteByKey(transfer.access_key);
    expect(note).toMatchObject({ kind: 'transfer', own_issued: true, branch_id: a.branch1.id, counterpart_branch_id: a.branch2.id });
    const productId = await productByCode();
    expect(await balance(productId, a.branch1.id)).toBe(-7);
    expect(await balance(productId, a.branch2.id)).toBe(4);
    const newCnpj = branchCnpj(a.root, 9);
    const toNew = own({ dest: party(newCnpj, 'Filial nova'), items: [item({ code: ownCode, cfop: '5152', quantity: 1, total: 10 })] });
    await importNfe(toNew);
    const created = (await ownerPool.query('SELECT b.id, c.economic_group_id FROM branch b JOIN company c ON c.id = b.company_id WHERE b.cnpj = $1', [newCnpj])).rows[0];
    expect(created.economic_group_id).toBe(a.group.id);
    expect(await balance(productId, created.id)).toBe(1);
  });

  it('devolução ao fornecedor e outras saídas baixam; entrada emitida pelo cliente soma', async () => {
    const productId = await productByCode();
    const back = own({ dest: party(supplierCnpj, 'DISTRIBUIDORA TESTE SA'), items: [item({ code: ownCode, cfop: '5202', quantity: 1, total: 10 })] });
    expect(await importNfe(back)).toMatchObject({ kind: 'supplier_return' });
    expect((await noteByKey(back.access_key)).supplier_id).not.toBeNull();
    const loss = own({ dest: party(companyCustomer, 'Alguém'), items: [item({ code: ownCode, cfop: '5927', quantity: 1, total: 10 })] });
    expect(await importNfe(loss)).toMatchObject({ kind: 'other_output' });
    const entry = own({ operation: '0', dest: { cpf: '11144477735', name: 'Consumidor' }, items: [item({ code: ownCode, cfop: '1202', quantity: 2, total: 20 })] });
    expect(await importNfe(entry)).toMatchObject({ kind: 'own_entry' });
    // Depois da venda (-3) e das transferências (-4 e -1): -8.
    expect(await balance(productId, a.branch1.id)).toBe(-8 - 1 - 1 + 2);
    expect((await noteByKey(entry.access_key)).party_document).toBe('11144477735');
  });

  it('o relatório mostra a última numeração das NF-e emitidas pelo cliente', async () => {
    const special = own({ series: 7, number: 999, dest: party(a.branch2.cnpj, 'Filial 2'), items: [item({ code: ownCode, cfop: '5152', quantity: 1, total: 10 })] });
    await importNfe(special);
    const report = (await asUser(a.admin, 'SELECT app.document_import_report($1) AS r', [job]))[0].r;
    expect(report.last_numbers).toEqual(expect.arrayContaining([expect.objectContaining({ branch_id: a.branch1.id, model: '55', series: 7, last_number: 999 })]));
    // Compra recebida (numeração do fornecedor) não conta como numeração do cliente.
    await importNfe(nfe({ series: 42, number: 4242, dest: party(a.branch2.cnpj, 'Filial 2') }));
    const after = (await asUser(a.admin, 'SELECT app.document_import_report($1) AS r', [job]))[0].r;
    expect(after.last_numbers.some((row) => row.series === 42)).toBe(false);
  });
});

describe('recebidas de terceiros e notas de fora', () => {
  it('devolução de cliente (empresa) entra no estoque, sem fornecedor', async () => {
    const back = nfe({ issuer: party(companyCustomer, 'CLINICA EXEMPLO LTDA'), items: [item({ cfop: '5202', quantity: 1 })] });
    expect(await importNfe(back)).toMatchObject({ kind: 'customer_return' });
    const note = await noteByKey(back.access_key);
    expect(note.supplier_id).toBeNull();
    expect(await balance((await itemsOf(note.id))[0].product_id, a.branch1.id)).toBe(1);
  });

  it('nota de fora, de entrada de terceiro, de homologação, sem autorização ou repetida não entra', async () => {
    const outsider = nfe({ dest: party(b.branch1.cnpj, 'Filial de outro cliente') });
    expect(await importNfe(outsider)).toMatchObject({ result: 'ignored', reason: expect.stringContaining('Nenhuma filial do cliente') });
    const thirdEntry = nfe({ operation: '0' });
    expect(await importNfe(thirdEntry)).toMatchObject({ result: 'ignored', reason: expect.stringContaining('entrada emitida por terceiro') });
    expect(await importNfe(nfe({ environment: '2' }))).toMatchObject({ result: 'ignored' });
    expect(await importNfe(nfe({ status_code: '' }))).toMatchObject({ result: 'ignored' });
    const once = nfe();
    expect(await importNfe(once)).toMatchObject({ result: 'imported' });
    expect(await importNfe(once)).toMatchObject({ result: 'duplicate' });
    for (const k of [outsider, thirdEntry]) expect(await noteByKey(k.access_key)).toBeUndefined();
    // O relatório conta as ignoradas por motivo.
    const report = (await asUser(a.admin, 'SELECT app.document_import_report($1) AS r', [job]))[0].r;
    expect(report.ignored_reasons).toEqual(expect.arrayContaining([
      { reason: expect.stringContaining('Nenhuma filial do cliente'), total: 1 },
      { reason: 'Nota de homologação, sem valor fiscal.', total: 1 },
    ]));
  });

  it('nota quebrada fica com problema, sem parar; só o processamento chama', async () => {
    expect(await importNfe(nfe({ items: [item({ quantity: 0 })] }))).toMatchObject({ result: 'failed', code: 'FA743' });
    expect(await importNfe(nfe({ model: '65' }))).toMatchObject({ result: 'failed', code: 'FA743' });
    await expect(asUser(a.admin, 'SELECT app.import_nfe($1, $2, $3::jsonb)', [job, 'x', JSON.stringify(nfe())])).rejects.toSatisfy(hasCode('FA002'));
  });

  it('natureza pelo CFOP', async () => {
    const kinds = (await ownerPool.query(
      `SELECT c, app.import_cfop_kind(c) AS k FROM unnest(ARRAY['5102','6108','5405','5656','5152','5409','5202','6411','5910','5927',NULL,'99']) c`,
    )).rows.map((r) => r.k);
    expect(kinds).toEqual(['sale', 'sale', 'sale', 'sale', 'transfer', 'transfer', 'return', 'return', 'other', 'other', 'other', 'other']);
  });
});
