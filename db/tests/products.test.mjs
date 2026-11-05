import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { importCatalog } from '../scripts/lib.mjs';
import {
  appPool, asOwner, asUser, closePools, connectionConfig, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

const ownerConfig = () =>
  connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD);

/** Cálculo independente do banco, para conferir a função SQL. */
function gtin(length = 13) {
  let base = '';
  for (let i = 0; i < length - 1; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const sourceKey = () => `teste-${randomBytes(6).toString('hex')}`;

const catalogItem = async (overrides = {}) => {
  const item = {
    sourceKey: sourceKey(),
    name: 'Ácido Acetilsalicílico Teste 100 mg',
    activeIngredient: 'Ácido acetilsalicílico',
    manufacturer: `Fabricante ${randomBytes(3).toString('hex')}`,
    msRegistration: '1234567890123',
    ncm: '30049099',
    barcodes: [gtin()],
    ...overrides,
  };
  const { rows } = await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify(item)]);
  return { ...item, id: rows[0].id };
};

const productData = (overrides = {}) => ({
  displayName: 'Produto Teste',
  barcode: gtin(),
  ...overrides,
});
const create = async (client, overrides = {}) =>
  (await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify(productData(overrides))])).rows[0].id;

/** As regras adiadas só rodam no fim da transação; os testes desfazem tudo, então antecipam. */
const flush = (client) => client.query('SET CONSTRAINTS ALL IMMEDIATE');

/** Confirma de verdade, como a API faz. */
async function committed(userId, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, userId);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

/** Dá um perfil com as permissões informadas, confirmado. */
async function userWith(group, codes, branch = null) {
  const client = await ownerPool.connect();
  try {
    await client.query('BEGIN');
    const { rows: [user] } = await client.query(
      'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *',
      [group.id, `Usuário ${randomBytes(3).toString('hex')}`],
    );
    const { rows: [role] } = await client.query(
      'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *',
      [group.id, `Perfil ${randomBytes(4).toString('hex')}`],
    );
    await client.query(
      'INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)',
      [role.id, codes],
    );
    if (branch) {
      await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
    }
    await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, branch?.id ?? null]);
    await client.query('COMMIT');
    return user;
  } finally {
    client.release();
  }
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('código de barras GTIN', () => {
  const valid = (code) => ownerPool.query('SELECT app.is_valid_gtin($1) AS ok', [code]).then((r) => r.rows[0].ok);

  it.each([8, 12, 13, 14])('aceita GTIN de %i dígitos com dígito certo', async (length) => {
    expect(await valid(gtin(length))).toBe(true);
  });

  it('recusa dígito verificador errado', async () => {
    const code = gtin();
    const wrong = `${code.slice(0, -1)}${(Number(code.at(-1)) + 1) % 10}`;
    expect(await valid(wrong)).toBe(false);
  });

  it.each(['123', '12345678901', '123456789012345', 'ABCDEFGHIJKLM', ''])('recusa %s sem quebrar', async (code) => {
    expect(await valid(code)).toBe(false);
  });
});

describe('busca: normalização', () => {
  it('ignora acentos e caixa', async () => {
    const { rows } = await ownerPool.query(`SELECT app.normalize_search('ÁCIDO Ação') AS text`);
    expect(rows[0].text).toBe('acido acao');
  });

  it('gera um padrão por palavra e escapa os caracteres especiais do LIKE', async () => {
    const { rows } = await ownerPool.query(`SELECT app.search_patterns('  50% a_b  ') AS p`);
    expect(rows[0].p).toEqual(['%50\\%%', '%a\\_b%']);
  });

  it('texto vazio não gera padrão', async () => {
    const { rows } = await ownerPool.query(`SELECT app.search_patterns('   ') AS p`);
    expect(rows[0].p).toEqual([]);
  });
});

describe('Catálogo', () => {
  it('a API só lê: não escreve em nenhuma tabela do Catálogo', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['catalog_manufacturer', 'catalog_product', 'catalog_product_barcode']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('a API não executa a importação', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(client.query(`SELECT app.upsert_catalog_product('{}'::jsonb)`)).rejects.toMatchObject({ code: '42501' });
    });
  });

  it('importar de novo o mesmo item não muda a versão nem duplica', async () => {
    const item = await catalogItem();
    const payload = { ...item };
    delete payload.id;
    const { rows: again } = await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify(payload)]);
    expect(again[0].id).toBe(item.id);
    const { rows } = await ownerPool.query(
      `SELECT version, (SELECT count(*)::int FROM catalog_product_barcode cb WHERE cb.catalog_product_id = cp.id) AS codes
         FROM catalog_product cp WHERE cp.id = $1`,
      [item.id],
    );
    expect(rows[0]).toEqual({ version: '1', codes: 1 });
  });

  it('item alterado atualiza e sobe a versão', async () => {
    const item = await catalogItem();
    const payload = { ...item, name: 'Nome novo', id: undefined };
    await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb)', [JSON.stringify(payload)]);
    const { rows } = await ownerPool.query('SELECT name, version FROM catalog_product WHERE id = $1', [item.id]);
    expect(rows[0]).toEqual({ name: 'Nome novo', version: '2' });
  });

  it('código que saiu do arquivo é excluído logicamente, e o novo entra', async () => {
    const oldCode = gtin();
    const newCode = gtin();
    const item = await catalogItem({ barcodes: [oldCode] });
    await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb)', [JSON.stringify({ ...item, id: undefined, barcodes: [newCode] })]);
    const { rows } = await ownerPool.query(
      'SELECT code, deleted_at IS NOT NULL AS gone FROM catalog_product_barcode WHERE catalog_product_id = $1',
      [item.id],
    );
    expect(rows).toEqual(expect.arrayContaining([{ code: oldCode, gone: true }, { code: newCode, gone: false }]));
  });

  it.each([
    ['NCM', { ncm: '123' }, 'catalog_product_ncm_check'],
    ['CEST', { cest: '12' }, 'catalog_product_cest_check'],
    ['MS', { msRegistration: 'abc' }, 'catalog_product_ms_registration_check'],
    ['controlado', { controlledClass: 'Z9' }, 'catalog_product_controlled_class_check'],
    ['código de barras', { barcodes: ['123'] }, 'catalog_product_barcode_gtin_check'],
  ])('recusa %s inválido com FA608', async (_label, overrides, constraint) => {
    await expect(catalogItem(overrides)).rejects.toMatchObject({ constraint });
    await expect(catalogItem(overrides)).rejects.toSatisfy(hasCode('FA608'));
  });

  it('a importação é tudo ou nada e diz qual item foi recusado', async () => {
    const good = sourceKey();
    const bad = sourceKey();
    await expect(
      importCatalog(ownerConfig(), [
        { sourceKey: good, name: 'Item bom', barcodes: [gtin()] },
        { sourceKey: bad, name: 'Item ruim', ncm: 'x', barcodes: [] },
      ]),
    ).rejects.toThrow(new RegExp(`Item 2 \\(${bad}\\) recusado`));
    const { rows } = await ownerPool.query('SELECT 1 FROM catalog_product WHERE source_key = $1', [good]);
    expect(rows).toEqual([]);
  });

  it('a importação grava e informa o total', async () => {
    const key = sourceKey();
    await expect(importCatalog(ownerConfig(), [{ sourceKey: key, name: 'Item', barcodes: [gtin()] }])).resolves.toBe(1);
    const { rows } = await ownerPool.query('SELECT name FROM catalog_product WHERE source_key = $1', [key]);
    expect(rows).toEqual([{ name: 'Item' }]);
  });

  it('recusa arquivo que não é lista', async () => {
    await expect(importCatalog(ownerConfig(), {})).rejects.toThrow(/lista de itens/);
  });

  it('todo usuário ativo do grupo lê o Catálogo, e sem usuário ninguém lê', async () => {
    const item = await catalogItem();
    await asUser(a.noBranchUser.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM v_catalog_product WHERE id = $1', [item.id]);
      expect(rows).toHaveLength(1);
    });
    await asUser(null, async (client) => {
      const { rows } = await client.query('SELECT id FROM v_catalog_product WHERE id = $1', [item.id]);
      expect(rows).toEqual([]);
    });
  });
});

describe('criar produto', () => {
  it('gera código humano e grava o principal', async () => {
    await asUser(a.admin.id, async (client) => {
      const barcode = gtin();
      const id = await create(client, { barcode });
      await flush(client);
      const { rows: [product] } = await client.query('SELECT * FROM v_product WHERE id = $1', [id]);
      expect(Number(product.code)).toBeGreaterThan(0);
      expect(product.updated_by).toBe(a.admin.id);
      const { rows } = await client.query('SELECT code, is_primary FROM v_product_barcode WHERE product_id = $1', [id]);
      expect(rows).toEqual([{ code: barcode, is_primary: true }]);
    });
  });

  it('o código enviado pela API é ignorado', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { code: 999999 });
      const { rows } = await client.query('SELECT code FROM v_product WHERE id = $1', [id]);
      expect(Number(rows[0].code)).not.toBe(999999);
    });
  });

  it('o código humano não muda depois do cadastro', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      const id = await create(client);
      await expect(client.query('UPDATE product SET code = code + 1000 WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('recusa produto sem código principal', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(create(client, { barcode: '  ' })).rejects.toSatisfy(hasCode('FA603'));
    });
  });

  it('recusa nome vazio', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(create(client, { displayName: '  ' })).rejects.toSatisfy(hasCode('FA216'));
    });
  });

  it('recusa fracionamento zero ou negativo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(create(client, { fractionQuantity: 0 })).rejects.toSatisfy(hasCode('FA609'));
    });
  });

  it('código de loja só passa sem dígito válido se marcado como interno', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT s');
      await expect(create(client, { barcode: 'LOJA-1' })).rejects.toSatisfy(hasCode('FA602'));
      await client.query('ROLLBACK TO s');
      await expect(create(client, { barcode: '12345' })).rejects.toSatisfy(hasCode('FA602'));
      await client.query('ROLLBACK TO s');
      const id = await create(client, { barcode: 'LOJA1', barcodeIsInternal: true });
      expect(id).toBeTruthy();
    });
  });

  it('o mesmo código de barras não entra em dois produtos do grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const barcode = gtin();
      await create(client, { barcode });
      await expect(create(client, { barcode })).rejects.toSatisfy(hasCode('FA601'));
    });
  });

  it('o mesmo código de barras pode existir em outro grupo', async () => {
    const barcode = gtin();
    await committed(a.admin.id, (client) => create(client, { barcode }));
    await committed(b.admin.id, (client) => create(client, { barcode }));
  });

  it('código excluído pode ser usado de novo', async () => {
    await asUser(a.admin.id, async (client) => {
      const code = gtin();
      const id = await create(client);
      const { rows } = await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [id, JSON.stringify({ code })]);
      await client.query('SELECT app.remove_barcode($1)', [rows[0].id]);
      await create(client, { barcode: code });
    });
  });
});

describe('produto com Catálogo', () => {
  it('copia os demais códigos do item, menos os que a rede já usa em outro produto', async () => {
    const [first, second, taken] = [gtin(), gtin(), gtin()];
    const item = await catalogItem({ barcodes: [first, second, taken] });
    await asUser(a.admin.id, async (client) => {
      await create(client, { barcode: taken });
      const id = await create(client, { catalogProductId: item.id, barcode: first });
      await flush(client);
      const { rows } = await client.query(
        'SELECT code, is_primary FROM v_product_barcode WHERE product_id = $1 ORDER BY is_primary DESC',
        [id],
      );
      expect(rows).toEqual([{ code: first, is_primary: true }, { code: second, is_primary: false }]);
    });
  });

  it('o fabricante próprio é ignorado quando há Catálogo', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { catalogProductId: item.id, barcode: item.barcodes[0], ownManufacturer: 'Outro' });
      const { rows } = await client.query('SELECT own_manufacturer FROM v_product WHERE id = $1', [id]);
      expect(rows[0].own_manufacturer).toBeNull();
    });
  });

  it('o mesmo item do Catálogo não entra duas vezes no grupo', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      await create(client, { catalogProductId: item.id, barcode: item.barcodes[0] });
      await expect(create(client, { catalogProductId: item.id })).rejects.toSatisfy(hasCode('FA604'));
    });
  });

  it('dois grupos podem usar o mesmo item do Catálogo', async () => {
    const item = await catalogItem();
    await committed(a.admin.id, (client) => create(client, { catalogProductId: item.id, barcode: item.barcodes[0] }));
    await committed(b.admin.id, (client) => create(client, { catalogProductId: item.id, barcode: item.barcodes[0] }));
  });

  it('recusa item do Catálogo que não existe', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(create(client, { catalogProductId: '019a0000-0000-7000-8000-0000000fffff' })).rejects.toSatisfy(hasCode('FA004'));
    });
  });

  it('produto sem Catálogo pode ser vinculado depois, e o fabricante próprio sai', async () => {
    const item = await catalogItem();
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { ownManufacturer: 'Fabricante próprio' });
      await client.query('SELECT app.update_product($1, $2::jsonb)', [
        id,
        JSON.stringify({ displayName: 'Vinculado', catalogProductId: item.id, ownManufacturer: 'Fabricante próprio' }),
      ]);
      const { rows } = await client.query('SELECT catalog_product_id, own_manufacturer, display_name FROM v_product WHERE id = $1', [id]);
      expect(rows[0]).toEqual({ catalog_product_id: item.id, own_manufacturer: null, display_name: 'Vinculado' });
    });
  });
});

describe('regras adiadas no fim da transação', () => {
  it('confirmar sem principal é recusado, por qualquer caminho', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(
        `INSERT INTO product (economic_group_id, display_name) VALUES ($1, 'Sem código')`,
        [a.group.id],
      );
      await expect(client.query('COMMIT')).rejects.toSatisfy(hasCode('FA603'));
    } finally {
      await client.query('ROLLBACK').catch(() => {});
      client.release();
    }
  });

  it('remover o principal é recusado ao confirmar, e o código continua lá', async () => {
    const barcode = gtin();
    const id = await committed(a.admin.id, (client) => create(client, { barcode }));
    const { rows: [primary] } = await ownerPool.query(
      'SELECT id FROM product_barcode WHERE product_id = $1 AND is_primary', [id],
    );
    await expect(
      committed(a.admin.id, (client) => client.query('SELECT app.remove_barcode($1)', [primary.id])),
    ).rejects.toSatisfy(hasCode('FA603'));
    const { rows } = await ownerPool.query('SELECT deleted_at FROM product_barcode WHERE id = $1', [primary.id]);
    expect(rows[0].deleted_at).toBeNull();
  });

  it('trocar o principal confirma com exatamente um', async () => {
    const id = await committed(a.admin.id, (client) => create(client));
    const other = await committed(a.admin.id, async (client) =>
      (await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [id, JSON.stringify({ code: gtin() })])).rows[0].id,
    );
    await committed(a.admin.id, (client) => client.query('SELECT app.set_primary_barcode($1)', [other]));
    const { rows } = await ownerPool.query(
      'SELECT id FROM product_barcode WHERE product_id = $1 AND is_primary AND deleted_at IS NULL', [id],
    );
    expect(rows).toEqual([{ id: other }]);
  });

  it('depois de trocar, o antigo principal pode ser removido', async () => {
    const id = await committed(a.admin.id, (client) => create(client));
    const { rows: [old] } = await ownerPool.query('SELECT id FROM product_barcode WHERE product_id = $1', [id]);
    const other = await committed(a.admin.id, async (client) =>
      (await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [id, JSON.stringify({ code: gtin() })])).rows[0].id,
    );
    await committed(a.admin.id, async (client) => {
      await client.query('SELECT app.set_primary_barcode($1)', [other]);
      await client.query('SELECT app.remove_barcode($1)', [old.id]);
    });
  });
});

describe('códigos de barras', () => {
  it('o principal precisa estar ativo na leitura', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      const { rows: [primary] } = await client.query('SELECT id FROM v_product_barcode WHERE product_id = $1', [id]);
      await expect(
        client.query('SELECT app.update_barcode($1, $2::jsonb)', [primary.id, JSON.stringify({ scanEnabled: false })]),
      ).rejects.toSatisfy(hasCode('FA606'));
    });
  });

  it('código com leitura desligada não vira principal', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      const { rows: [{ id: other }] } = await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [
        id, JSON.stringify({ code: gtin(), scanEnabled: false }),
      ]);
      await expect(client.query('SELECT app.set_primary_barcode($1)', [other])).rejects.toSatisfy(hasCode('FA606'));
    });
  });

  it('o código em si não muda: precisa remover e incluir', async () => {
    const id = await committed(a.admin.id, (client) => create(client));
    await expect(
      ownerPool.query(`UPDATE product_barcode SET code = '7890000000017' WHERE product_id = $1`, [id]),
    ).rejects.toSatisfy(hasCode('FA104'));
  });

  it('canais: inclui, retira e guarda o histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      const channel = async (name) => (await client.query('SELECT app.create_sales_channel($1) AS id', [name])).rows[0].id;
      const [one, two] = [await channel('Canal Um'), await channel('Canal Dois')];
      const id = await create(client);
      const { rows: [{ id: barcode }] } = await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [
        id, JSON.stringify({ code: gtin(), channels: [one] }),
      ]);
      await client.query('SELECT app.update_barcode($1, $2::jsonb)', [barcode, JSON.stringify({ channels: [two] })]);
      const { rows: active } = await client.query('SELECT channel_id FROM v_product_barcode_channel WHERE barcode_id = $1', [barcode]);
      expect(active).toEqual([{ channel_id: two }]);
      const { rows: all } = await client.query('SELECT channel_id FROM product_barcode_channel WHERE barcode_id = $1', [barcode]);
      expect(all).toHaveLength(2);
    });
  });

  it('não vincula canal de outro grupo', async () => {
    const other = await committed(b.admin.id, async (client) =>
      (await client.query('SELECT app.create_sales_channel($1) AS id', [`Canal B ${randomBytes(3).toString('hex')}`])).rows[0].id,
    );
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(
        client.query('SELECT app.add_barcode($1, $2::jsonb)', [id, JSON.stringify({ code: gtin(), channels: [other] })]),
      ).rejects.toSatisfy(hasCode('FA004'));
    });
  });

  it('canal em uso não pode ser excluído', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [{ id: channel }] } = await client.query(`SELECT app.create_sales_channel('Em uso') AS id`);
      const id = await create(client);
      await client.query('SELECT app.add_barcode($1, $2::jsonb)', [id, JSON.stringify({ code: gtin(), channels: [channel] })]);
      await expect(client.query('SELECT app.delete_sales_channel($1)', [channel])).rejects.toSatisfy(hasCode('FA105'));
    });
  });
});

describe('fracionamento', () => {
  it('o código de barras prevalece sobre o produto', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { fractionQuantity: 10 });
      const { rows: [{ id: withFraction }] } = await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [
        id, JSON.stringify({ code: gtin(), fractionQuantity: 30 }),
      ]);
      const { rows: [{ id: without }] } = await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [
        id, JSON.stringify({ code: gtin() }),
      ]);
      const fraction = async (barcode) =>
        Number((await client.query('SELECT app.effective_fraction($1, $2) AS f', [id, barcode])).rows[0].f);
      expect(await fraction(withFraction)).toBe(30);
      expect(await fraction(without)).toBe(10);
      expect(await fraction(null)).toBe(10);
    });
  });

  it('código de outro produto não interfere', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await create(client, { fractionQuantity: 10 });
      const second = await create(client);
      const { rows: [{ id: barcode }] } = await client.query('SELECT app.add_barcode($1, $2::jsonb) AS id', [
        second, JSON.stringify({ code: gtin(), fractionQuantity: 30 }),
      ]);
      const { rows } = await client.query('SELECT app.effective_fraction($1, $2) AS f', [first, barcode]);
      expect(Number(rows[0].f)).toBe(10);
    });
  });
});

describe('estrutura', () => {
  const category = async (client, parent, name) =>
    (await client.query('SELECT app.create_product_category($1, $2) AS id', [parent, name])).rows[0].id;

  it('monta departamento > categoria > subcategoria e recusa o quarto nível', async () => {
    await asUser(a.admin.id, async (client) => {
      const department = await category(client, null, 'Depto');
      const middle = await category(client, department, 'Cat');
      const leaf = await category(client, middle, 'Sub');
      const { rows } = await client.query('SELECT level FROM v_product_category WHERE id = $1', [leaf]);
      expect(rows[0].level).toBe(3);
      await expect(category(client, leaf, 'Quarto')).rejects.toSatisfy(hasCode('FA607'));
    });
  });

  it('o mesmo nome pode existir em pais diferentes, mas não no mesmo pai', async () => {
    await asUser(a.admin.id, async (client) => {
      const one = await category(client, null, 'Um');
      const two = await category(client, null, 'Dois');
      await category(client, one, 'Igual');
      await category(client, two, 'Igual');
      await expect(category(client, one, 'igual')).rejects.toSatisfy(hasCode('FA215'));
    });
  });

  it('produto só usa subcategoria', async () => {
    await asUser(a.admin.id, async (client) => {
      const department = await category(client, null, 'Depto');
      await expect(create(client, { categoryId: department })).rejects.toSatisfy(hasCode('FA605'));
    });
  });

  it('produto não usa subcategoria de outro grupo', async () => {
    const leaf = await committed(b.admin.id, async (client) => {
      const department = await category(client, null, `Depto ${randomBytes(3).toString('hex')}`);
      return category(client, await category(client, department, 'Cat'), 'Sub');
    });
    await asUser(a.admin.id, async (client) => {
      await expect(create(client, { categoryId: leaf })).rejects.toSatisfy(hasCode('FA605'));
    });
  });

  it('não exclui categoria com filhos nem subcategoria com produto', async () => {
    await asUser(a.admin.id, async (client) => {
      const department = await category(client, null, 'Depto');
      const middle = await category(client, department, 'Cat');
      const leaf = await category(client, middle, 'Sub');
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.delete_product_category($1)', [middle])).rejects.toSatisfy(hasCode('FA105'));
      await client.query('ROLLBACK TO s');
      await create(client, { categoryId: leaf });
      await expect(client.query('SELECT app.delete_product_category($1)', [leaf])).rejects.toSatisfy(hasCode('FA105'));
    });
  });

  it('categoria vazia pode ser excluída, e o nome volta a ficar livre', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await category(client, null, 'Temporária');
      await client.query('SELECT app.delete_product_category($1)', [id]);
      await category(client, null, 'Temporária');
    });
  });

  it('grupo de um tipo não serve em outro campo do produto', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [{ id }] } = await client.query(`SELECT app.create_product_group('pricing', 'Só preço') AS id`);
      await client.query('SAVEPOINT s');
      await expect(create(client, { commissionGroupId: id })).rejects.toSatisfy(hasCode('FA004'));
      await client.query('ROLLBACK TO s');
      await create(client, { pricingGroupId: id });
    });
  });

  it('grupo em uso não pode ser excluído', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [{ id }] } = await client.query(`SELECT app.create_product_group('commission', 'Usado') AS id`);
      await create(client, { commissionGroupId: id });
      await expect(client.query('SELECT app.delete_product_group($1)', [id])).rejects.toSatisfy(hasCode('FA105'));
    });
  });

  it('recusa tipo de grupo desconhecido e nome repetido', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT s');
      await expect(client.query(`SELECT app.create_product_group('outro', 'X')`)).rejects.toSatisfy(hasCode('FA609'));
      await client.query('ROLLBACK TO s');
      await client.query(`SELECT app.create_product_group('pricing', 'Repetido')`);
      await expect(client.query(`SELECT app.create_product_group('pricing', 'repetido')`)).rejects.toSatisfy(hasCode('FA215'));
    });
  });
});

describe('permissões', () => {
  it('a API não escreve direto em nenhuma tabela de produto', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['product', 'product_barcode', 'product_barcode_channel', 'product_category', 'product_group', 'sales_channel']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('sem products.manage, nenhuma alteração passa', async () => {
    const viewer = await userWith(a.group, ['products.view']);
    const id = await committed(a.admin.id, (client) => create(client));
    const calls = [
      ['SELECT app.create_product($1::jsonb)', [JSON.stringify(productData())]],
      ['SELECT app.update_product($1, $2::jsonb)', [id, JSON.stringify({ displayName: 'X' })]],
      ['SELECT app.add_barcode($1, $2::jsonb)', [id, JSON.stringify({ code: gtin() })]],
      [`SELECT app.create_product_category(NULL, 'X')`, []],
      [`SELECT app.create_product_group('pricing', 'X')`, []],
      [`SELECT app.create_sales_channel('X')`, []],
    ];
    for (const [sql, params] of calls) {
      await asUser(viewer.id, async (client) => {
        await expect(client.query(sql, params), sql).rejects.toSatisfy(hasCode('FA002'));
      });
    }
  });

  it('products.manage em uma filial só não altera o cadastro, que é da rede', async () => {
    const user = await userWith(a.group, ['products.manage'], a.branch1);
    await asUser(user.id, async (client) => {
      await expect(create(client)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('perfil de uma filial só pode ver os produtos', async () => {
    const user = await userWith(a.group, ['products.view'], a.branch1);
    const id = await committed(a.admin.id, (client) => create(client));
    await asUser(user.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM v_product WHERE id = $1', [id]);
      expect(rows).toHaveLength(1);
    });
  });

  it('sem permissão de ver, não enxerga nada de produto', async () => {
    const id = await committed(a.admin.id, (client) => create(client));
    await asUser(a.noBranchUser.id, async (client) => {
      for (const view of ['v_product', 'v_product_barcode', 'v_product_category', 'v_product_group', 'v_sales_channel']) {
        const { rows } = await client.query(`SELECT 1 FROM ${view} LIMIT 1`);
        expect(rows, view).toEqual([]);
      }
      const { rows } = await client.query('SELECT * FROM app.search_products($1)', [String(id)]);
      expect(rows).toEqual([]);
    });
  });

  it('o outro grupo não vê nem altera', async () => {
    const barcode = gtin();
    const id = await committed(a.admin.id, (client) => create(client, { barcode }));
    const { rows: [{ id: barcodeId }] } = await ownerPool.query('SELECT id FROM product_barcode WHERE product_id = $1', [id]);
    await asUser(b.admin.id, async (client) => {
      const { rows } = await client.query('SELECT 1 FROM v_product WHERE id = $1', [id]);
      expect(rows).toEqual([]);
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.update_product($1, $2::jsonb)', [id, JSON.stringify({ displayName: 'X' })])).rejects.toSatisfy(hasCode('FA006'));
      await client.query('ROLLBACK TO s');
      await expect(client.query('SELECT app.remove_barcode($1)', [barcodeId])).rejects.toSatisfy(hasCode('FA006'));
    });
  });
});

describe('busca de produtos', () => {
  const search = async (client, query) =>
    (await client.query('SELECT * FROM app.search_products($1)', [query])).rows;

  it('acha por nome sem acento, por palavras fora de ordem e por princípio ativo e fabricante', async () => {
    const tag = randomBytes(4).toString('hex');
    const item = await catalogItem({
      name: `Solução Ótica ${tag}`,
      activeIngredient: `Princípio${tag}`,
      manufacturer: `Fábrica${tag}`,
    });
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { catalogProductId: item.id, barcode: item.barcodes[0], displayName: `Solução Ótica ${tag}` });
      for (const query of [`solucao ${tag}`, `${tag} OTICA`, `principio${tag}`, `fabrica${tag} solucao`]) {
        expect((await search(client, query)).map((row) => row.id), query).toEqual([id]);
      }
      const [row] = await search(client, tag);
      expect(row.manufacturer).toBe(`Fábrica${tag}`);
      expect(row.active_ingredient).toBe(`Princípio${tag}`);
      expect(row.primary_barcode).toBe(item.barcodes[0]);
    });
  });

  it('acha pelo código humano e por qualquer código de barras, inclusive o não principal', async () => {
    await asUser(a.admin.id, async (client) => {
      const other = gtin();
      const id = await create(client);
      await client.query('SELECT app.add_barcode($1, $2::jsonb)', [id, JSON.stringify({ code: other })]);
      const { rows: [{ code }] } = await client.query('SELECT code FROM v_product WHERE id = $1', [id]);
      expect((await search(client, String(code))).map((row) => row.id)).toContain(id);
      expect((await search(client, other)).map((row) => row.id)).toEqual([id]);
    });
  });

  it('% e _ são texto, não curingas', async () => {
    await asUser(a.admin.id, async (client) => {
      const tag = randomBytes(4).toString('hex');
      await create(client, { displayName: `Item ${tag}` });
      expect(await search(client, `${tag.slice(0, 2)}%${tag.slice(3)}`)).toEqual([]);
      expect(await search(client, `${tag.slice(0, 2)}_${tag.slice(3)}`)).toEqual([]);
    });
  });

  it('o produto sem Catálogo aparece com o fabricante próprio', async () => {
    await asUser(a.admin.id, async (client) => {
      const tag = randomBytes(4).toString('hex');
      await create(client, { displayName: `Conveniência ${tag}`, ownManufacturer: 'Marca própria' });
      const [row] = await search(client, tag);
      expect(row.catalog_product_id).toBeNull();
      expect(row.manufacturer).toBe('Marca própria');
    });
  });

  it('não traz produto de outro grupo', async () => {
    const tag = randomBytes(4).toString('hex');
    await committed(b.admin.id, (client) => create(client, { displayName: `Grupo B ${tag}` }));
    await asUser(a.admin.id, async (client) => {
      expect(await search(client, tag)).toEqual([]);
    });
  });
});

describe('consulta ao Catálogo', () => {
  const search = async (client, query) =>
    (await client.query('SELECT * FROM app.search_catalog($1)', [query])).rows;

  it('acha pelo nome e por código de barras, e avisa se já está na loja', async () => {
    const tag = randomBytes(4).toString('hex');
    const item = await catalogItem({ name: `Xarope Ação ${tag}` });
    await asUser(a.admin.id, async (client) => {
      const [before] = await search(client, `xarope acao ${tag}`);
      expect(before.id).toBe(item.id);
      expect(before.barcodes).toEqual(item.barcodes);
      expect(before.product_id).toBeNull();
      expect((await search(client, item.barcodes[0])).map((row) => row.id)).toEqual([item.id]);

      const id = await create(client, { catalogProductId: item.id, barcode: item.barcodes[0] });
      const [after] = await search(client, tag);
      expect(after.product_id).toBe(id);
    });
  });

  it('a marca de já cadastrado não vaza produto de outro grupo', async () => {
    const tag = randomBytes(4).toString('hex');
    const item = await catalogItem({ name: `Item Vazamento ${tag}` });
    await committed(b.admin.id, (client) => create(client, { catalogProductId: item.id, barcode: item.barcodes[0] }));
    await asUser(a.admin.id, async (client) => {
      const [row] = await search(client, tag);
      expect(row.product_id).toBeNull();
    });
  });

  it('busca vazia não traz o Catálogo inteiro', async () => {
    await asUser(a.admin.id, async (client) => {
      expect(await search(client, '   ')).toEqual([]);
    });
  });
});

describe('perfis iniciais', () => {
  it('só o Gerente recebe products.view entre os perfis criáveis por padrão', async () => {
    await asOwner(async (client) => {
      const { rows } = await client.query(
        `SELECT r.name FROM role r
           JOIN role_permission rp ON rp.role_id = r.id AND rp.deleted_at IS NULL
           JOIN permission p ON p.id = rp.permission_id
          WHERE r.economic_group_id = $1 AND p.code = 'products.view'
            AND r.name IN ('Gerente', 'Farmacêutico', 'Operador de caixa')`,
        [a.group.id],
      );
      expect(rows.map((row) => row.name)).toEqual(['Gerente']);
    });
  });
});
