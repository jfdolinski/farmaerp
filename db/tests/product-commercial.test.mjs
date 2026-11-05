import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

const create = async (client, overrides = {}) =>
  (await client.query('SELECT app.create_product($1::jsonb) AS id', [
    JSON.stringify({ displayName: 'Produto Teste', barcode: gtin(), ...overrides }),
  ])).rows[0].id;
const setPrice = (client, product, branch, price, reason = null) =>
  client.query('SELECT app.set_product_price($1, $2, $3, $4) AS id', [product, branch?.id ?? null, price, reason]);
const addPmc = (client, product, state, value, region = null) =>
  client.query('SELECT app.add_product_pmc($1, $2, $3, $4) AS id', [product, state, region, value]);
const setStatus = (client, product, branches, status, reason = 'Motivo do teste') =>
  client.query('SELECT app.set_product_status($1, $2, $3, $4)', [product, branches.map((x) => x.id), status, reason]);
const reactivate = (client, product, branches, status = 'active', reason = 'Voltou a vender') =>
  client.query('SELECT app.reactivate_product($1, $2, $3, $4)', [product, branches.map((x) => x.id), status, reason]);
const locate = (client, branch, state, region = null) =>
  client.query('SELECT app.set_branch_location($1, $2, $3)', [branch.id, state, region]);
const grid = async (client, product) =>
  (await client.query('SELECT * FROM app.product_branch_grid($1)', [product])).rows;
const rowOf = async (client, product, branch) =>
  (await grid(client, product)).find((row) => row.branch_id === branch.id);
const price = async (client, product, branch) => {
  const { rows } = await client.query('SELECT app.effective_price($1, $2) AS value', [product, branch.id]);
  return rows[0].value === null ? null : Number(rows[0].value);
};

/** Usuário com as permissões informadas, em uma filial ou em todas as vinculadas. */
async function userWith(client, group, codes, { branches = [], scope = null } = {}) {
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
  for (const branch of branches) {
    await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
  }
  await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, scope?.id ?? null]);
  return user;
}

/** Tudo como dono das tabelas, trocando de usuário dentro da mesma transação. */
const asRole = (client, user) => setUser(client, user.id);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('linhas de status', () => {
  it('produto novo nasce ativo em todas as filiais do grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      const rows = await grid(client, id);
      expect(rows.map((row) => row.branch_id).sort()).toEqual(
        [a.branch1.id, a.branch2.id, a.branchFree.id].sort(),
      );
      expect(rows.every((row) => row.status === 'active')).toBe(true);
    });
  });

  it('filial nova nasce ativa nos produtos que já existem', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const { rows: [branch] } = await client.query(
        `INSERT INTO branch (company_id, name, cnpj) VALUES ($1, 'Nova', $2) RETURNING id`,
        [a.company.id, branchCnpj(a.root, 77)],
      );
      const { rows } = await client.query(
        'SELECT status FROM product_branch_status WHERE product_id = $1 AND branch_id = $2',
        [id, branch.id],
      );
      expect(rows).toEqual([{ status: 'active' }]);
    });
  });

  it('não cria linha em filial de outro grupo', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const { rows } = await client.query(
        'SELECT 1 FROM product_branch_status WHERE product_id = $1 AND branch_id = $2',
        [id, b.branch1.id],
      );
      expect(rows).toEqual([]);
    });
  });
});

describe('preço', () => {
  it('a filial segue o preço da rede até ter exceção', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      expect(await price(client, id, a.branch1)).toBeNull();
      await setPrice(client, id, null, 10);
      expect(await price(client, id, a.branch1)).toBe(10);
      await setPrice(client, id, a.branch1, 8);
      expect(await price(client, id, a.branch1)).toBe(8);
      expect(await price(client, id, a.branch2)).toBe(10);
    });
  });

  it('mudar a rede não mexe em quem tem exceção', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setPrice(client, id, null, 10);
      await setPrice(client, id, a.branch1, 8);
      await setPrice(client, id, null, 12);
      expect(await price(client, id, a.branch1)).toBe(8);
      expect(await price(client, id, a.branch2)).toBe(12);
    });
  });

  it('encerrar a exceção volta ao preço da rede, e o histórico fica', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setPrice(client, id, null, 10);
      await setPrice(client, id, a.branch1, 8, 'Concorrência');
      await setPrice(client, id, a.branch1, null, 'Fim da ação');
      expect(await price(client, id, a.branch1)).toBe(10);
      const { rows } = await client.query(
        'SELECT price, reason, updated_by FROM v_product_price WHERE product_id = $1 AND branch_id = $2 ORDER BY id',
        [id, a.branch1.id],
      );
      expect(rows).toEqual([
        { price: '8.00', reason: 'Concorrência', updated_by: a.admin.id },
        { price: null, reason: 'Fim da ação', updated_by: a.admin.id },
      ]);
    });
  });

  it('a rede sempre precisa de um preço', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(setPrice(client, id, null, null)).rejects.toSatisfy(hasCode('FA613'));
    });
  });

  it.each([0, -1])('recusa preço %s', async (value) => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(setPrice(client, id, null, value)).rejects.toSatisfy(hasCode('FA613'));
    });
  });

  it('histórico não muda: nem o dono altera o valor', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const { rows: [{ id: priceId }] } = await setPrice(client, id, null, 10);
      await expect(client.query('UPDATE product_price SET price = 1 WHERE id = $1', [priceId])).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('recusa filial de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(setPrice(client, id, b.branch1, 5)).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('PMC', () => {
  /** Tudo na mesma transação desfeita, para as filiais do fixture continuarem sem estado. */
  const withPmc = (fn) => asUser(a.admin.id, async (client) => {
    await locate(client, a.branch1, 'SP');
    await locate(client, a.branch2, 'RJ');
    await locate(client, a.branchFree, 'AM', 'manaus_free_zone');
    const id = await create(client, { usesPmc: true });
    return fn(client, id);
  });

  it('bloqueia preço acima do PMC do estado da filial', async () => {
    await withPmc(async (client, id) => {
      await addPmc(client, id, 'SP', 10);
      await client.query('SAVEPOINT s');
      await expect(setPrice(client, id, a.branch1, 10.01)).rejects.toSatisfy(hasCode('FA610'));
      await client.query('ROLLBACK TO s');
      await setPrice(client, id, a.branch1, 10);
      expect(await price(client, id, a.branch1)).toBe(10);
    });
  });

  it('na rede, confere cada filial que segue o preço da rede', async () => {
    await withPmc(async (client, id) => {
      await addPmc(client, id, 'RJ', 10);
      await expect(setPrice(client, id, null, 11)).rejects.toSatisfy(hasCode('FA610'));
    });
  });

  it('na rede, ignora filial que tem exceção', async () => {
    await withPmc(async (client, id) => {
      await addPmc(client, id, 'RJ', 10);
      await setPrice(client, id, a.branch2, 9);
      await setPrice(client, id, null, 11);
      expect(await price(client, id, a.branch1)).toBe(11);
      expect(await price(client, id, a.branch2)).toBe(9);
    });
  });

  it('encerrar exceção não pode deixar a filial acima do PMC', async () => {
    await withPmc(async (client, id) => {
      await setPrice(client, id, null, 20);
      await setPrice(client, id, a.branch1, 9);
      await addPmc(client, id, 'SP', 10);
      await expect(setPrice(client, id, a.branch1, null)).rejects.toSatisfy(hasCode('FA610'));
    });
  });

  it('a região especial prevalece, e sem valor próprio vale o do estado', async () => {
    await withPmc(async (client, id) => {
      await addPmc(client, id, 'AM', 20);
      const pmc = async () => Number((await rowOf(client, id, a.branchFree)).pmc);
      expect(await pmc()).toBe(20);
      await addPmc(client, id, 'AM', 15, 'manaus_free_zone');
      expect(await pmc()).toBe(15);
      await addPmc(client, id, 'AM', 30);
      expect(await pmc()).toBe(15);
      await expect(setPrice(client, id, a.branchFree, 16)).rejects.toSatisfy(hasCode('FA610'));
    });
  });

  it('valor de outra região especial não vale aqui', async () => {
    await withPmc(async (client, id) => {
      await addPmc(client, id, 'AM', 5, 'free_trade_area');
      expect((await rowOf(client, id, a.branchFree)).pmc).toBeNull();
      await setPrice(client, id, a.branchFree, 50);
    });
  });

  it('o valor mais recente vale, e o histórico fica', async () => {
    await withPmc(async (client, id) => {
      await addPmc(client, id, 'SP', 10);
      await addPmc(client, id, 'SP', 12);
      expect(Number((await rowOf(client, id, a.branch1)).pmc)).toBe(12);
      const { rows } = await client.query('SELECT value FROM v_product_pmc WHERE product_id = $1 ORDER BY id', [id]);
      expect(rows.map((row) => row.value)).toEqual(['10.00', '12.00']);
    });
  });

  it('PMC novo menor que o preço não bloqueia: só avisa na grade', async () => {
    await withPmc(async (client, id) => {
      await setPrice(client, id, a.branch1, 15);
      expect((await rowOf(client, id, a.branch1)).above_pmc).toBe(false);
      await addPmc(client, id, 'SP', 10);
      const row = await rowOf(client, id, a.branch1);
      expect(row.above_pmc).toBe(true);
      expect(Number(row.effective_price)).toBe(15);
    });
  });

  it('sem a flag não bloqueia nem avisa', async () => {
    await asUser(a.admin.id, async (client) => {
      await locate(client, a.branch1, 'SP');
      const id = await create(client);
      await addPmc(client, id, 'SP', 10);
      await setPrice(client, id, a.branch1, 99);
      expect((await rowOf(client, id, a.branch1)).above_pmc).toBe(false);
    });
  });

  it('com a flag, filial sem estado impede salvar o preço', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { usesPmc: true });
      await expect(setPrice(client, id, a.branch1, 5)).rejects.toSatisfy(hasCode('FA612'));
    });
  });

  it('com a flag e sem PMC cadastrado, não há limite para comparar', async () => {
    await withPmc(async (client, id) => {
      await setPrice(client, id, a.branch1, 999);
      expect((await rowOf(client, id, a.branch1)).above_pmc).toBe(false);
    });
  });

  it.each([
    ['estado', 'XX', null, 10],
    ['região', 'SP', 'lugar', 10],
    ['valor', 'SP', null, 0],
  ])('recusa %s inválido', async (_label, state, region, value) => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(addPmc(client, id, state, value, region)).rejects.toSatisfy(hasCode('FA614'));
    });
  });

  it('o PMC do Catálogo vale, e o digitado depois passa na frente', async () => {
    const sourceKey = `pmc-${randomBytes(6).toString('hex')}`;
    const code = gtin();
    const upsert = (value) => ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [
      JSON.stringify({ sourceKey, name: 'Com PMC', barcodes: [code], pmc: [{ state: 'SP', value }] }),
    ]);
    const { rows: [{ id: catalogId }] } = await upsert(10);
    await upsert(10);
    const { rows: lines } = await ownerPool.query('SELECT 1 FROM catalog_product_pmc WHERE catalog_product_id = $1', [catalogId]);
    expect(lines, 'importar de novo o mesmo valor não gera linha').toHaveLength(1);

    await asUser(a.admin.id, async (client) => {
      await locate(client, a.branch1, 'SP');
      const id = await create(client, { catalogProductId: catalogId, barcode: code, usesPmc: true });
      expect(Number((await rowOf(client, id, a.branch1)).pmc)).toBe(10);
      await addPmc(client, id, 'SP', 8);
      expect(Number((await rowOf(client, id, a.branch1)).pmc)).toBe(8);
    });
  });

  it('a importação recusa PMC inválido', async () => {
    await expect(ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb)', [
      JSON.stringify({ sourceKey: `pmc-${randomBytes(6).toString('hex')}`, name: 'Ruim', pmc: [{ state: 'ZZ', value: 1 }] }),
    ])).rejects.toSatisfy(hasCode('FA614'));
  });
});

describe('estado da filial', () => {
  it('quem tem structure.manage informa, e quem não tem não muda', async () => {
    await asOwner(async (client) => {
      await asRole(client, a.oneBranchUser);
      await client.query('SAVEPOINT s');
      await expect(locate(client, a.branch1, 'SP')).rejects.toSatisfy(hasCode('FA002'));
      await client.query('ROLLBACK TO s');
      await asRole(client, a.admin);
      await locate(client, a.branch1, 'SP', 'free_trade_area');
      const { rows } = await client.query('SELECT state, pmc_region FROM branch WHERE id = $1', [a.branch1.id]);
      expect(rows[0]).toEqual({ state: 'SP', pmc_region: 'free_trade_area' });
    });
  });

  it('recusa estado inválido', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(locate(client, a.branch1, 'ZZ')).rejects.toSatisfy(hasCode('FA617'));
    });
  });

  it('não altera filial de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(locate(client, b.branch1, 'SP')).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('status por filial', () => {
  const statusOf = async (client, id, branch) => (await rowOf(client, id, branch)).status;

  it('ação em massa muda as filiais marcadas e registra motivo e autor', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1, a.branch2], 'blocked', '  Falta no distribuidor ');
      expect(await statusOf(client, id, a.branch1)).toBe('blocked');
      expect(await statusOf(client, id, a.branch2)).toBe('blocked');
      expect(await statusOf(client, id, a.branchFree)).toBe('active');
      const { rows } = await client.query(
        `SELECT e.branch_id, e.old_status, e.new_status, e.reason, e.updated_by
           FROM v_product_status_event e
           JOIN v_product_branch_status s ON s.id = e.product_branch_status_id
          WHERE s.product_id = $1 ORDER BY e.branch_id`,
        [id],
      );
      expect(rows).toHaveLength(2);
      expect(rows[0]).toMatchObject({
        old_status: 'active', new_status: 'blocked', reason: 'Falta no distribuidor', updated_by: a.admin.id,
      });
    });
  });

  it('é tudo ou nada: uma filial sem permissão cancela a ação inteira', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      const id = await create(client);
      const limited = await userWith(client, a.group, ['products.status', 'products.view'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, limited.id);
      await client.query('SAVEPOINT s');
      await expect(setStatus(client, id, [a.branch1, a.branch2], 'blocked')).rejects.toSatisfy(hasCode('FA002'));
      await client.query('ROLLBACK TO s');
      await setUser(client, a.admin.id);
      expect(await statusOf(client, id, a.branch1)).toBe('active');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('o perfil de uma filial muda só a dele', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const limited = await userWith(client, a.group, ['products.status', 'products.view'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, limited.id);
      await setStatus(client, id, [a.branch1], 'on_order');
      const { rows } = await client.query('SELECT status FROM product_branch_status WHERE product_id = $1 AND branch_id = $2', [id, a.branch1.id]);
      expect(rows[0].status).toBe('on_order');
    });
  });

  it('exige motivo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(setStatus(client, id, [a.branch1], 'blocked', '   ')).rejects.toSatisfy(hasCode('FA302'));
    });
  });

  it('exige ao menos uma filial', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(setStatus(client, id, [], 'blocked')).rejects.toSatisfy(hasCode('FA005'));
    });
  });

  it('recusa status desconhecido', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(setStatus(client, id, [a.branch1], 'sumido')).rejects.toSatisfy(hasCode('FA615'));
    });
  });

  it('o mesmo status não gera registro', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1], 'active');
      const { rows } = await client.query(
        `SELECT 1 FROM v_product_status_event e JOIN v_product_branch_status s ON s.id = e.product_branch_status_id WHERE s.product_id = $1`,
        [id],
      );
      expect(rows).toEqual([]);
    });
  });

  it('filial repetida na lista conta uma vez', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1, a.branch1], 'blocked');
      const { rows } = await client.query(
        `SELECT 1 FROM v_product_status_event e JOIN v_product_branch_status s ON s.id = e.product_branch_status_id WHERE s.product_id = $1`,
        [id],
      );
      expect(rows).toHaveLength(1);
    });
  });
});

describe('reativação', () => {
  it('inativo não volta pela ação comum', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1], 'inactive');
      await expect(setStatus(client, id, [a.branch1], 'active')).rejects.toSatisfy(hasCode('FA611'));
    });
  });

  it('volta pela reativação, com registro', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1], 'inactive');
      await reactivate(client, id, [a.branch1], 'on_order', 'Voltou ao mix');
      expect((await rowOf(client, id, a.branch1)).status).toBe('on_order');
      const { rows } = await client.query(
        `SELECT e.old_status, e.new_status FROM v_product_status_event e
           JOIN v_product_branch_status s ON s.id = e.product_branch_status_id
          WHERE s.product_id = $1 ORDER BY e.id DESC LIMIT 1`,
        [id],
      );
      expect(rows[0]).toEqual({ old_status: 'inactive', new_status: 'on_order' });
    });
  });

  it('exige products.reactivate, não só products.status', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      const id = await create(client);
      await setStatus(client, id, [a.branch1], 'inactive');
      const statusOnly = await userWith(client, a.group, ['products.status', 'products.view'], { branches: [a.branch1] });
      await setUser(client, statusOnly.id);
      await expect(reactivate(client, id, [a.branch1])).rejects.toSatisfy(hasCode('FA002'));
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('só reativa o que está inativo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await expect(reactivate(client, id, [a.branch1])).rejects.toSatisfy(hasCode('FA616'));
    });
  });

  it('não reativa para inativo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1], 'inactive');
      await expect(reactivate(client, id, [a.branch1], 'inactive')).rejects.toSatisfy(hasCode('FA615'));
    });
  });

  it('exige motivo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setStatus(client, id, [a.branch1], 'inactive');
      await expect(reactivate(client, id, [a.branch1], 'active', ' ')).rejects.toSatisfy(hasCode('FA302'));
    });
  });
});

describe('busca e inativos', () => {
  const search = async (client, query, showInactive = false) =>
    (await client.query('SELECT * FROM app.search_products($1, 50, $2)', [query, showInactive])).rows;

  it('inativo em todas as filiais some da busca e volta com o filtro', async () => {
    await asUser(a.admin.id, async (client) => {
      const tag = randomBytes(4).toString('hex');
      const id = await create(client, { displayName: `Item ${tag}` });
      await setStatus(client, id, [a.branch1, a.branch2], 'inactive');
      expect((await search(client, tag)).map((row) => row.id), 'ainda ativo em uma filial').toEqual([id]);
      await setStatus(client, id, [a.branchFree], 'inactive');
      expect(await search(client, tag)).toEqual([]);
      const [row] = await search(client, tag, true);
      expect(row).toMatchObject({ id, all_inactive: true });
    });
  });

  it('bloqueado continua aparecendo', async () => {
    await asUser(a.admin.id, async (client) => {
      const tag = randomBytes(4).toString('hex');
      const id = await create(client, { displayName: `Item ${tag}` });
      await setStatus(client, id, [a.branch1, a.branch2, a.branchFree], 'blocked');
      expect((await search(client, tag)).map((row) => row.id)).toEqual([id]);
    });
  });

  it('vale o que o usuário enxerga: inativo na filial dele some, mesmo ativo em outra', async () => {
    const client = await ownerPool.connect();
    const tag = randomBytes(4).toString('hex');
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      const id = await create(client, { displayName: `Item ${tag}` });
      await setStatus(client, id, [a.branch1], 'inactive');
      const local = await userWith(client, a.group, ['products.view'], { branches: [a.branch1], scope: a.branch1 });
      await client.query('COMMIT');
      const app = await appPool.connect();
      try {
        await app.query('BEGIN');
        await setUser(app, local.id);
        expect(await search(app, tag)).toEqual([]);
        await app.query('ROLLBACK');
      } finally {
        app.release();
      }
    } finally {
      client.release();
    }
  });
});

describe('o que cada um enxerga', () => {
  it('a API não escreve direto em preço, PMC ou status', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['product_price', 'product_pmc', 'catalog_product_pmc', 'product_branch_status', 'product_status_event']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('sem products.price, preço e PMC não mudam', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const viewer = await userWith(client, a.group, ['products.view'], { branches: [a.branch1] });
      await setUser(client, viewer.id);
      await client.query('SAVEPOINT s');
      await expect(setPrice(client, id, a.branch1, 5)).rejects.toSatisfy(hasCode('FA002'));
      await client.query('ROLLBACK TO s');
      await expect(addPmc(client, id, 'SP', 5)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('o perfil de uma filial altera a exceção dela, mas não a rede nem outra filial', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const local = await userWith(client, a.group, ['products.price', 'products.view'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, local.id);
      await setPrice(client, id, a.branch1, 5);
      await client.query('SAVEPOINT s');
      await expect(setPrice(client, id, null, 5)).rejects.toSatisfy(hasCode('FA002'));
      await client.query('ROLLBACK TO s');
      await expect(setPrice(client, id, a.branch2, 5)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('outro grupo não vê nem altera', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setPrice(client, id, null, 10);
      await setUser(client, b.admin.id);
      expect(await grid(client, id)).toEqual([]);
      await client.query('SAVEPOINT s');
      await expect(setPrice(client, id, null, 1)).rejects.toSatisfy(hasCode('FA006'));
      await client.query('ROLLBACK TO s');
      await expect(setStatus(client, id, [b.branch1], 'blocked')).rejects.toSatisfy(hasCode('FA006'));
    });
  });

  it('sem products.view, a grade vem vazia', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client);
      await setUser(client, a.noBranchUser.id);
      expect(await grid(client, id)).toEqual([]);
    });
  });
});
