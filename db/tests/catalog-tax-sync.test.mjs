import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setUser } from './helpers.mjs';

// Tributação vinda do Catálogo externo (C2): o que buscar (item vinculado x estado com filial de
// chave), a regra dos dois regimes (com o código de ICMS convertido) e os motivos quando não fecha.

let a;
let b;
let stateA;

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
const asWorker = (sql, params) =>
  run((c) => c.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'catalog', true)"), sql, params);
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);

function gtin() {
  let base = '789';
  for (let i = 0; i < 9; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const hash = () => Array.from({ length: 64 }, () => '0123456789abcdef'[randomInt(16)]).join('');
const externalId = () => String(randomInt(1, 999_999_999));

/** Item do Catálogo (pela rotina) e, se pedido, um produto do grupo vinculado a ele. */
async function item({ origin = '0', pending = false, link = true, group = a } = {}) {
  const id = externalId();
  const itemHash = hash();
  await asWorker('SELECT app.catalog_sync_apply($1::jsonb)', [JSON.stringify([{
    sourceKey: `catalogo:${id}`, name: `Item tributado ${id}`, barcodes: [gtin()], pending, hash: itemHash, origin,
  }])]);
  const catalogId = (await ownerPool.query('SELECT id FROM catalog_product WHERE source_key = $1 AND deleted_at IS NULL', [`catalogo:${id}`])).rows[0].id;
  let productId = null;
  if (link) {
    productId = (await asUser(group.admin, 'SELECT app.create_product($1::jsonb) AS id', [
      JSON.stringify({ displayName: `Produto tributado ${id}`, barcode: gtin(), catalogProductId: catalogId }),
    ]))[0].id;
  }
  return { id, catalogId, itemHash, productId };
}
const due = () => asWorker('SELECT * FROM app.catalog_tax_due(1000)');
const applyTax = (it, result, state = stateA, branch = a.branch1) =>
  asWorker('SELECT app.catalog_tax_apply($1, $2, $3, $4, $5::jsonb) AS s', [it.catalogId, state, branch.id, it.itemHash, JSON.stringify(result)])
    .then((r) => r[0].s);
const rules = (it) => ownerPool.query(
  `SELECT tax_regime, state, cfop, origin, icms_cst, icms_csosn, icms_rate, st_base_mode, st_mva, st_rate, pis_cst, cofins_cst,
          ibs_cbs_reduction, valid_from::text AS valid_from
     FROM catalog_product_tax WHERE catalog_product_id = $1 AND deleted_at IS NULL ORDER BY tax_regime`, [it.catalogId],
).then((r) => r.rows);
const fetchRow = (it, state = stateA) => ownerPool.query(
  'SELECT status, message, source_icms_code, branch_id FROM catalog_tax_fetch WHERE catalog_product_id = $1 AND state = $2 AND deleted_at IS NULL',
  [it.catalogId, state],
).then((r) => r.rows[0]);
const VALUES = { cfop: '5405', cst_icms: '60', icms_rate: '', mva: '', cst_pis: '04', pis_rate: '0', cst_cofins: '04', cofins_rate: '0' };

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  // As filiais dos testes não têm estado: a busca precisa dele.
  await ownerPool.query("UPDATE branch SET state = 'SP' WHERE id = ANY ($1)", [[a.branch1.id, a.branch2.id, a.branchFree.id, b.branch1.id]]);
  stateA = 'SP';
  // Só a filial 1 do grupo A tem chave; o grupo B tem chave numa filial também.
  await asUser(a.admin, 'SELECT app.set_branch_catalog_key($1, $2, $3)', [a.branch1.id, randomBytes(48), 'cat_grupoa']);
  await asUser(b.admin, 'SELECT app.set_branch_catalog_key($1, $2, $3)', [b.branch1.id, randomBytes(48), 'cat_grupob']);
});
afterAll(closePools);

describe('conversão do código de ICMS', () => {
  it('CST vira CSOSN e CSOSN vira CST pela tabela; fora dela, nada', async () => {
    const convert = (code) => ownerPool.query('SELECT app.convert_icms_code($1) AS c', [code]).then((r) => r.rows[0].c);
    for (const [from, to] of [['00', '102'], ['10', '202'], ['20', '102'], ['30', '203'], ['40', '300'], ['41', '400'], ['50', '400'],
      ['51', '900'], ['60', '500'], ['70', '202'], ['90', '900'], ['101', '00'], ['102', '00'], ['103', '40'], ['201', '10'],
      ['202', '10'], ['203', '30'], ['300', '41'], ['400', '41'], ['500', '60'], ['900', '90']]) {
      expect(await convert(from), from).toBe(to);
    }
    expect(await convert('99')).toBeNull();
    expect(await convert(null)).toBeNull();
  });
});

describe('o que buscar', () => {
  it('item vinculado, no estado da filial com chave, com a chave dela; solto, pendente ou de grupo sem produto ficam de fora', async () => {
    const linked = await item();
    const loose = await item({ link: false });
    const pending = await item({ pending: true, link: false });
    const rows = await due();
    const mine = rows.filter((r) => r.catalog_product_id === linked.catalogId);
    expect(mine).toHaveLength(1);
    expect(mine[0]).toMatchObject({ external_id: linked.id, state: stateA, branch_id: a.branch1.id, item_hash: linked.itemHash });
    expect(mine[0].encrypted_key).toBeInstanceOf(Buffer);
    expect(rows.some((r) => r.catalog_product_id === loose.catalogId)).toBe(false);
    expect(rows.some((r) => r.catalog_product_id === pending.catalogId)).toBe(false);
    // Item que ficou pendente lá depois de vinculado sai da lista.
    await asWorker('SELECT app.catalog_sync_apply($1::jsonb)', [JSON.stringify([{ sourceKey: `catalogo:${linked.id}`, name: 'Agora pendente', pending: true, hash: linked.itemHash }])]);
    expect((await due()).some((r) => r.catalog_product_id === linked.catalogId)).toBe(false);
  });

  it('grupo sem chave no estado ou com chave só em filial sem estado não busca', async () => {
    const { a: c } = await createFixtures();
    // Filial 1 com chave e sem estado; filial 2 no estado, sem chave.
    await ownerPool.query("UPDATE branch SET state = 'SP' WHERE id = $1", [c.branch2.id]);
    await asUser(c.admin, 'SELECT app.set_branch_catalog_key($1, $2, $3)', [c.branch1.id, randomBytes(48), 'cat_grupoc']);
    const onlyC = await item({ group: c });
    expect((await due()).filter((r) => r.catalog_product_id === onlyC.catalogId)).toEqual([]);
  });

  it('depois da busca sai da lista; volta quando o item muda lá ou depois de um dia', async () => {
    const it2 = await item();
    expect(await applyTax(it2, { status: 'ok', values: VALUES })).toBe('ok');
    expect((await due()).some((r) => r.catalog_product_id === it2.catalogId)).toBe(false);
    await ownerPool.query("UPDATE catalog_product SET external_hash = $2 WHERE id = $1", [it2.catalogId, hash()]);
    expect((await due()).some((r) => r.catalog_product_id === it2.catalogId)).toBe(true);
    await applyTax({ ...it2, itemHash: (await ownerPool.query('SELECT external_hash FROM catalog_product WHERE id = $1', [it2.catalogId])).rows[0].external_hash },
      { status: 'ok', values: VALUES });
    expect((await due()).some((r) => r.catalog_product_id === it2.catalogId)).toBe(false);
    await ownerPool.query("UPDATE catalog_tax_fetch SET fetched_at = now() - interval '25 hours' WHERE catalog_product_id = $1", [it2.catalogId]);
    expect((await due()).some((r) => r.catalog_product_id === it2.catalogId)).toBe(true);
    // Buscada de novo: sai da lista até o dia seguinte.
    const current = (await ownerPool.query('SELECT external_hash FROM catalog_product WHERE id = $1', [it2.catalogId])).rows[0].external_hash;
    await applyTax({ ...it2, itemHash: current }, { status: 'ok', values: VALUES });
    expect((await due()).some((r) => r.catalog_product_id === it2.catalogId)).toBe(false);
  });

  it('origem fora de 0 a 8 fica vazia, sem recusar o item', async () => {
    const odd = await item({ origin: '9', link: false });
    expect((await ownerPool.query('SELECT tax_origin FROM catalog_product WHERE id = $1', [odd.catalogId])).rows[0].tax_origin).toBeNull();
    const fine = await item({ origin: '8', link: false });
    expect((await ownerPool.query('SELECT tax_origin FROM catalog_product WHERE id = $1', [fine.catalogId])).rows[0].tax_origin).toBe(8);
  });

  it('só a rotina busca e grava', async () => {
    await expect(asUser(a.admin, 'SELECT * FROM app.catalog_tax_due(10)')).rejects.toSatisfy(hasCode('FA002'));
    const it3 = await item();
    await expect(asUser(a.admin, 'SELECT app.catalog_tax_apply($1, $2, $3, $4, $5::jsonb)', [it3.catalogId, stateA, a.branch1.id, it3.itemHash, '{"status":"ok"}']))
      .rejects.toSatisfy(hasCode('FA002'));
  });
});

describe('a regra gravada', () => {
  it('CST do Catálogo vale no regime normal e vira CSOSN no Simples; com a origem do item e a ST pela MVA', async () => {
    const it4 = await item({ origin: '2' });
    expect(await applyTax(it4, { status: 'ok', values: { ...VALUES, cst_icms: '10', icms_rate: '18', mva: '35,5'.replace(',', '.'), icms_st_rate: '18' } })).toBe('ok');
    const saved = await rules(it4);
    expect(saved.map((r) => [r.tax_regime, r.icms_cst, r.icms_csosn])).toEqual([[1, null, '202'], [2, '10', null], [3, '10', null], [4, null, '202']]);
    for (const rule of saved) {
      expect(rule).toMatchObject({ state: stateA, cfop: '5405', origin: 2, st_base_mode: 4, pis_cst: '04', cofins_cst: '04' });
      expect(Number(rule.st_mva)).toBe(35.5);
      expect(Number(rule.icms_rate)).toBe(18);
    }
    expect(await fetchRow(it4)).toMatchObject({ status: 'ok', message: null, source_icms_code: '10', branch_id: a.branch1.id });
    // A mesma regra de novo não cria outra linha.
    await applyTax(it4, { status: 'ok', values: { ...VALUES, cst_icms: '10', icms_rate: '18', mva: '35.5', icms_st_rate: '18' } });
    expect(await rules(it4)).toHaveLength(4);
  });

  it('CSOSN do Catálogo vale no Simples e vira CST no regime normal; sem MVA não há modalidade de ST', async () => {
    const it5 = await item();
    await applyTax(it5, { status: 'ok', values: { ...VALUES, cst_icms: '500' } });
    expect((await rules(it5)).map((r) => [r.tax_regime, r.icms_cst, r.icms_csosn, r.st_base_mode])).toEqual([
      [1, null, '500', null], [2, '60', null, null], [3, '60', null, null], [4, null, '500', null],
    ]);
  });

  it('IBS/CBS entra com o grupo completo; reduções iguais viram a redução daqui, diferentes ficam vazias; grupo pela metade fica de fora', async () => {
    const REFORM = { cst_ibs_cbs: '200', c_class_trib: '200001', ibs_uf_rate: '0.1', ibs_mun_rate: '0', cbs_rate: '0.9' };
    const same = await item();
    expect(await applyTax(same, { status: 'ok', values: { ...VALUES, ...REFORM, ibs_uf_reduction: '60', ibs_mun_reduction: '60', cbs_reduction: '60' } })).toBe('ok');
    const sameRules = await rules(same);
    expect(sameRules).toHaveLength(4);
    expect(Number(sameRules[0].ibs_cbs_reduction)).toBe(60);
    const differ = await item();
    expect(await applyTax(differ, { status: 'ok', values: { ...VALUES, ...REFORM, ibs_uf_reduction: '60', cbs_reduction: '30' } })).toBe('ok');
    expect((await rules(differ))[0].ibs_cbs_reduction).toBeNull();
    const half = await item();
    expect(await applyTax(half, { status: 'ok', values: { ...VALUES, cst_ibs_cbs: '200', cbs_reduction: '60' } })).toBe('ok');
    const halfRules = await ownerPool.query('SELECT ibs_cbs_cst, ibs_cbs_reduction FROM catalog_product_tax WHERE catalog_product_id = $1 AND deleted_at IS NULL', [half.catalogId]);
    expect(halfRules.rows).toHaveLength(4);
    expect(halfRules.rows.every((r) => r.ibs_cbs_cst === null && r.ibs_cbs_reduction === null)).toBe(true);
  });

  it('o que não fecha fica com o motivo, e a regra anterior continua valendo', async () => {
    const it6 = await item();
    await applyTax(it6, { status: 'ok', values: VALUES });
    const before = await rules(it6);
    const cases = [
      [{ ...VALUES, cfop: '6102' }, 'CFOP de venda dentro do estado'],
      [{ ...VALUES, cfop: '' }, 'CFOP de venda dentro do estado'],
      [{ ...VALUES, cst_pis: '' }, 'PIS e do COFINS'],
      [{ ...VALUES, cst_cofins: '' }, 'PIS e do COFINS'],
      [{ ...VALUES, cst_icms: '99' }, 'fora da tabela: 99'],
      [{ ...VALUES, cst_icms: '' }, 'fora da tabela: vazio'],
      [{ ...VALUES, icms_rate: '12.12345' }, 'não fecha com as regras daqui'],
      [{ ...VALUES, cst_pis: '77' }, 'não fecha com as regras daqui'],
    ];
    for (const [values, reason] of cases) {
      expect(await applyTax(it6, { status: 'ok', values }), reason).toBe('incomplete');
      expect((await fetchRow(it6)).message, reason).toContain(reason);
    }
    expect(await rules(it6)).toEqual(before);
    expect(await applyTax(it6, { status: 'ok', values: {} })).toBe('no_rule');
    expect((await fetchRow(it6)).message).toContain('não tem regra');
    expect(await applyTax(it6, { status: 'not_found', message: 'Item não está mais no Catálogo.' })).toBe('not_found');
    expect(await applyTax(it6, { status: 'failed', message: 'O Catálogo não respondeu.' })).toBe('failed');
    expect(await fetchRow(it6)).toMatchObject({ status: 'failed', message: 'O Catálogo não respondeu.' });
    expect(await rules(it6)).toEqual(before);
    await expect(applyTax(it6, { status: 'qualquer' })).rejects.toSatisfy(hasCode('FA005'));

    // Sem origem no item: não grava.
    const noOrigin = await item({ origin: '' });
    expect(await applyTax(noOrigin, { status: 'ok', values: VALUES })).toBe('incomplete');
    expect((await fetchRow(noOrigin)).message).toContain('origem');
    expect(await rules(noOrigin)).toEqual([]);
  });
});

describe('na aba Tributação', () => {
  it('a cobertura mostra os que esperam a primeira busca, os com problema e se a filial tem chave; a lista traz o motivo', async () => {
    const waiting = await item();
    const broken = await item();
    const fine = await item();
    await applyTax(broken, { status: 'ok', values: { ...VALUES, cfop: '6102' } });
    await applyTax(fine, { status: 'ok', values: VALUES });
    for (const it of [waiting, broken]) {
      await ownerPool.query(
        "INSERT INTO product_branch_status (economic_group_id, product_id, branch_id, status) VALUES ($1, $2, $3, 'active') ON CONFLICT DO NOTHING",
        [a.group.id, it.productId, a.branch1.id],
      ).catch(() => undefined);
    }
    const coverage = await asUser(a.admin, 'SELECT * FROM app.tax_coverage()');
    const one = coverage.find((r) => r.branch_id === a.branch1.id);
    expect(one.has_catalog_key).toBe(true);
    expect(coverage.find((r) => r.branch_id === a.branchFree.id).has_catalog_key).toBe(false);
    const problems = await asUser(a.admin, 'SELECT * FROM app.catalog_tax_problems($1)', [a.branch1.id]);
    expect(problems.find((p) => p.product_id === broken.productId)).toMatchObject({ status: 'incomplete', message: expect.stringContaining('CFOP') });
    expect(problems.some((p) => p.product_id === waiting.productId)).toBe(false);
    expect(problems.some((p) => p.product_id === fine.productId)).toBe(false);
    expect(await asUser(b.admin, 'SELECT * FROM app.catalog_tax_problems($1)', [a.branch1.id])).toEqual([]);
  });
});
