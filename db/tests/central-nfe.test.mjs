import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot,
} from './helpers.mjs';

let a;
let b;
let manager;
let buyer;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const newUser = async (name) => (await ownerPool.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, name],
  )).rows[0];
  manager = await newUser('Gerente lançamento');
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [manager.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
  // O cancelar não vem no Gerente padrão: a rede dá no perfil (aqui, um perfil a mais do gerente).
  const { rows: [canceller] } = await ownerPool.query(
    `INSERT INTO role (economic_group_id, name) VALUES ($1, 'Cancela nota') RETURNING *`, [a.group.id],
  );
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code IN ('purchases.cancel', 'purchases.return')`, [canceller.id],
  );
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, canceller.id, a.branch1.id]);
  // Comprador: confere a nota, mas não lança nem vê custo de outra filial.
  const { rows: [role] } = await ownerPool.query(
    `INSERT INTO role (economic_group_id, name) VALUES ($1, 'Comprador') RETURNING *`, [a.group.id],
  );
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code IN ('purchases.view', 'purchases.manage')`,
    [role.id],
  );
  buyer = await newUser('Comprador lançamento');
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [buyer.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [buyer.id, role.id, a.branch1.id]);
});
// A filial emitente precisa dos dados fiscais completos (endereço, inscrição e regime).
beforeAll(async () => {
  await ownerPool.query(
    `UPDATE branch SET state = 'SP', state_registration = '110042490114', street = 'Rua das Flores', street_number = '100', district = 'Centro',
            city = 'São Paulo', city_code = '3550308', postal_code = '01001000'
      WHERE id = $1`,
    [a.branch1.id],
  );
  await ownerPool.query('UPDATE company SET tax_regime = 1 WHERE id = (SELECT company_id FROM branch WHERE id = $1)', [a.branch1.id]);
});
afterAll(closePools);

it('filial sem os dados fiscais completos não emite', async () => {
  const owner = await ownerPool.connect();
  try {
    await owner.query('BEGIN');
    await owner.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
    await owner.query('UPDATE branch SET street = NULL WHERE id = $1', [a.branch1.id]);
    const prod = await product(owner);
    const id = await invoiceFor(owner, prod, { quantity: '4', unitPrice: '10', productsValue: '40.00' });
    await post(owner, id);
    const [it] = await itemsOf(owner, id);
    const returnId = await devolve(owner, id, [{ itemId: it.id, quantity: 1 }]);
    await owner.query('SAVEPOINT s');
    await expect(owner.query('SELECT app.return_nfe_prepare($1)', [returnId])).rejects.toSatisfy(hasCode('FA724'));
    await owner.query('ROLLBACK TO s');
  } finally {
    await owner.query('ROLLBACK');
    owner.release();
  }
});

const cnpj = () => branchCnpj(randomRoot(), 1);
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
function accessKey(emitter, number) {
  const base = `352611${emitter}55001${String(number).padStart(9, '0')}1${String(randomInt(10_000_000, 99_999_999))}`;
  let total = 0;
  let weight = 2;
  for (let i = base.length - 1; i >= 0; i -= 1) {
    total += (base.charCodeAt(i) - 48) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const remainder = total % 11;
  return `${base}${remainder < 2 ? 0 : 11 - remainder}`;
}
const item = (overrides = {}) => ({
  number: 1, supplierCode: `C-${randomBytes(3).toString('hex')}`, barcode: null, description: 'ITEM DE TESTE', ncm: '30049099',
  cfop: '6102', unit: 'CX', quantity: '2.0000', unitPrice: '10.5', productsValue: '21.00', batches: [], ...overrides,
});
function invoice(overrides = {}) {
  const emitterCnpj = overrides.emitterCnpj ?? cnpj();
  const number = randomInt(1, 999_999_999);
  return {
    accessKey: accessKey(emitterCnpj, number), series: 1, number, issuedAt: '2026-11-20T10:00:00-03:00', operationType: 1,
    purpose: 1, environment: 2, protocolNumber: '135260000000001', authorizedAt: '2026-11-20T10:00:05-03:00',
    destCnpj: a.branch1.cnpj,
    emitter: { cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA DO LANCAMENTO LTDA', state: 'SP' },
    totals: { products: '21.00', invoice: '21.00' },
    items: [item()],
    ...overrides,
  };
}
const XML = '<nfeProc>conteúdo de teste</nfeProc>';
const importInvoice = (client, data) =>
  client.query('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, true) AS id', [
    JSON.stringify(data), XML, createHash('sha256').update(XML).digest('hex'),
  ]).then((r) => r.rows[0].id);
const createProduct = (client, data = {}) =>
  client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto ${randomBytes(4).toString('hex')}`, barcode: gtin(), ...data })])
    .then((r) => r.rows[0].id);
/** Produto com código de barras próprio: a nota com esse cEAN liga sozinha. */
async function product(client, data = {}) {
  const code = gtin();
  const id = await createProduct(client, { barcode: code, ...data });
  return { id, code };
}
/** Nota de um item do produto, com os valores informados. */
const invoiceFor = (client, prod, itemData = {}, invoiceData = {}) =>
  importInvoice(client, invoice({ items: [item({ barcode: prod.code, ...itemData })], ...invoiceData }));
const itemsOf = (client, invoiceId) =>
  client.query('SELECT * FROM purchase_invoice_item WHERE invoice_id = $1 ORDER BY item_number', [invoiceId]).then((r) => r.rows);
const post = (client, id) => client.query('SELECT app.post_purchase_invoice($1)', [id]);
const reverse = (client, id, reason = 'Produto ligado errado') => client.query('SELECT app.reverse_purchase_invoice($1, $2)', [id, reason]);
const release = (client, itemId, reason = 'Reajuste do fornecedor') => client.query('SELECT app.release_purchase_item_cost($1, $2)', [itemId, reason]);
const setBatches = (client, itemId, batches) => client.query('SELECT app.set_purchase_item_batches($1, $2::jsonb)', [itemId, JSON.stringify(batches)]);
const posting = (client, id) => client.query('SELECT * FROM app.purchase_invoice_posting($1)', [id]).then((r) => r.rows);
const averageCost = (client, productId, branchId = a.branch1.id) =>
  client.query(
    'SELECT average_cost FROM v_product_cost WHERE product_id = $1 AND branch_id = $2 ORDER BY created_at DESC, id DESC LIMIT 1',
    [productId, branchId],
  ).then((r) => r.rows[0]?.average_cost ?? null);
const stockOf = (client, productId, branchId = a.branch1.id) =>
  client.query('SELECT COALESCE(sum(quantity), 0)::text AS q FROM v_stock_balance WHERE product_id = $1 AND branch_id = $2', [productId, branchId])
    .then((r) => r.rows[0].q);
const statusOf = (client, id) => client.query('SELECT status FROM purchase_invoice WHERE id = $1', [id]).then((r) => r.rows[0].status);
const toleranceRule = (client, prod, value) =>
  client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({ typeCode: 'cost_tolerance', level: 'product', productLookup: prod.code, value })]);
const loss = (client, prod, quantity, batchNumber = null) =>
  client.query('SELECT app.register_stock_loss($1::jsonb)', [JSON.stringify({
    branchId: a.branch1.id, productLookup: prod.code, quantity, reason: 'Quebra', ...(batchNumber ? { batchNumber } : {}),
  })]);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
const devolve = (client, id, items, reason = 'Embalagem avariada') =>
  client.query('SELECT app.return_purchase_items($1, $2::jsonb, $3) AS id', [id, JSON.stringify(items), reason]).then((r) => r.rows[0].id);
const as = (client, user) => client.query(`SELECT set_config('app.user_id', $1, true)`, [user.id]);
const returnsOf = (client, id) => client.query('SELECT app.purchase_invoice_returns($1) AS x', [id]).then((r) => r.rows[0].x);
const audit = (client, id) => client.query('SELECT app.purchase_invoice_extra($1) AS x', [id]).then((r) => r.rows[0].x.audit);
const tracked = async (client, data = {}) => {
  const prod = await product(client, data);
  await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
  return prod;
};
const batchId = (client, prod, number) =>
  client.query('SELECT id FROM v_product_batch WHERE product_id = $1 AND batch_number = $2', [prod.id, number]).then((r) => r.rows[0].id);
const balances = (client, productId) =>
  client.query(
    `SELECT pb.batch_number, sb.quantity FROM v_stock_balance sb JOIN v_product_batch pb ON pb.id = sb.batch_id
      WHERE sb.product_id = $1 ORDER BY pb.batch_number`, [productId],
  ).then((r) => r.rows);

const prepare = (client, returnId) => client.query('SELECT app.return_nfe_prepare($1) AS x', [returnId]).then((r) => r.rows[0].x);
const store = (client, prepared, overrides = {}) => client.query(
  'SELECT app.return_nfe_store($1, $2, $3, $4, $5, $6, $7, $8) AS id',
  [prepared.returnId, overrides.series ?? prepared.series, overrides.number ?? prepared.number,
    overrides.key ?? `3526111122233300018155${String(prepared.series).padStart(3, '0')}${String(prepared.number).padStart(9, '0')}1112233440`,
    2, '<NFe>' + 'x'.repeat(200) + '</NFe>', '2026-11-27T16:00:00Z', prepared.totalValue],
).then((r) => r.rows[0].id);
const result = (client, id, value) => client.query('SELECT app.central_nfe_result($1, $2::jsonb) AS s', [id, JSON.stringify(value)]).then((r) => r.rows[0].s);
const supplierAddress = {
  legalName: 'DISTRIBUIDORA DO LANCAMENTO LTDA', stateRegistration: '110.042.490.114', postalCode: '01310100', street: 'Avenida Paulista',
  streetNumber: '1000', district: 'Bela Vista', city: 'São Paulo', cityCode: '3550308', state: 'SP', email: 'fiscal@fornecedor.test',
};
async function returned(client, itemData = {}) {
  const prod = await product(client);
  const id = await invoiceFor(client, prod, { quantity: '4', unitPrice: '10', productsValue: '40.00', ...itemData });
  await post(client, id);
  const [it] = await itemsOf(client, id);
  const { rows: [inv] } = await client.query('SELECT supplier_id, access_key, number FROM purchase_invoice WHERE id = $1', [id]);
  const returnId = await devolve(client, id, [{ itemId: it.id, quantity: 2 }]);
  return { prod, invoiceId: id, item: it, supplierId: inv.supplier_id, accessKey: inv.access_key, invoiceNumber: inv.number, returnId };
}

describe('NF-e de devolução emitida pela central', () => {
  it('sem endereço completo do fornecedor, avisa; com ele, prepara o espelho da devolução', async () => {
    await asUser(a.admin.id, async (client) => {
      const r = await returned(client, { discount: '4.00', freight: '2.00', ipi: '1.20', st: '0.80' });
      await expectCode(client, () => prepare(client, r.returnId), 'FA771');
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      const prepared = await prepare(client, r.returnId);
      expect(prepared).toMatchObject({ returnId: r.returnId, number: 1, totalValue: 20, hasCertificate: false });
      // A série é a menor que nenhum caixa da filial usa no modelo 55.
      const { rows: used } = await client.query("SELECT series FROM terminal_fiscal_series WHERE branch_id = $1 AND model = '55'", [a.branch1.id]);
      expect(used.map((u) => u.series)).not.toContain(prepared.series);
      expect(prepared.series).toBe([1, 2, 3, 4, 5].find((n) => !used.map((u) => u.series).includes(n)));
      const { input } = prepared;
      expect(input).toMatchObject({
        operation: 'DEVOLUCAO DE COMPRA', purpose: 4, presence: 0, finalConsumer: false, series: prepared.series, number: 1, references: [r.accessKey],
      });
      expect(input.recipient).toMatchObject({
        cnpj: expect.stringMatching(/^\d{14}$/), name: 'DISTRIBUIDORA DO LANCAMENTO LTDA', ieIndicator: 1, stateRegistration: '110042490114',
        street: 'Avenida Paulista', number: '1000', cityCode: '3550308', uf: 'SP', postalCode: '01310100', email: 'fiscal@fornecedor.test',
      });
      expect(input.items).toHaveLength(1);
      // Metade do item: 2 de 4 CX (a nota é na unidade da nota de compra).
      expect(input.items[0]).toMatchObject({
        unit: 'CX', quantityMilli: 2000, unitPriceCents: 1000, grossCents: 2000, discountCents: 200, freightCents: 100,
        ipiReturnedCents: 60, otherCents: 40, returnPercent: 50, ncm: '30049099',
      });
      // Com ST na compra: CFOP 5411 e, no Simples, CSOSN 500 (padrões a confirmar com o contador).
      expect(input.items[0].tax).toMatchObject({ cfop: '5411', icms_csosn: '500', pis_cst: '49', cofins_cst: '49' });
      expect(input.additionalInfo).toContain(`Devolução 1 da NF-e ${r.invoiceNumber} série 1 de `);
      expect(input.additionalInfo).toContain('Motivo: Embalagem avariada');
    });
  });

  it('sem ST usa o CFOP 5202; a regra da filial vale (e muda o CFOP)', async () => {
    await asUser(a.admin.id, async (client) => {
      const r = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      expect((await prepare(client, r.returnId)).input.items[0].tax.cfop).toBe('5202');
    });
  });

  it('numeração da central: série que nenhum caixa usa no modelo 55, um número por emissão', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [first.supplierId, JSON.stringify(supplierAddress)]);
      const p1 = await prepare(client, first.returnId);
      const id = await store(client, p1);
      expect(await result(client, id, { kind: 'rejected', status_code: '539', reason: 'Duplicidade' })).toBe('rejected');
      // Recusada: pode emitir de novo, com outro número.
      const p2 = await prepare(client, first.returnId);
      expect(p2.number).toBe(p1.number + 1);
      expect(p2.series).toBe(p1.series);
      // Número que não é o reservado não entra.
      await expectCode(client, () => store(client, p2, { number: p2.number + 5 }), 'FA931');
    });
  });

  it('pendente segura a devolução; a resposta da Sefaz autoriza e a nota não muda mais', async () => {
    await asUser(a.admin.id, async (client) => {
      const r = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      const prepared = await prepare(client, r.returnId);
      const id = await store(client, prepared);
      await expectCode(client, () => prepare(client, r.returnId), 'FA773');
      const { rows: pending } = await client.query('SELECT * FROM app.return_nfe_pending($1)', [r.returnId]);
      expect(pending).toEqual([expect.objectContaining({ id, environment: 2 })]);
      expect(await result(client, id, { kind: 'unavailable', reason: 'Sem resposta' })).toBe('pending');
      const procXml = '<nfeProc>' + 'y'.repeat(200) + '</nfeProc>';
      expect(await result(client, id, {
        kind: 'authorized', protocol: '135260000000777', authorized_at: '2026-11-27T16:00:05Z', xml: procXml, status_code: '100', reason: 'Autorizado o uso da NF-e',
      })).toBe('authorized');
      const { rows: [saved] } = await client.query('SELECT status, protocol, xml FROM central_nfe WHERE id = $1', [id]);
      expect(saved).toEqual({ status: 'authorized', protocol: '135260000000777', xml: procXml });
      // Já respondida: nada muda.
      expect(await result(client, id, { kind: 'rejected', status_code: '999', reason: 'x' })).toBe('authorized');
      await expectCode(client, () => prepare(client, r.returnId), 'FA773');
      const list = (await client.query('SELECT app.purchase_invoice_return_nfes($1) AS x', [r.invoiceId])).rows[0].x;
      expect(list).toEqual([expect.objectContaining({ id, return_id: r.returnId, status: 'authorized', protocol: '135260000000777', total_value: 20 })]);
      const { rows: [file] } = await client.query('SELECT * FROM app.central_nfe_xml($1)', [id]);
      expect(file).toMatchObject({ status: 'authorized', xml: procXml });
    });
  });

  it('contingência SVC: a pendente troca a chave e o XML uma vez só; a pendente diz a forma de emissão', async () => {
    await asUser(a.admin.id, async (client) => {
      const r = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      const prepared = await prepare(client, r.returnId);
      const id = await store(client, prepared);
      expect((await client.query('SELECT emission_type FROM app.return_nfe_pending($1)', [r.returnId])).rows).toEqual([{ emission_type: 1 }]);
      const svcKey = `3526111122233300018155${String(prepared.series).padStart(3, '0')}${String(prepared.number).padStart(9, '0')}6112233440`;
      const svcXml = '<NFe>' + 'z'.repeat(200) + '</NFe>';
      const contingency = (key, xml, type, noteId = id) =>
        client.query('SELECT app.central_nfe_contingency($1, $2, $3, $4::smallint)', [noteId, key, xml, type]);
      // Outro grupo não acha a nota; quem não emite NF-e na filial não troca.
      const as = (user) => client.query("SELECT set_config('app.user_id', $1, true)", [user.id]);
      await as(b.admin);
      await expectCode(client, () => contingency(svcKey, svcXml, 6), 'FA006');
      await as(buyer);
      await expectCode(client, () => contingency(svcKey, svcXml, 6), 'FA002');
      await as(a.admin);
      await contingency(svcKey, svcXml, 6);
      const { rows: [saved] } = await client.query('SELECT access_key, xml, emission_type, series, number::int AS number FROM central_nfe WHERE id = $1', [id]);
      expect(saved).toEqual({ access_key: svcKey, xml: svcXml, emission_type: 6, series: prepared.series, number: prepared.number });
      expect((await client.query('SELECT emission_type, access_key FROM app.return_nfe_pending($1)', [r.returnId])).rows)
        .toEqual([{ emission_type: 6, access_key: svcKey }]);
      // Já em SVC: não troca de novo, nem volta para a normal.
      await expectCode(client, () => contingency(svcKey.replace(/0$/, '1'), svcXml, 7), 'FA772');
      await expectCode(client, () => contingency(svcKey, svcXml, 1), 'FA772');
      await expectCode(client, () => contingency(svcKey, svcXml, 9), 'FA772');
      // Autorizada: não muda.
      await result(client, id, { kind: 'authorized', protocol: '135260000000778', authorized_at: '2026-11-27T16:00:05Z', xml: '<nfeProc>' + 'y'.repeat(200) + '</nfeProc>', status_code: '100', reason: 'Autorizado' });
      await expectCode(client, () => contingency(svcKey, svcXml, 7), 'FA772');
      // Nota normal já autorizada também não vai para a SVC.
      const other = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [other.supplierId, JSON.stringify(supplierAddress)]);
      const otherId = await store(client, await prepare(client, other.returnId));
      await result(client, otherId, { kind: 'authorized', protocol: '135260000000779', authorized_at: '2026-11-27T16:00:05Z', xml: '<nfeProc>' + 'w'.repeat(200) + '</nfeProc>', status_code: '100', reason: 'Autorizado' });
      await expectCode(client, () => contingency(svcKey.replace(/0$/, '9'), svcXml, 6, otherId), 'FA772');
      // Nem trocando só a chave (com o mesmo XML).
      await expectCode(client, () => contingency(svcKey.replace(/0$/, '9'), '<nfeProc>' + 'w'.repeat(200) + '</nfeProc>', 6, otherId), 'FA772');
    });
    await asUser(b.admin.id, async (client) => {
      await expectCode(client, () => client.query('SELECT app.central_nfe_contingency(gen_random_uuid(), $1, $2, 6::smallint)', ['1', '<x/>']), 'FA006');
    });
  });

  it('cancelamento: só a autorizada, até 24 horas, por quem emite; a devolução fica e aceita NF-e nova', async () => {
    const hoursAgo = (h) => new Date(Date.now() - h * 3_600_000).toISOString();
    const procXml = '<nfeProc>' + 'c'.repeat(200) + '</nfeProc>';
    const cancelEvent = {
      reason: 'Valores da devolução errados', protocol: '135260000000901', status_code: '135',
      xml: '<procEventoNFe>' + 'e'.repeat(200) + '</procEventoNFe>', registered_at: new Date().toISOString(),
    };
    await asUser(a.admin.id, async (client) => {
      const r = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      const prepared = await prepare(client, r.returnId);
      const id = await store(client, prepared);
      const context = (noteId) => client.query('SELECT * FROM app.central_nfe_cancel_context($1)', [noteId]).then((x) => x.rows);
      const register = (noteId) => client.query('SELECT app.central_nfe_cancel_register($1, $2::jsonb) AS s', [noteId, JSON.stringify(cancelEvent)])
        .then((x) => x.rows[0].s);
      const list = async () => (await client.query('SELECT app.purchase_invoice_return_nfes($1) AS x', [r.invoiceId])).rows[0].x;
      // Pendente não se cancela.
      await expectCode(client, () => context(id), 'FA787');
      await expectCode(client, () => register(id), 'FA787');
      const authorizedAt = hoursAgo(23);
      await result(client, id, { kind: 'authorized', protocol: '135260000000780', authorized_at: authorizedAt, xml: procXml, status_code: '100', reason: 'Autorizado' });
      expect((await context(id))[0]).toMatchObject({
        id, status: 'authorized', model: '55', emission_type: 1, protocol: '135260000000780', access_key: expect.stringMatching(/^\d{44}$/), state: 'SP',
      });
      expect(new Date((await list())[0].cancelable_until).getTime() - new Date(authorizedAt).getTime()).toBe(24 * 3_600_000);
      // Outro grupo não acha; quem não emite NF-e na filial não cancela.
      await as(client, b.admin);
      await expectCode(client, () => context(id), 'FA006');
      await expectCode(client, () => register(id), 'FA006');
      await as(client, buyer);
      await expectCode(client, () => context(id), 'FA002');
      await expectCode(client, () => register(id), 'FA002');
      await as(client, a.admin);
      const stockBefore = await stockOf(client, r.prod.id);
      expect(await register(id)).toBe('canceled');
      const { rows: [saved] } = await client.query(
        'SELECT status, protocol, xml, cancel_reason, cancel_protocol, canceled_by FROM central_nfe WHERE id = $1', [id],
      );
      expect(saved).toEqual({
        status: 'canceled', protocol: '135260000000780', xml: procXml, cancel_reason: 'Valores da devolução errados',
        cancel_protocol: '135260000000901', canceled_by: a.admin.id,
      });
      // Repetido: responde que está feito; o contexto volta como está.
      expect(await register(id)).toBe('canceled');
      expect((await context(id))[0]).toMatchObject({ status: 'canceled' });
      // A devolução e o estoque ficam; a lista mostra a cancelada sem prazo.
      expect(await stockOf(client, r.prod.id)).toBe(stockBefore);
      expect((await list())[0]).toMatchObject({ id, status: 'canceled', cancel_reason: 'Valores da devolução errados', cancelable_until: null });
      expect((await client.query('SELECT * FROM app.central_nfe_cancel_xml($1)', [id])).rows).toEqual([{ access_key: expect.any(String), xml: cancelEvent.xml }]);
      // A devolução aceita uma NF-e nova, com outro número.
      const again = await prepare(client, r.returnId);
      expect(again.number).toBe(prepared.number + 1);
      const second = await store(client, again);
      expect((await client.query('SELECT * FROM app.central_nfe_cancel_xml($1)', [second])).rows).toEqual([]);
      await expectCode(client, () => prepare(client, r.returnId), 'FA773');
      // Fora das 24 horas: FA786.
      const late = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [late.supplierId, JSON.stringify(supplierAddress)]);
      const lateId = await store(client, await prepare(client, late.returnId));
      await result(client, lateId, { kind: 'authorized', protocol: '135260000000781', authorized_at: hoursAgo(25), xml: procXml, status_code: '100', reason: 'Autorizado' });
      await expectCode(client, () => context(lateId), 'FA786');
      expect((await client.query('SELECT app.purchase_invoice_return_nfes($1) AS x', [late.invoiceId])).rows[0].x[0].cancelable_until).toBeNull();
    });
  });

  it('cancelada não volta e o cancelamento só se grava na passagem da autorizada', async () => {
    await asOwner(async (client) => {
      await as(client, a.admin);
      const r = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      const id = await store(client, await prepare(client, r.returnId));
      const update = (sql) => client.query(`UPDATE central_nfe SET ${sql} WHERE id = $1`, [id]);
      const cancelSql = `status = 'canceled', cancel_reason = 'Motivo com mais de quinze letras', cancel_protocol = '135260000000902',
        cancel_xml = repeat('e', 120), canceled_at = now(), canceled_by = '${a.admin.id}'`;
      // Pendente não vira cancelada, nem ganha dados de cancelamento.
      await expectCode(client, () => update(cancelSql + `, protocol = '135260000000782', authorized_at = now()`), 'FA772');
      await expectCode(client, () => update("cancel_reason = 'Motivo com mais de quinze letras'"), 'FA772');
      await update(`status = 'authorized', protocol = '135260000000782', authorized_at = now(), xml = repeat('p', 150)`);
      // Autorizada sem os dados do cancelamento não vira cancelada.
      await expectCode(client, () => update("status = 'canceled'"), 'FA931');
      // Nem com outro XML.
      await expectCode(client, () => update(cancelSql + ", xml = repeat('q', 150)"), 'FA772');
      await update(cancelSql);
      // Cancelada não volta nem muda o cancelamento.
      await expectCode(client, () => update("status = 'authorized'"), 'FA772');
      await expectCode(client, () => update("cancel_reason = 'Outro motivo com mais de quinze'"), 'FA772');
      await expectCode(client, () => update("xml = repeat('r', 150)"), 'FA772');
    });
  });

  it('só quem tem a permissão de emitir; outro grupo não enxerga', async () => {
    await asUser(a.admin.id, async (client) => {
      const r = await returned(client);
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
      await as(client, manager);
      await expectCode(client, () => prepare(client, r.returnId), 'FA002');
      await as(client, b.admin);
      await expectCode(client, () => prepare(client, r.returnId), 'FA006');
    });
    const { rows } = await ownerPool.query(
      `SELECT r.name FROM role_permission rp JOIN role r ON r.id = rp.role_id JOIN permission p ON p.id = rp.permission_id
        WHERE p.code = 'fiscal.nfe_issue' AND r.economic_group_id = $1 AND r.system_key IS NULL AND rp.deleted_at IS NULL`,
      [a.group.id],
    );
    expect(rows).toEqual([]);
  });

  it('fora do estado usa o CFOP 6xxx; regime normal leva a alíquota do ICMS da compra', async () => {
    const owner = await ownerPool.connect();
    try {
      await owner.query('BEGIN');
      await owner.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      await owner.query(`UPDATE branch SET state = 'SP' WHERE id = $1`, [a.branch1.id]);
      const company = (await owner.query('SELECT company_id FROM branch WHERE id = $1', [a.branch1.id])).rows[0].company_id;
      await owner.query('UPDATE company SET tax_regime = 3 WHERE id = $1', [company]);
      const r = await returned(owner);
      await owner.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify({ ...supplierAddress, state: 'PR', stateRegistration: null })]);
      await owner.query(
        `UPDATE purchase_invoice SET content = $2::jsonb, content_read_at = now() WHERE id = $1`,
        [r.invoiceId, JSON.stringify({ det: [{ '@_nItem': '1', imposto: { ICMS: { ICMS00: { orig: '2', CST: '00', pICMS: '12.00' } } } }] })],
      );
      const prepared = await prepare(owner, r.returnId);
      expect(prepared.input.recipient).toMatchObject({ uf: 'PR', ieIndicator: 9 });
      expect(prepared.input.items[0].tax).toMatchObject({ cfop: '6202', icms_cst: '00', icms_rate: 12, origin: 2 });
    } finally {
      await owner.query('ROLLBACK');
      owner.release();
    }
  });
});

describe('carta de correção da NF-e da central (CC-e)', () => {
  let stockOnly;
  beforeAll(async () => {
    const { rows: [role] } = await ownerPool.query(`INSERT INTO role (economic_group_id, name) VALUES ($1, 'Só estoque CC-e') RETURNING *`, [a.group.id]);
    await ownerPool.query("INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'stock.view'", [role.id]);
    stockOnly = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, 'Só estoque'])).rows[0];
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [stockOnly.id, a.branch1.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [stockOnly.id, role.id, a.branch1.id]);
  });
  const TEXT = 'Endereço de entrega: Rua das Acácias, 200';
  const event = (sequence, protocol, correction = TEXT) => ({
    sequence, correction, protocol, status_code: '135', xml: '<procEventoNFe>' + 'k'.repeat(200) + '</procEventoNFe>',
    registered_at: new Date().toISOString(),
  });
  const nfeXml = '<nfeProc>' + 'n'.repeat(200) + '</nfeProc>';
  async function authorizedNote(client, protocol) {
    const r = await returned(client);
    await client.query('SELECT app.update_supplier($1, $2::jsonb)', [r.supplierId, JSON.stringify(supplierAddress)]);
    const id = await store(client, await prepare(client, r.returnId));
    return { id, authorize: () => result(client, id, { kind: 'authorized', protocol, authorized_at: new Date().toISOString(), xml: nfeXml, status_code: '100', reason: 'Autorizado' }) };
  }
  const calls = (client, id) => ({
    context: (text = TEXT) => client.query("SELECT * FROM app.nfe_correction_context('central', $1, $2)", [id, text]).then((x) => x.rows),
    register: (value) => client.query("SELECT app.nfe_correction_register('central', $1, $2::jsonb) AS id", [id, JSON.stringify(value)]).then((x) => x.rows[0].id),
    screen: () => client.query("SELECT app.nfe_corrections('central', $1) AS x", [id]).then((x) => x.rows[0].x),
    file: (correctionId) => client.query('SELECT * FROM app.nfe_correction_file($1)', [correctionId]).then((x) => x.rows),
  });

  it('só a autorizada, com o texto que a Sefaz aceita; a sequência anda, o repetido devolve a mesma e o limite é 20', async () => {
    await asUser(a.admin.id, async (client) => {
      const note = await authorizedNote(client, '135260000000990');
      const { context, register, screen, file } = calls(client, note.id);
      // Pendente: não manda carta (nem registra), mas a tela abre.
      await expectCode(client, () => context(), 'FA787');
      await expectCode(client, () => register(event(1, '135260000000989')), 'FA787');
      expect(await screen()).toMatchObject({ status: 'pending', can_send: false, count: 0, corrections: [], note_kind: 'supplier_return' });
      await note.authorize();
      expect(await context()).toEqual([expect.objectContaining({ id: note.id, model: '55', sequence: 1, emission_type: 1, status: 'authorized' })]);
      // Texto: de 15 a 1000, numa linha, sem espaço nas pontas, sem símbolo fora do leiaute.
      await expectCode(client, () => context('Curto demais.'), 'FA790');
      await expectCode(client, () => context('x'.repeat(1001)), 'FA790');
      await expectCode(client, () => context('Primeira linha\nsegunda linha'), 'FA790');
      await expectCode(client, () => context(' Começa com espaço na frente'), 'FA790');
      await expectCode(client, () => context('Com emoji no meio 😀 do texto'), 'FA790');
      await expectCode(client, () => context(null), 'FA790');
      expect(await context('x'.repeat(1000))).toHaveLength(1);
      expect(await context('Ação: troca do CFOP é proibida; Ç ã ü º ª')).toHaveLength(1);

      const first = await register(event(1, '135260000000991'));
      // Pedido repetido (a mesma resposta da Sefaz): a mesma carta.
      expect(await register(event(1, '135260000000991'))).toBe(first);
      // A mesma sequência com outro protocolo: outra carta foi junto.
      await expectCode(client, () => register(event(1, '135260000000992', 'Outro texto com mais de quinze')), 'FA791');
      expect((await context())[0].sequence).toBe(2);
      // O que não é registro da Sefaz não grava.
      await expectCode(client, () => register(event(2, '135260000000993', 'Linha\nquebrada com mais de quinze')), 'FA790');
      await expectCode(client, () => register({ ...event(2, '135260000000993'), status_code: '573' }), 'FA792');
      await expectCode(client, () => register({ ...event(2, '13526') }), 'FA792');
      expect(await screen()).toMatchObject({
        count: 1, can_send: true, status: 'authorized', access_key: expect.any(String),
        corrections: [{ id: first, sequence: 1, correction: TEXT, protocol: '135260000000991', status_code: '135', requested_by: a.admin.name }],
      });
      expect(await file(first)).toEqual([{ access_key: expect.any(String), sequence: 1, xml: expect.stringContaining('procEventoNFe'), nfe_xml: nfeXml }]);
      // Quem vê a devolução e não emite NF-e: a tela diz que não pode mandar.
      await as(client, manager);
      expect(await screen()).toMatchObject({ count: 1, can_send: false });
      // Quem só vê o estoque não vê a nota da devolução (a da transferência, sim).
      await as(client, stockOnly);
      await expectCode(client, () => screen(), 'FA006');
      await as(client, a.admin);

      // 136 (registrada, ainda não vinculada) também vale; até 20 cartas, a última primeiro.
      await register({ ...event(2, '135260000001002'), status_code: '136' });
      for (let s = 3; s <= 20; s += 1) await register(event(s, String(135260000001000 + s)));
      await expectCode(client, () => context(), 'FA789');
      const full = await screen();
      expect(full).toMatchObject({ count: 20, can_send: false });
      expect(full.corrections.map((c) => c.sequence)).toEqual(Array.from({ length: 20 }, (_, i) => 20 - i));
      await expectCode(client, () => register(event(21, '135260000001021')), 'FA792');

      // Quem vê a devolução e não emite NF-e: vê as cartas, não manda.
      await as(client, manager);
      await expectCode(client, () => context(), 'FA002');
      await expectCode(client, () => register(event(21, '135260000001021')), 'FA002');
      expect(await screen()).toMatchObject({ count: 20, can_send: false });
      // Outro grupo não acha nada.
      await as(client, b.admin);
      await expectCode(client, () => screen(), 'FA006');
      await expectCode(client, () => context(), 'FA006');
      await expectCode(client, () => file(first), 'FA006');
      await expectCode(client, () => client.query("SELECT app.nfe_corrections('outra', $1)", [note.id]), 'FA005');
    });
  });

  it('cancelada: não manda carta nova, mas a que a Sefaz registrou no caminho fica registrada', async () => {
    await asUser(a.admin.id, async (client) => {
      const note = await authorizedNote(client, '135260000000994');
      await note.authorize();
      const { context, register, screen } = calls(client, note.id);
      expect((await context())[0].sequence).toBe(1);
      await client.query('SELECT app.central_nfe_cancel_register($1, $2::jsonb)', [note.id, JSON.stringify({
        reason: 'Valores da devolução errados', protocol: '135260000000995', status_code: '135',
        xml: '<procEventoNFe>' + 'e'.repeat(200) + '</procEventoNFe>', registered_at: new Date().toISOString(),
      })]);
      await expectCode(client, () => context(), 'FA787');
      const id = await register(event(1, '135260000000996'));
      expect(await screen()).toMatchObject({ status: 'canceled', can_send: false, count: 1, corrections: [{ id }] });
    });
  });

  it('registrada, a carta não muda', async () => {
    await asOwner(async (client) => {
      await as(client, a.admin);
      const note = await authorizedNote(client, '135260000000997');
      await note.authorize();
      const id = await calls(client, note.id).register(event(1, '135260000000998'));
      for (const sql of ["correction = 'Outro texto com mais de quinze'", "protocol = '135260000000999'", 'sequence = 2', "status_code = '136'", "xml = repeat('z', 150)"]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(`UPDATE nfe_correction SET ${sql} WHERE id = $1`, [id])).rejects.toThrow();
        await client.query('ROLLBACK TO s');
      }
    });
  });
});
