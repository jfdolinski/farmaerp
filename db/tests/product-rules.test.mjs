import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;
let manufacturer;
let otherManufacturer;

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const tag = () => randomBytes(4).toString('hex');

const rule = (client, data) =>
  client.query('SELECT app.create_product_rule($1::jsonb) AS id', [JSON.stringify({ typeCode: 'commission', value: 1, ...data })])
    .then((r) => r.rows[0].id);
const resolve = async (client, product, branch = null, type = 'commission', at = null) =>
  (await client.query('SELECT * FROM app.resolve_product_rule($1, $2, $3, $4)', [type, product, branch?.id ?? null, at])).rows[0];
const valueOf = async (...args) => {
  const row = await resolve(...args);
  return row ? Number(row.value) : null;
};

/**
 * Produto com um alvo em cada nível. Fica na transação do teste, que é desfeita.
 * Com Catálogo, tem fabricante; sem ele, o nível do fabricante não se aplica.
 */
async function fullProduct(client) {
  const group = async (kind) => (await client.query('SELECT app.create_product_group($1, $2) AS id', [kind, `G ${tag()}`])).rows[0].id;
  const category = async (parent) => (await client.query('SELECT app.create_product_category($1, $2) AS id', [parent, `C ${tag()}`])).rows[0].id;
  const department = await category(null);
  const middle = await category(department);
  const subcategory = await category(middle);
  const priceFamily = await group('price_family');
  const pricing = await group('pricing');
  const commission = await group('commission');
  const code = gtin();
  const id = (await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
    displayName: `Produto ${tag()}`,
    barcode: code,
    catalogProductId: await freshCatalog(code),
    categoryId: subcategory,
    priceFamilyId: priceFamily,
    pricingGroupId: pricing,
    commissionGroupId: commission,
  })])).rows[0].id;
  return { id, department, middle, subcategory, priceFamily, pricing, commission, code };
}

/** Item novo do Catálogo, do fabricante do teste. Precisa estar confirmado para a API enxergar. */
async function freshCatalog(code) {
  const { rows } = await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey: `regra-${tag()}`, name: `Item ${tag()}`, manufacturer: manufacturer.name, barcodes: [code],
  })]);
  return rows[0].id;
}

async function userWith(client, codes, { branches = [], scope = null } = {}) {
  const { rows: [user] } = await client.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [a.group.id, `Usuário ${tag()}`],
  );
  const { rows: [role] } = await client.query(
    'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [a.group.id, `Perfil ${tag()}`],
  );
  await client.query(
    'INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)',
    [role.id, codes],
  );
  for (const branch of branches) {
    await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
  }
  await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, scope?.id ?? null]);
  return user;
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const make = async (name) => {
    await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb)', [JSON.stringify({
      sourceKey: `fab-${tag()}`, name: `Base ${name}`, manufacturer: name, barcodes: [gtin()],
    })]);
    return (await ownerPool.query('SELECT id, name FROM catalog_manufacturer WHERE name = $1', [name])).rows[0];
  };
  manufacturer = await make(`Fabricante ${tag()}`);
  otherManufacturer = await make(`Outro fabricante ${tag()}`);
});
afterAll(closePools);

describe('hierarquia', () => {
  const LEVELS = [
    ['product', (t) => ({ productLookup: t.code })],
    ['price_family', (t) => ({ productGroupId: t.priceFamily })],
    ['manufacturer', () => ({ manufacturerId: manufacturer.id })],
    ['subcategory', (t) => ({ categoryId: t.subcategory })],
    ['category', (t) => ({ categoryId: t.middle })],
    ['department', (t) => ({ categoryId: t.department })],
    ['pricing_group', (t) => ({ productGroupId: t.pricing })],
    ['commission_group', (t) => ({ productGroupId: t.commission })],
    ['store_default', () => ({})],
  ];

  it.each(LEVELS.slice(0, -1).map(([level], index) => [level, LEVELS[index + 1][0], index]))(
    '%s vence %s',
    async (_winner, _loser, index) => {
      await asUser(a.admin.id, async (client) => {
        const target = await fullProduct(client);
        // A mais específica é criada primeiro: se a ordem de criação mandasse, a outra venceria.
        await rule(client, { level: LEVELS[index][0], value: 10, ...LEVELS[index][1](target) });
        await rule(client, { level: LEVELS[index + 1][0], value: 20, ...LEVELS[index + 1][1](target) });
        const row = await resolve(client, target.id);
        expect(row.level).toBe(LEVELS[index][0]);
        expect(Number(row.value)).toBe(10);
      });
    },
  );

  it('com todos os níveis criados, vale o produto; ao encerrar cada um, vale o seguinte', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const ids = [];
      for (const [index, [level, data]] of LEVELS.entries()) {
        ids.push(await rule(client, { level, value: index + 1, ...data(target) }));
      }
      for (const [index, [level]] of LEVELS.entries()) {
        const row = await resolve(client, target.id);
        expect(row.level).toBe(level);
        expect(Number(row.value)).toBe(index + 1);
        await client.query('SELECT app.end_product_rule($1)', [ids[index]]);
      }
      expect(await resolve(client, target.id)).toBeUndefined();
    });
  });

  it('a explicação traz o nível e o nome do alvo', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'manufacturer', value: 5, manufacturerId: manufacturer.id });
      const row = await resolve(client, target.id);
      expect(row).toMatchObject({ level: 'manufacturer', target_name: manufacturer.name, unit: 'percent', branch_id: null });
    });
  });

  it('regra de alvo que não é do produto não vale', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const other = await fullProduct(client);
      await rule(client, { level: 'department', value: 5, categoryId: other.department });
      await rule(client, { level: 'manufacturer', value: 6, manufacturerId: otherManufacturer.id });
      await rule(client, { level: 'product', value: 7, productLookup: other.code });
      expect(await resolve(client, target.id)).toBeUndefined();
    });
  });

  it('produto sem Catálogo pula o fabricante e segue para a subcategoria', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const id = (await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
        displayName: 'Sem Catálogo', barcode: gtin(), ownManufacturer: manufacturer.name, categoryId: target.subcategory,
      })])).rows[0].id;
      await rule(client, { level: 'manufacturer', value: 5, manufacturerId: manufacturer.id });
      await rule(client, { level: 'subcategory', value: 6, categoryId: target.subcategory });
      expect((await resolve(client, id)).level).toBe('subcategory');
    });
  });

  it('sem regra, não devolve nada', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      expect(await resolve(client, target.id)).toBeUndefined();
    });
  });

  it('um tipo não interfere no outro', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { typeCode: 'cashback', level: 'store_default', value: 2 });
      expect(await resolve(client, target.id)).toBeUndefined();
      expect(await valueOf(client, target.id, null, 'cashback')).toBe(2);
    });
  });
});

describe('filial e rede', () => {
  it('no mesmo nível, a filial vence a rede', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 8, branchId: a.branch1.id });
      await rule(client, { level: 'store_default', value: 5 });
      expect(await valueOf(client, target.id, a.branch1)).toBe(8);
      expect(await valueOf(client, target.id, a.branch2)).toBe(5);
    });
  });

  it('nível mais específico da rede vence nível geral da filial', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'department', value: 8, categoryId: target.department, branchId: a.branch1.id });
      await rule(client, { level: 'product', value: 5, productLookup: target.code });
      const row = await resolve(client, target.id, a.branch1);
      expect(row).toMatchObject({ level: 'product', branch_id: null });
    });
  });

  it('regra de filial não vale em outra filial nem sem filial', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 8, branchId: a.branch1.id });
      expect(await resolve(client, target.id, a.branch2)).toBeUndefined();
      expect(await resolve(client, target.id)).toBeUndefined();
    });
  });

  it('a filial vence antes da prioridade', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 8, branchId: a.branch1.id });
      await rule(client, { level: 'store_default', value: 5, priority: 9999 });
      expect(await valueOf(client, target.id, a.branch1)).toBe(8);
    });
  });
});

describe('desempate', () => {
  it('no mesmo nível, a maior prioridade vence, mesmo sendo a mais antiga', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 8, priority: 5 });
      await rule(client, { level: 'store_default', value: 5, priority: 1 });
      expect(await valueOf(client, target.id)).toBe(8);
    });
  });

  it('com prioridade vence a sem prioridade', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 8, priority: 0 });
      await rule(client, { level: 'store_default', value: 5 });
      expect(await valueOf(client, target.id)).toBe(8);
    });
  });

  it('sem prioridade, vale a mais recente', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 8 });
      await rule(client, { level: 'store_default', value: 5 });
      expect(await valueOf(client, target.id)).toBe(5);
    });
  });

  it('a prioridade não passa por cima do nível', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'product', value: 5, productLookup: target.code });
      await rule(client, { level: 'store_default', value: 8, priority: 9999 });
      expect(await valueOf(client, target.id)).toBe(5);
    });
  });
});

describe('validade', () => {
  const at = (iso) => new Date(iso).toISOString();

  it('vale só dentro do período, com início incluído e fim excluído', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, {
        level: 'store_default', value: 5,
        validFrom: at('2030-01-01T00:00:00Z'), validTo: at('2030-02-01T00:00:00Z'),
      });
      const check = (when) => valueOf(client, target.id, null, 'commission', at(when));
      expect(await check('2029-12-31T23:59:59Z')).toBeNull();
      expect(await check('2030-01-01T00:00:00Z')).toBe(5);
      expect(await check('2030-01-31T23:59:59Z')).toBe(5);
      expect(await check('2030-02-01T00:00:00Z')).toBeNull();
    });
  });

  it('regra vencida dá lugar à mais geral', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 5 });
      await rule(client, {
        level: 'product', value: 9, productLookup: target.code,
        validFrom: at('2020-01-01T00:00:00Z'), validTo: at('2020-02-01T00:00:00Z'),
      });
      expect(await valueOf(client, target.id)).toBe(5);
    });
  });

  it('recusa fim antes do início', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(rule(client, {
        level: 'store_default', validFrom: at('2030-02-01T00:00:00Z'), validTo: at('2030-01-01T00:00:00Z'),
      })).rejects.toSatisfy(hasCode('FA703'));
    });
  });
});

describe('validação', () => {
  it.each([
    ['comissão acima de 100', 'commission', 100.01],
    ['valor negativo', 'cashback', -1],
    ['desconto acima de 100', 'max_discount', 101],
    ['tolerância acima de 1000', 'cost_tolerance', 1000.5],
  ])('recusa %s', async (_label, typeCode, value) => {
    await asUser(a.admin.id, async (client) => {
      await expect(rule(client, { typeCode, level: 'store_default', value })).rejects.toSatisfy(hasCode('FA701'));
    });
  });

  it.each([['commission', 100], ['commission', 0], ['cost_tolerance', 1000]])('aceita o limite: %s %d', async (typeCode, value) => {
    await asUser(a.admin.id, async (client) => {
      await rule(client, { typeCode, level: 'store_default', value });
    });
  });

  it('recusa tipo desconhecido', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(rule(client, { typeCode: 'magica', level: 'store_default' })).rejects.toSatisfy(hasCode('FA004'));
    });
  });

  it('recusa nível desconhecido', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(rule(client, { level: 'galaxia' })).rejects.toSatisfy(hasCode('FA704'));
    });
  });

  it.each(['product', 'price_family', 'manufacturer', 'subcategory', 'department', 'commission_group'])(
    'nível %s sem alvo é recusado',
    async (level) => {
      await asUser(a.admin.id, async (client) => {
        await expect(rule(client, { level })).rejects.toSatisfy(hasCode('FA702'));
      });
    },
  );

  it('produto que não existe é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(rule(client, { level: 'product', productLookup: 'naoexiste' })).rejects.toSatisfy(hasCode('FA702'));
    });
  });

  it('grupo do tipo errado é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await expect(rule(client, { level: 'commission_group', productGroupId: target.pricing })).rejects.toSatisfy(hasCode('FA702'));
    });
  });

  it('categoria no nível errado é recusada', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await expect(rule(client, { level: 'department', categoryId: target.subcategory })).rejects.toSatisfy(hasCode('FA702'));
    });
  });

  it('campo sobrando de outro nível é ignorado', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const id = await rule(client, { level: 'store_default', categoryId: target.department, manufacturerId: manufacturer.id });
      const { rows } = await client.query('SELECT category_id, manufacturer_id FROM v_product_rule WHERE id = $1', [id]);
      expect(rows[0]).toEqual({ category_id: null, manufacturer_id: null });
    });
  });

  it('prioridade fora da faixa é recusada', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(rule(client, { level: 'store_default', priority: 10000 })).rejects.toSatisfy(hasCode('FA704'));
    });
  });
});

describe('editar e encerrar', () => {
  it('editar encerra a antiga e cria outra, e o histórico guarda o valor anterior', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const old = await rule(client, { level: 'department', value: 5, categoryId: target.department, reason: 'Inicial' });
      const { rows: [{ id: fresh }] } = await client.query('SELECT app.replace_product_rule($1, $2::jsonb) AS id', [
        old, JSON.stringify({ value: 7, reason: 'Revisão' }),
      ]);
      expect(fresh).not.toBe(old);
      expect(await valueOf(client, target.id)).toBe(7);

      const { rows } = await client.query('SELECT * FROM app.list_product_rules(true) WHERE id = ANY ($1)', [[old, fresh]]);
      expect(rows.find((row) => row.id === old)).toMatchObject({ state: 'ended', value: '5.0000', reason: 'Inicial', author: a.admin.name });
      expect(rows.find((row) => row.id === fresh)).toMatchObject({ state: 'active', value: '7.0000', level: 'department' });
    });
  });

  it('editar mantém a data de início, se não for informada', async () => {
    await asUser(a.admin.id, async (client) => {
      const old = await rule(client, { level: 'store_default', validFrom: '2020-01-01T00:00:00Z' });
      const { rows: [{ id }] } = await client.query('SELECT app.replace_product_rule($1, $2::jsonb) AS id', [old, JSON.stringify({ value: 2 })]);
      const { rows } = await client.query('SELECT valid_from FROM v_product_rule WHERE id = $1', [id]);
      expect(new Date(rows[0].valid_from).toISOString()).toBe('2020-01-01T00:00:00.000Z');
    });
  });

  it('valor inválido na edição desfaz tudo, e a antiga continua', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const old = await rule(client, { level: 'store_default', value: 5 });
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.replace_product_rule($1, $2::jsonb)', [old, JSON.stringify({ value: 500 })])).rejects.toSatisfy(hasCode('FA701'));
      await client.query('ROLLBACK TO s');
      expect(await valueOf(client, target.id)).toBe(5);
    });
  });

  it('regra encerrada não vale, não muda de novo e aparece só no histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const id = await rule(client, { level: 'store_default', value: 5 });
      await client.query('SELECT app.end_product_rule($1)', [id]);
      expect(await resolve(client, target.id)).toBeUndefined();
      const { rows: active } = await client.query('SELECT 1 FROM app.list_product_rules() WHERE id = $1', [id]);
      expect(active).toEqual([]);
      await expect(client.query('SELECT app.end_product_rule($1)', [id])).rejects.toSatisfy(hasCode('FA006'));
    });
  });

  it('o valor não muda direto, nem pelo dono', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await rule(client, { level: 'store_default', value: 5 });
      await expect(client.query('UPDATE product_rule SET value = 9 WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('a lista mostra regra vencida e agendada', async () => {
    await asUser(a.admin.id, async (client) => {
      const expired = await rule(client, { level: 'store_default', validFrom: '2020-01-01T00:00:00Z', validTo: '2020-02-01T00:00:00Z' });
      const scheduled = await rule(client, { level: 'store_default', validFrom: '2090-01-01T00:00:00Z' });
      const { rows } = await client.query('SELECT id, state FROM app.list_product_rules() WHERE id = ANY ($1)', [[expired, scheduled]]);
      expect(rows.find((row) => row.id === expired).state).toBe('expired');
      expect(rows.find((row) => row.id === scheduled).state).toBe('scheduled');
    });
  });
});

describe('alvo protegido', () => {
  it('grupo e categoria com regra ativa não saem', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [{ id: group }] } = await client.query(`SELECT app.create_product_group('pricing', 'Livre') AS id`);
      const { rows: [{ id: department }] } = await client.query(`SELECT app.create_product_category(NULL, 'Livre') AS id`);
      await rule(client, { level: 'pricing_group', productGroupId: group });
      await rule(client, { level: 'department', categoryId: department });
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.delete_product_group($1)', [group])).rejects.toSatisfy(hasCode('FA105'));
      await client.query('ROLLBACK TO s');
      await expect(client.query('SELECT app.delete_product_category($1)', [department])).rejects.toSatisfy(hasCode('FA105'));
    });
  });

  it('regra vencida ou encerrada não segura o alvo', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [{ id: group }] } = await client.query(`SELECT app.create_product_group('pricing', 'Livre') AS id`);
      await rule(client, { level: 'pricing_group', productGroupId: group, validFrom: '2020-01-01T00:00:00Z', validTo: '2020-02-01T00:00:00Z' });
      const ended = await rule(client, { level: 'pricing_group', productGroupId: group });
      await client.query('SELECT app.end_product_rule($1)', [ended]);
      await client.query('SELECT app.delete_product_group($1)', [group]);
    });
  });
});

describe('simulador', () => {
  it('traz os quatro tipos, inclusive os sem regra', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { typeCode: 'cashback', level: 'store_default', value: 2 });
      const { rows } = await client.query('SELECT * FROM app.simulate_product_rules($1, NULL)', [target.id]);
      expect(rows.map((row) => row.type_code).sort()).toEqual(['cashback', 'commission', 'cost_tolerance', 'max_discount']);
      const cashback = rows.find((row) => row.type_code === 'cashback');
      expect(Number(cashback.value)).toBe(2);
      expect(cashback.level).toBe('store_default');
      expect(rows.find((row) => row.type_code === 'commission').rule_id).toBeNull();
    });
  });

  it('localiza pelo código humano e pelo código de barras', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      const { rows: [{ code }] } = await client.query('SELECT code FROM v_product WHERE id = $1', [target.id]);
      const find = async (value) => (await client.query('SELECT app.find_product_id($1) AS id', [value])).rows[0].id;
      expect(await find(String(code))).toBe(target.id);
      expect(await find(` ${target.code} `)).toBe(target.id);
      expect(await find('naoexiste')).toBeNull();
    });
  });
});

describe('permissões', () => {
  it('sem rules.manage, nada muda', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await rule(client, { level: 'store_default' });
      const viewer = await userWith(client, ['rules.view']);
      await setUser(client, viewer.id);
      for (const call of [
        () => rule(client, { level: 'store_default' }),
        () => client.query('SELECT app.replace_product_rule($1, $2::jsonb)', [id, '{"value": 1}']),
        () => client.query('SELECT app.end_product_rule($1)', [id]),
      ]) {
        await client.query('SAVEPOINT s');
        await expect(call()).rejects.toSatisfy(hasCode('FA002'));
        await client.query('ROLLBACK TO s');
      }
    });
  });

  it('perfil de uma filial cuida da regra dela, mas não da rede nem de outra filial', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const network = await rule(client, { level: 'store_default' });
      const other = await rule(client, { level: 'store_default', branchId: a.branch2.id });
      const local = await userWith(client, ['rules.manage'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, local.id);
      const mine = await rule(client, { level: 'store_default', branchId: a.branch1.id });
      await client.query('SELECT app.end_product_rule($1)', [mine]);
      for (const call of [
        () => rule(client, { level: 'store_default' }),
        () => rule(client, { level: 'store_default', branchId: a.branch2.id }),
        () => client.query('SELECT app.end_product_rule($1)', [network]),
        () => client.query('SELECT app.end_product_rule($1)', [other]),
      ]) {
        await client.query('SAVEPOINT s');
        await expect(call()).rejects.toSatisfy(hasCode('FA002'));
        await client.query('ROLLBACK TO s');
      }
    });
  });

  it('a API não escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['rule_type', 'product_rule']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('o catálogo tem os quatro tipos, e sem usuário ninguém lê', async () => {
    const { rows } = await ownerPool.query('SELECT code, unit FROM rule_type ORDER BY code');
    expect(rows).toEqual([
      { code: 'cashback', unit: 'percent' },
      { code: 'commission', unit: 'percent' },
      { code: 'cost_tolerance', unit: 'percent' },
      { code: 'max_discount', unit: 'percent' },
    ]);
    await asUser(null, async (client) => {
      expect((await client.query('SELECT 1 FROM v_rule_type')).rows).toEqual([]);
    });
  });

  it('o Gerente não recebe as permissões de regras', async () => {
    const { rows } = await ownerPool.query(
      `SELECT p.code FROM role_permission rp
         JOIN permission p ON p.id = rp.permission_id
        WHERE rp.role_id = $1 AND p.code LIKE 'rules.%'`,
      [a.managerRole.id],
    );
    expect(rows).toEqual([]);
  });

  it('sem permissão, a regra não aparece nem pelo motor', async () => {
    await asUser(a.admin.id, async (client) => {
      const target = await fullProduct(client);
      await rule(client, { level: 'store_default', value: 5 });
      await setUser(client, a.noBranchUser.id);
      expect(await resolve(client, target.id)).toBeUndefined();
      expect((await client.query('SELECT 1 FROM app.list_product_rules(true)')).rows).toEqual([]);
    });
  });

  it('outro grupo não enxerga nem altera', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await rule(client, { level: 'store_default', value: 5 });
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM app.list_product_rules(true) WHERE id = $1', [id])).rows).toEqual([]);
      await expect(client.query('SELECT app.end_product_rule($1)', [id])).rejects.toSatisfy(hasCode('FA006'));
    });
  });

  it('regra de uma filial fica oculta para quem não a enxerga', async () => {
    const owner = await ownerPool.connect();
    let hidden;
    let visible;
    let viewer;
    try {
      await owner.query('BEGIN');
      viewer = await userWith(owner, ['rules.view'], { branches: [a.branch1], scope: a.branch1 });
      await owner.query('COMMIT');
    } finally {
      owner.release();
    }
    const committed = await appPool.connect();
    try {
      await committed.query('BEGIN');
      await setUser(committed, a.admin.id);
      hidden = await rule(committed, { level: 'store_default', branchId: a.branch2.id });
      visible = await rule(committed, { level: 'store_default', branchId: a.branch1.id });
      await committed.query('COMMIT');
    } finally {
      committed.release();
    }
    await asUser(viewer.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM app.list_product_rules() WHERE id = ANY ($1)', [[hidden, visible]]);
      expect(rows.map((row) => row.id)).toEqual([visible]);
    });
  });
});
