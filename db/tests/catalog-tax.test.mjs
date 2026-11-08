import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { importCatalog } from '../scripts/lib.mjs';
import { appPool, asUser, closePools, connectionConfig, createFixtures, hasCode, ownerPool, setUser } from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

// asOwner desfaz tudo ao fim; aqui os dados precisam ficar para as outras conexões.
const committed = (fn) => fn(ownerPool);
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const key = () => `tax-${randomBytes(8).toString('hex')}`;
const simples = (overrides = {}) => ({
  regimes: [1], states: ['SP'], validFrom: '2026-01-01', cfop: '5405', origin: 0, icmsCsosn: '500', pisCst: '49', cofinsCst: '49', ...overrides,
});
const normal = (overrides = {}) => ({
  regimes: [3], states: ['SP'], validFrom: '2026-01-01', cfop: '5102', origin: 0, icmsCst: '00', icmsRate: 18,
  pisCst: '01', pisRate: 1.65, cofinsCst: '01', cofinsRate: 7.6, ...overrides,
});
const upsert = (sourceKey, taxes) => ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [
  JSON.stringify({ sourceKey, name: `Item ${sourceKey}`, ...(taxes === undefined ? {} : { taxes }) }),
]).then((r) => r.rows[0].id);
const rulesOf = (catalogId, activeOnly = true) => ownerPool.query(
  `SELECT * FROM catalog_product_tax WHERE catalog_product_id = $1 ${activeOnly ? 'AND deleted_at IS NULL' : ''}
    ORDER BY tax_regime, state, valid_from, created_at`,
  [catalogId],
).then((r) => r.rows);
const today = async () => (await ownerPool.query(`SELECT to_char(app.local_today(), 'YYYY-MM-DD') AS d`)).rows[0].d;
const shifted = async (days) => (await ownerPool.query(
  `SELECT to_char(app.local_today() + $1::int, 'YYYY-MM-DD') AS d`, [days],
)).rows[0].d;

// Produto do grupo A ligado a um item do Catálogo, com a filial no estado e a empresa no regime pedidos.
async function scenario(fixture, { regime = 1, state = 'SP', taxes, linked = true } = {}) {
  const sourceKey = key();
  const catalogId = await upsert(sourceKey, taxes);
  await committed(async (client) => {
    await client.query('UPDATE company SET tax_regime = $1 WHERE id = $2', [regime, fixture.company.id]);
    await client.query('UPDATE branch SET state = $1 WHERE id = $2', [state, fixture.branch1.id]);
  });
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, fixture.admin.id);
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${sourceKey}`,
      barcode: gtin(),
      ...(linked ? { catalogProductId: catalogId } : {}),
    })]);
    await client.query('COMMIT');
    return { catalogId, sourceKey, product: { id: rows[0].id } };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const resolve = (client, productId, branchId, on = null) =>
  client.query('SELECT * FROM app.resolve_product_tax($1, $2, $3)', [productId, branchId, on]).then((r) => r.rows);

describe('validações da regra', () => {
  it.each([
    ['CFOP fora da venda interna', simples({ cfop: '6102' }), 'cfop'],
    ['origem fora da tabela', simples({ origin: 9 }), 'origin'],
    ['cBenef com outro tamanho', simples({ benefitCode: 'ABC' }), 'benefit_code'],
    ['UF inexistente', simples({ states: ['ZZ'] }), 'state'],
    ['regime inexistente', normal({ regimes: [5] }), 'regime'],
    ['CSOSN inexistente', simples({ icmsCsosn: '999' }), 'icms_csosn'],
    ['CST inexistente', normal({ icmsCst: '99' }), 'icms_cst'],
    ['Simples com CST', simples({ icmsCsosn: null, icmsCst: '00', icmsRate: 18 }), 'icms_code'],
    ['Regime Normal com CSOSN', normal({ icmsCst: null, icmsCsosn: '102' }), 'icms_code'],
    ['Simples com CST e CSOSN', simples({ icmsCst: '60' }), 'icms_code'],
    ['CST 00 sem alíquota', normal({ icmsRate: null }), 'icms_rate'],
    ['alíquota de ICMS acima de 100', normal({ icmsRate: 101 }), 'icms_rate_range'],
    ['alíquota negativa', normal({ fcpRate: -1 }), 'fcp_rate'],
    ['CST com ST sem modalidade', normal({ icmsCst: '10', stRate: 18 }), 'st_required'],
    ['CST com ST sem alíquota', normal({ icmsCst: '10', stBaseMode: 1 }), 'st_required'],
    ['CSOSN com ST sem dados', simples({ icmsCsosn: '201' }), 'st_required'],
    ['ST em código sem ST', normal({ stBaseMode: 1, stRate: 18 }), 'st_allowed'],
    ['ST em CSOSN sem ST', simples({ stMva: 10 }), 'st_allowed'],
    ['modalidade MVA sem MVA', normal({ icmsCst: '10', stBaseMode: 4, stRate: 18 }), 'st_mva_required'],
    ['modalidade inexistente', normal({ icmsCst: '10', stBaseMode: 7, stRate: 18 }), 'st_base_mode'],
    ['CST de PIS de entrada', simples({ pisCst: '50' }), 'pis_cst'],
    ['CST de COFINS de entrada', simples({ cofinsCst: '50' }), 'cofins_cst'],
    ['PIS 01 sem alíquota', normal({ pisRate: null }), 'pis_rate'],
    ['COFINS 01 sem alíquota', normal({ cofinsRate: null }), 'cofins_rate'],
    ['IBS/CBS pela metade', simples({ ibsCbsCst: '000' }), 'ibs_cbs_group'],
    ['IBS/CBS sem cClassTrib', simples({ ibsCbsCst: '000', ibsStateRate: 0.1, ibsCityRate: 0, cbsRate: 0.9 }), 'ibs_cbs_group'],
    ['CST de IBS/CBS fora do formato', simples({ ibsCbsCst: '00', classTrib: '000001', ibsStateRate: 0.1, ibsCityRate: 0, cbsRate: 0.9 }), 'ibs_cbs_cst'],
    ['cClassTrib fora do formato', simples({ ibsCbsCst: '000', classTrib: '01', ibsStateRate: 0.1, ibsCityRate: 0, cbsRate: 0.9 }), 'class_trib'],
    ['redução sem o grupo IBS/CBS', simples({ ibsCbsReduction: 60 }), 'ibs_cbs_reduction'],
  ])('recusa %s com FA922', async (_label, entry, constraint) => {
    await expect(upsert(key(), [entry])).rejects.toMatchObject({ constraint: `catalog_product_tax_${constraint}_check` });
  });

  it('aceita ST válida, CST 90 com e sem ST e IBS/CBS completo', async () => {
    const catalogId = await upsert(key(), [
      normal({ icmsCst: '10', stBaseMode: 4, stMva: 33.5, stRate: 18, stFcpRate: 2 }),
      normal({ regimes: [2], icmsCst: '90', icmsRate: null }),
      normal({ states: ['PR'], icmsCst: '90', icmsRate: null, stBaseMode: 2, stRate: 19 }),
      simples({ ibsCbsCst: '200', classTrib: '200038', ibsStateRate: 0.1, ibsCityRate: 0, cbsRate: 0.9, ibsCbsReduction: 60 }),
    ]);
    expect(await rulesOf(catalogId)).toHaveLength(4);
  });
});

describe('importação', () => {
  it('uma entrada vale para vários regimes e UFs, com a UF em maiúscula', async () => {
    const catalogId = await upsert(key(), [simples({ regimes: [1, 4], states: ['sp', ' PR '] })]);
    const rules = await rulesOf(catalogId);
    expect(rules.map((r) => `${r.tax_regime}${r.state}`)).toEqual(['1PR', '1SP', '4PR', '4SP']);
  });

  it('importar de novo igual não gera linha nem muda a versão', async () => {
    const sourceKey = key();
    const catalogId = await upsert(sourceKey, [normal()]);
    const [before] = await rulesOf(catalogId);
    await upsert(sourceKey, [normal({ icmsRate: '18.00' })]);
    const after = await rulesOf(catalogId, false);
    expect(after).toHaveLength(1);
    expect(after[0].version).toBe(before.version);
    expect(after[0].updated_at).toEqual(before.updated_at);
  });

  it('a mesma regra com vigência nova não gera linha', async () => {
    const sourceKey = key();
    const catalogId = await upsert(sourceKey, [normal()]);
    await upsert(sourceKey, [normal({ validFrom: '2026-06-01' })]);
    expect(await rulesOf(catalogId, false)).toHaveLength(1);
  });

  it('um valor novo com vigência nova guarda o histórico', async () => {
    const sourceKey = key();
    const catalogId = await upsert(sourceKey, [normal()]);
    await upsert(sourceKey, [normal({ validFrom: '2026-06-01', icmsRate: 19 })]);
    const rules = await rulesOf(catalogId);
    expect(rules.map((r) => Number(r.icms_rate))).toEqual([18, 19]);
  });

  it('mudar qualquer campo gera linha nova', async () => {
    const sourceKey = key();
    const fullSt = { icmsCst: '10', stBaseMode: 4, stMva: 10, stRate: 18 };
    const ibs = { ibsCbsCst: '000', classTrib: '000001', ibsStateRate: 0.1, ibsCityRate: 0, cbsRate: 0.9 };
    const base = normal({ ...fullSt, ...ibs, fcpRate: 2, icmsBaseReduction: 1, stBaseReduction: 1, stFcpRate: 1, benefitCode: 'ABCD1234', ibsCbsReduction: 1 });
    const catalogId = await upsert(sourceKey, [base]);
    const changes = {
      cfop: '5403', origin: 1, benefitCode: 'ABCD1235', icmsRate: 17, icmsBaseReduction: 2, fcpRate: 3, stBaseMode: 1, stMva: 11, stRate: 17,
      stBaseReduction: 2, stFcpRate: 2, pisCst: '02', pisRate: 2, cofinsCst: '02', cofinsRate: 8, ibsCbsCst: '200', classTrib: '200038',
      ibsStateRate: 0.2, ibsCityRate: 0.1, cbsRate: 0.8, ibsCbsReduction: 2,
    };
    let expected = 1;
    let current = base;
    for (const [field, value] of Object.entries(changes)) {
      current = { ...current, [field]: value };
      await upsert(sourceKey, [current]);
      expected += 1;
      const rows = await ownerPool.query(
        'SELECT 1 FROM catalog_product_tax WHERE catalog_product_id = $1', [catalogId],
      );
      expect(rows.rowCount, `campo ${field}`).toBe(expected);
    }
  });

  it('a mesma vigência com outro valor substitui a anterior, sem apagar', async () => {
    const sourceKey = key();
    const catalogId = await upsert(sourceKey, [normal()]);
    await upsert(sourceKey, [normal({ icmsRate: 12 })]);
    const active = await rulesOf(catalogId);
    expect(active.map((r) => Number(r.icms_rate))).toEqual([12]);
    const all = await rulesOf(catalogId, false);
    expect(all).toHaveLength(2);
    expect(all.filter((r) => r.deleted_at !== null)).toHaveLength(1);
  });

  it('item sem o bloco mantém as regras', async () => {
    const sourceKey = key();
    const catalogId = await upsert(sourceKey, [normal()]);
    await upsert(sourceKey);
    expect(await rulesOf(catalogId)).toHaveLength(1);
  });

  it('uma regra de outra UF não mexe nas existentes', async () => {
    const sourceKey = key();
    const catalogId = await upsert(sourceKey, [normal()]);
    await upsert(sourceKey, [normal({ states: ['PR'], icmsRate: 12 })]);
    const rules = await rulesOf(catalogId);
    expect(rules.map((r) => `${r.state}${Number(r.icms_rate)}`)).toEqual(['PR12', 'SP18']);
  });

  it.each([
    ['campo desconhecido', [simples({ icmsAliquota: 18 })]],
    ['combinação repetida', [simples(), simples({ regimes: [1, 4] })]],
    ['bloco que não é lista', simples()],
    ['entrada que não é objeto', ['x']],
    ['sem regimes', [simples({ regimes: undefined })]],
    ['regimes vazio', [simples({ regimes: [] })]],
    ['sem estados', [simples({ states: undefined })]],
    ['sem vigência', [simples({ validFrom: undefined })]],
    ['sem CFOP', [simples({ cfop: undefined })]],
    ['sem origem', [simples({ origin: undefined })]],
    ['sem CST de PIS', [simples({ pisCst: undefined })]],
    ['sem CST de COFINS', [simples({ cofinsCst: undefined })]],
    ['mais de quatro casas', [normal({ icmsRate: 18.12345 })]],
  ])('recusa %s', async (_label, taxes) => {
    await expect(upsert(key(), taxes)).rejects.toSatisfy(hasCode('FA922'));
  });

  it('uma regra inválida cancela o arquivo inteiro, sem gravar o item bom', async () => {
    const good = key();
    const bad = key();
    const owner = connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD);
    await expect(importCatalog(owner, [
      { sourceKey: good, name: 'Bom', taxes: [simples()] },
      { sourceKey: bad, name: 'Ruim', taxes: [simples({ cfop: '6102' })] },
    ])).rejects.toThrow(new RegExp(bad));
    const { rows } = await ownerPool.query('SELECT 1 FROM catalog_product WHERE source_key = $1', [good]);
    expect(rows).toHaveLength(0);
  });

  it('a API não importa', async () => {
    const client = await appPool.connect();
    try {
      await expect(client.query(`SELECT app.upsert_catalog_product_taxes(gen_random_uuid(), '[]'::jsonb)`)).rejects.toMatchObject({ code: '42501' });
    } finally {
      client.release();
    }
  });
});

describe('histórico', () => {
  it('nenhum campo da regra muda, e a linha nunca é apagada', async () => {
    const catalogId = await upsert(key(), [normal()]);
    const [rule] = await rulesOf(catalogId);
    for (const change of ["cfop = '5403'", 'icms_rate = 1', "valid_from = '2020-01-01'", 'tax_regime = 2', "state = 'PR'", 'cbs_rate = 1', 'pis_rate = 1']) {
      await expect(ownerPool.query(`UPDATE catalog_product_tax SET ${change} WHERE id = $1`, [rule.id]), change).rejects.toSatisfy(hasCode('FA104'));
    }
    await expect(ownerPool.query('DELETE FROM catalog_product_tax WHERE id = $1', [rule.id])).rejects.toThrow();
  });

  it('o papel da API não escreve', async () => {
    const catalogId = await upsert(key(), [normal()]);
    const [rule] = await rulesOf(catalogId);
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT s');
      await expect(client.query('UPDATE catalog_product_tax SET deleted_at = now() WHERE id = $1', [rule.id])).rejects.toMatchObject({ code: '42501' });
      await client.query('ROLLBACK TO s');
      await expect(client.query(`INSERT INTO catalog_product_tax (catalog_product_id) VALUES ($1)`, [catalogId])).rejects.toMatchObject({ code: '42501' });
    });
  });
});

describe('resolução', () => {
  it('usa o regime da empresa e a UF da filial', async () => {
    const { product } = await scenario(a, {
      regime: 3, state: 'PR',
      taxes: [
        simples({ states: ['PR'] }),
        normal({ states: ['SP'], icmsRate: 18 }),
        normal({ states: ['PR'], icmsRate: 19 }),
      ],
    });
    await asUser(a.admin.id, async (client) => {
      const [row] = await resolve(client, product.id, a.branch1.id);
      expect(row).toMatchObject({ status: 'ok', tax_regime: 3, state: 'PR', icms_cst: '00', cfop: '5102' });
      expect(Number(row.icms_rate)).toBe(19);
    });
  });

  it('a mesma regra muda com a UF da filial, nas duas direções', async () => {
    const taxes = [normal({ states: ['SP'], icmsRate: 18 }), normal({ states: ['PR'], icmsRate: 19 }), normal({ states: ['RJ'], icmsRate: 20 })];
    const rateIn = async (state, product) => {
      if (!product) return scenario(a, { regime: 3, state, taxes });
      await ownerPool.query('UPDATE branch SET state = $1 WHERE id = $2', [state, a.branch1.id]);
      return asUser(a.admin.id, async (client) => Number((await resolve(client, product.id, a.branch1.id))[0].icms_rate));
    };
    const { product } = await rateIn('SP');
    expect(await rateIn('SP', product)).toBe(18);
    expect(await rateIn('PR', product)).toBe(19);
    expect(await rateIn('RJ', product)).toBe(20);
    await ownerPool.query('UPDATE branch SET state = $1 WHERE id = $2', ['MG', a.branch1.id]);
    await asUser(a.admin.id, async (client) => {
      expect((await resolve(client, product.id, a.branch1.id))[0].status).toBe('no_rule');
    });
    await ownerPool.query('UPDATE branch SET state = $1 WHERE id = $2', ['SP', a.branch1.id]);
  });

  it('escolhe a vigência certa na data, inclusive no próprio dia', async () => {
    const { product } = await scenario(a, {
      regime: 3,
      taxes: [
        normal({ validFrom: '2026-01-01', icmsRate: 17 }),
        normal({ validFrom: '2026-06-01', icmsRate: 18 }),
        normal({ validFrom: '2026-09-01', icmsRate: 19 }),
      ],
    });
    await asUser(a.admin.id, async (client) => {
      const rate = async (on) => Number((await resolve(client, product.id, a.branch1.id, on))[0].icms_rate);
      expect(await rate('2026-01-01')).toBe(17);
      expect(await rate('2026-05-31')).toBe(17);
      expect(await rate('2026-06-01')).toBe(18);
      expect(await rate('2026-08-31')).toBe(18);
      expect(await rate('2026-09-01')).toBe(19);
      const [before] = await resolve(client, product.id, a.branch1.id, '2025-12-31');
      expect(before.status).toBe('no_rule');
    });
  });

  it('sem data, vale hoje: regra futura ainda não vale', async () => {
    const { product } = await scenario(a, {
      regime: 3,
      taxes: [
        normal({ validFrom: await today(), icmsRate: 17 }),
        normal({ validFrom: await shifted(1), icmsRate: 18 }),
      ],
    });
    await asUser(a.admin.id, async (client) => {
      const [row] = await resolve(client, product.id, a.branch1.id);
      expect(Number(row.icms_rate)).toBe(17);
    });
  });

  it('a regra substituída não vale mais', async () => {
    const { product, sourceKey } = await scenario(a, { regime: 3, taxes: [normal()] });
    await upsert(sourceKey, [normal({ icmsRate: 12 })]);
    await asUser(a.admin.id, async (client) => {
      const [row] = await resolve(client, product.id, a.branch1.id);
      expect(Number(row.icms_rate)).toBe(12);
    });
  });

  it('explica cada falta', async () => {
    const withRule = await scenario(a, { regime: 3, taxes: [simples()] });
    await asUser(a.admin.id, async (client) => {
      expect((await resolve(client, withRule.product.id, a.branch1.id))[0]).toMatchObject({ status: 'no_rule', tax_id: null, tax_regime: 3, state: 'SP' });
    });
    const unlinked = await scenario(a, { regime: 3, linked: false, taxes: [normal()] });
    await asUser(a.admin.id, async (client) => {
      expect((await resolve(client, unlinked.product.id, a.branch1.id))[0].status).toBe('no_catalog');
    });
    const noRegime = await scenario(a, { regime: null, taxes: [normal()] });
    await asUser(a.admin.id, async (client) => {
      expect((await resolve(client, noRegime.product.id, a.branch1.id))[0].status).toBe('no_regime');
    });
    const noState = await scenario(a, { regime: 3, state: null, taxes: [normal()] });
    await asUser(a.admin.id, async (client) => {
      expect((await resolve(client, noState.product.id, a.branch1.id))[0].status).toBe('no_state');
    });
    await scenario(a, { regime: 3, state: 'SP', taxes: [normal()] });
  });

  it('outro grupo econômico não enxerga o produto nem a filial', async () => {
    const { product } = await scenario(a, { regime: 3, taxes: [normal()] });
    await asUser(b.admin.id, async (client) => {
      expect(await resolve(client, product.id, a.branch1.id)).toEqual([]);
      expect(await resolve(client, product.id, b.branch1.id)).toEqual([]);
    });
  });

  it('sem usuário, a API não lê regra nenhuma', async () => {
    const catalogId = await upsert(key(), [normal()]);
    const client = await appPool.connect();
    try {
      const { rows } = await client.query('SELECT 1 FROM v_catalog_product_tax WHERE catalog_product_id = $1', [catalogId]);
      expect(rows).toEqual([]);
    } finally {
      client.release();
    }
  });
});

describe('cobertura por filial', () => {
  const coverage = (client, branchId) => client.query('SELECT * FROM app.tax_coverage() WHERE branch_id = $1', [branchId]).then((r) => r.rows[0]);

  it('conta quem falta e ignora inativo e excluído', async () => {
    await committed(async (client) => {
      await client.query('UPDATE company SET tax_regime = 3 WHERE id = $1', [a.company.id]);
      await client.query(`UPDATE branch SET state = 'SP' WHERE id = $1`, [a.branch1.id]);
    });
    const before = await asUser(a.admin.id, (client) => coverage(client, a.branch1.id));

    await scenario(a, { regime: 3, taxes: [normal()] });
    let after = await asUser(a.admin.id, (client) => coverage(client, a.branch1.id));
    expect(Number(after.products_total)).toBe(Number(before.products_total) + 1);
    expect(Number(after.products_missing)).toBe(Number(before.products_missing));

    const noRule = await scenario(a, { regime: 3, taxes: [simples()] });
    await scenario(a, { regime: 3, linked: false });
    const future = await scenario(a, { regime: 3, taxes: [normal({ validFrom: await shifted(30) })] });
    after = await asUser(a.admin.id, (client) => coverage(client, a.branch1.id));
    expect(Number(after.products_total)).toBe(Number(before.products_total) + 4);
    expect(Number(after.products_missing)).toBe(Number(before.products_missing) + 3);

    await committed(async (client) => {
      await client.query(`UPDATE product_branch_status SET status = 'inactive' WHERE product_id = $1 AND branch_id = $2`, [noRule.product.id, a.branch1.id]);
      await client.query('UPDATE product SET deleted_at = now() WHERE id = $1', [future.product.id]);
    });
    after = await asUser(a.admin.id, (client) => coverage(client, a.branch1.id));
    expect(Number(after.products_total)).toBe(Number(before.products_total) + 2);
    expect(Number(after.products_missing)).toBe(Number(before.products_missing) + 1);
  });

  it('sem regime na empresa, todos faltam', async () => {
    const { product } = await scenario(a, { regime: null, taxes: [normal()] });
    const row = await asUser(a.admin.id, (client) => coverage(client, a.branch1.id));
    expect(row.products_total).toBe(row.products_missing);
    expect(product.id).toBeTruthy();
    await committed((client) => client.query('UPDATE company SET tax_regime = 3 WHERE id = $1', [a.company.id]));
  });

  it('só mostra filiais do grupo de quem pode ver o Fiscal', async () => {
    await asUser(b.admin.id, async (client) => {
      expect(await coverage(client, a.branch1.id)).toBeUndefined();
    });
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.oneBranchUser.id);
      const { rows } = await client.query('SELECT 1 FROM app.tax_coverage() WHERE branch_id = $1', [a.branch1.id]);
      expect(rows).toEqual([]);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
