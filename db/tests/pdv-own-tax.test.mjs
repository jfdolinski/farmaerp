import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, branchCnpj, closePools, createFixtures, ownerPool, randomRoot, setUser } from './helpers.mjs';

// Tributação própria (vinda da importação das notas) descendo para o caixa quando o produto não
// tem os dados no Catálogo.

let a;
let job;
let branchId;
let productA;
let productB;
const XML = `<nfeProc versao="4.00">${'<z/>'.repeat(40)}</nfeProc>`;
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
const legacyA = `T${randomInt(1e6)}`;
const legacyB = `U${randomInt(1e6)}`;

const productData = async (productId) =>
  (await ownerPool.query('SELECT data FROM app.pdv_product_data($1, $2)', [branchId, [productId]])).rows[0].data;
const changeXid = async (productId) =>
  (await ownerPool.query(
    "SELECT xid::text AS x FROM sync_change WHERE entity = 'product' AND entity_id = $1 AND branch_id IS NULL AND deleted_at IS NULL",
    [productId],
  )).rows[0]?.x ?? null;

beforeAll(async () => {
  ({ a } = await createFixtures());
  job = (await asUser(a.admin, 'SELECT app.create_document_import($1, $2) AS id', ['trib.zip', 10]))[0].id;
  await asUser(a.admin, 'SELECT app.document_import_part($1, 1, 10)', [job]);
  await asUser(a.admin, 'SELECT app.complete_document_import($1)', [job]);
  for (let i = 0; i < 50; i += 1) {
    const claimed = (await asWorker('SELECT app.claim_document_import() AS j'))[0].j;
    if (!claimed || claimed.id === job) break;
    await asWorker('SELECT app.document_import_progress($1, NULL, $2, NULL)', [claimed.id, 'done']);
  }
  const note = {
    access_key: key(), model: '65', series: 1, number: randomInt(1, 1e6), emitted_at: '2026-06-10T10:00:00-03:00', environment: '1',
    status_code: '100', protocol: '135260000000003',
    issuer: {
      cnpj: issuerCnpj, name: 'FARMACIA TRIBUTOS LTDA', state_registration: 'ISENTO', crt: '1',
      street: 'Rua B', number: '2', district: 'Centro', city: 'São Paulo', city_code: '3550308', uf: 'SP', postal_code: '01001000',
    },
    customer: null,
    items: [
      { line: 1, code: legacyA, gtin: null, name: 'Com tributação', ncm: '30049099', cest: '1300100', quantity: 1, unit_price: 10,
        discount: 0, total: 10, cfop: '5405', tax: { origin: 0, icms_csosn: '500', pis_cst: '04', cofins_cst: '04', benefit_code: 'SP000001' } },
      { line: 2, code: legacyB, gtin: null, name: 'Sem PIS', ncm: '33049910', quantity: 1, unit_price: 5, discount: 0, total: 5,
        cfop: '5102', tax: { origin: 0, icms_csosn: '102' } },
    ],
    payments: [{ type: '01', amount: 15 }],
    subtotal: 15, discount: 0, total: 15, change: 0, xml: XML,
  };
  expect((await asWorker('SELECT app.import_nfce($1, $2, $3::jsonb) AS r', [job, 'n.xml', JSON.stringify(note)]))[0].r.result).toBe('imported');
  branchId = (await ownerPool.query('SELECT branch_id FROM imported_sale WHERE access_key = $1', [note.access_key])).rows[0].branch_id;
  const products = (await ownerPool.query(
    'SELECT id, legacy_code FROM product WHERE economic_group_id = $1 AND legacy_code = ANY ($2)', [a.group.id, [legacyA, legacyB]],
  )).rows;
  productA = products.find((p) => p.legacy_code === legacyA).id;
  productB = products.find((p) => p.legacy_code === legacyB).id;
});
afterAll(closePools);

describe('produto importado no caixa', () => {
  it('desce com o NCM, o CEST e a tributação próprios, no formato do Catálogo', async () => {
    const data = await productData(productA);
    expect(data).toMatchObject({ ncm: '30049099', cest: '1300100' });
    expect(data.taxes).toEqual([{
      id: expect.any(String), valid_from: '2026-06-10', cfop: '5405', origin: 0, benefit_code: 'SP000001',
      icms_cst: null, icms_csosn: '500', icms_rate: null, pis_cst: '04', pis_rate: null, cofins_cst: '04', cofins_rate: null, own: true,
    }]);
  });

  it('sem PIS e COFINS na nota, a regra não desce (o caixa avisa que falta a tributação)', async () => {
    const data = await productData(productB);
    expect(data).toMatchObject({ ncm: '33049910', cest: null, taxes: [] });
  });

  it('filial de outro regime ou UF não recebe a regra própria', async () => {
    const company = (await ownerPool.query('SELECT company_id FROM branch WHERE id = $1', [branchId])).rows[0].company_id;
    await ownerPool.query('UPDATE branch SET state = $1 WHERE id = $2', ['RJ', branchId]);
    expect((await productData(productA)).taxes).toEqual([]);
    await ownerPool.query('UPDATE branch SET state = $1 WHERE id = $2', ['SP', branchId]);
    await ownerPool.query('UPDATE company SET tax_regime = 3 WHERE id = $1', [company]);
    expect((await productData(productA)).taxes).toEqual([]);
    await ownerPool.query('UPDATE company SET tax_regime = 1 WHERE id = $1', [company]);
    expect((await productData(productA)).taxes).toHaveLength(1);
    // Regra apagada (exclusão lógica) não desce.
    await ownerPool.query('UPDATE product_tax_rule SET deleted_at = now() WHERE product_id = $1', [productA]);
    expect((await productData(productA)).taxes).toEqual([]);
    await ownerPool.query('UPDATE product_tax_rule SET deleted_at = NULL WHERE product_id = $1', [productA]);
    expect((await productData(productA)).taxes).toHaveLength(1);
  });

  it('mudança na regra própria faz o produto descer de novo', async () => {
    const before = await changeXid(productA);
    await ownerPool.query("UPDATE product_tax_rule SET cfop = '5102' WHERE product_id = $1", [productA]);
    const after = await changeXid(productA);
    expect(after).not.toBeNull();
    expect(BigInt(after)).toBeGreaterThan(BigInt(before ?? '0'));
    expect((await productData(productA)).taxes[0].cfop).toBe('5102');
  });

  it('com o Catálogo, vale a tributação dele; o NCM próprio só cobre o que falta', async () => {
    const sourceKey = `own-${randomBytes(6).toString('hex')}`;
    const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
      sourceKey, name: `Item ${sourceKey}`, ncm: '30042099',
      taxes: [{ regimes: [1], states: ['SP'], validFrom: '2026-01-01', cfop: '5405', origin: 0, icmsCsosn: '500', pisCst: '49', cofinsCst: '49' }],
    })])).rows[0].id;
    await ownerPool.query('UPDATE product SET catalog_product_id = $1 WHERE id = $2', [catalogId, productA]);
    const data = await productData(productA);
    expect(data).toMatchObject({ ncm: '30042099', cest: '1300100' });
    expect(data.taxes).toHaveLength(1);
    expect(data.taxes[0]).toMatchObject({ pis_cst: '49', valid_from: '2026-01-01' });
    expect(data.taxes[0]).not.toHaveProperty('own');
  });
});
