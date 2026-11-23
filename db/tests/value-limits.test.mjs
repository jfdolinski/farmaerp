import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot } from './helpers.mjs';

let a;
let b;
let manager;
let supervisor;
let clerk;
let supervisorRole;

const insertUser = async (name, groupId) => (await ownerPool.query(
  'INSERT INTO user_account (economic_group_id, name, email) VALUES ($1, $2, $3) RETURNING *',
  [groupId, name, `${randomBytes(4).toString('hex')}@limites.test`],
)).rows[0];
const link = (user, branch) => ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
const grant = (user, role, branch = null) => ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, branch?.id ?? null]);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  manager = await insertUser('Gerente limites', a.group.id);
  await link(manager, a.branch1);
  await grant(manager, a.managerRole, a.branch1);

  // Supervisor: faz perda, com limite de 30.
  supervisorRole = (await ownerPool.query(`INSERT INTO role (economic_group_id, name) VALUES ($1, 'Supervisor de estoque') RETURNING *`, [a.group.id])).rows[0];
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code IN ('stock.view', 'stock.loss', 'stock.adjust')`,
    [supervisorRole.id],
  );
  await ownerPool.query(
    `INSERT INTO role_limit (economic_group_id, role_id, limit_type_id, value) SELECT $1, $2, id, 30 FROM limit_type WHERE code = 'stock_loss'`,
    [a.group.id, supervisorRole.id],
  );
  supervisor = await insertUser('Supervisor limites', a.group.id);
  await link(supervisor, a.branch1);
  await grant(supervisor, supervisorRole, a.branch1);

  // Balconista: vê estoque, sem perda.
  const clerkRole = (await ownerPool.query(`INSERT INTO role (economic_group_id, name) VALUES ($1, 'Balconista') RETURNING *`, [a.group.id])).rows[0];
  await ownerPool.query(`INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'stock.view'`, [clerkRole.id]);
  clerk = await insertUser('Balconista limites', a.group.id);
  await link(clerk, a.branch1);
  await grant(clerk, clerkRole, a.branch1);
});
afterAll(closePools);

async function session(fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    const as = (user) => client.query(`SELECT set_config('app.user_id', $1, true)`, [user.id]);
    await as(a.admin);
    await fn(client, as);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
/** Limite da pessoa pela função que a API usa (my_limits), voltando ao usuário de antes. */
async function limit(client, user, branch, type) {
  const { rows: [before] } = await client.query("SELECT current_setting('app.user_id', true) AS u");
  await client.query("SELECT set_config('app.user_id', $1, true)", [user.id]);
  const { rows } = await client.query('SELECT value FROM app.my_limits($1) WHERE code = $2', [branch.id, type]);
  await client.query("SELECT set_config('app.user_id', $1, true)", [before.u ?? '']);
  return rows.length === 0 ? 'sem acesso' : rows[0].value;
}
const setLimits = (client, role, limits) => client.query('SELECT app.set_role_limits($1, $2::jsonb)', [role.id, JSON.stringify(limits)]);

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
function accessKey(emitter) {
  const base = `352611${emitter}55001${String(randomInt(1, 999_999_999)).padStart(9, '0')}1${String(randomInt(10_000_000, 99_999_999))}`;
  let total = 0;
  let weight = 2;
  for (let i = base.length - 1; i >= 0; i -= 1) {
    total += (base.charCodeAt(i) - 48) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const remainder = total % 11;
  return `${base}${remainder < 2 ? 0 : 11 - remainder}`;
}
/** Produto com 10 unidades na filial 1 a R$ 10 de custo médio, pela nota de compra. */
async function stockedProduct(client) {
  const code = gtin();
  await client.query('SELECT app.create_product($1::jsonb)', [JSON.stringify({ displayName: `Produto ${code}`, barcode: code })]);
  const emitter = branchCnpj(randomRoot(), 1);
  const xml = '<nfeProc/>';
  const { rows: [{ id }] } = await client.query('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, true) AS id', [JSON.stringify({
    accessKey: accessKey(emitter), series: 1, number: randomInt(1, 999_999_999), issuedAt: '2026-11-20T10:00:00-03:00', operationType: 1,
    purpose: 1, environment: 2, protocolNumber: '135260000000001', authorizedAt: '2026-11-20T10:00:05-03:00', destCnpj: a.branch1.cnpj,
    emitter: { cnpj: emitter, legalName: 'DISTRIBUIDORA LIMITES LTDA' }, totals: { products: '100.00', invoice: '100.00' },
    items: [{ number: 1, supplierCode: `L-${code}`, barcode: code, description: 'ITEM', cfop: '6102', unit: 'UN', quantity: '10', unitPrice: '10', productsValue: '100.00', batches: [] }],
  }), xml, createHash('sha256').update(xml).digest('hex')]);
  await client.query('SELECT app.post_purchase_invoice($1)', [id]);
  return code;
}
const loss = (client, code, quantity, release = undefined) =>
  client.query('SELECT app.register_stock_loss($1::jsonb) AS id', [JSON.stringify({
    branchId: a.branch1.id, productLookup: code, quantity, reason: 'Quebra', ...(release ? { release } : {}),
  })]).then((r) => r.rows[0].id);

describe('limite de cada pessoa', () => {
  it('Administrador sem teto; Gerente com os valores iniciais; sem perfil com limite, zero', async () => {
    await session(async (client) => {
      expect(await limit(client, a.admin, a.branch1, 'stock_loss')).toBeNull();
      expect(await limit(client, manager, a.branch1, 'stock_loss')).toBe('500.00');
      expect(await limit(client, manager, a.branch1, 'sale_discount')).toBe('10.00');
      expect(await limit(client, manager, a.branch1, 'cash_withdrawal')).toBe('1000.00');
      expect(await limit(client, clerk, a.branch1, 'stock_loss')).toBe('0');
    });
  });

  it('com vários perfis vale o maior; filial em que não atua e pessoa inativa não contam', async () => {
    await session(async (client) => {
      expect(await limit(client, supervisor, a.branch1, 'stock_loss')).toBe('30.00');
      // O Gerente da filial 1 não atua na filial 2.
      expect(await limit(client, manager, a.branch2, 'stock_loss')).toBe('sem acesso');
    });
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [supervisor.id, a.managerRole.id, a.branch1.id]);
      expect((await client.query(`SELECT app.user_limit($1, $2, 'stock_loss') AS v`, [supervisor.id, a.branch1.id])).rows[0].v).toBe('500.00');
      // Perfil só na filial 2 não vale na filial 1.
      await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [clerk.id, a.branch2.id]);
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [clerk.id, a.managerRole.id, a.branch2.id]);
      expect((await client.query(`SELECT app.user_limit($1, $2, 'stock_loss') AS v`, [clerk.id, a.branch1.id])).rows[0].v).toBe('0');
      expect((await client.query(`SELECT app.user_limit($1, $2, 'stock_loss') AS v`, [clerk.id, a.branch2.id])).rows[0].v).toBe('500.00');
      // Perfil sem filial vale só onde a pessoa atua.
      const { rows: [roaming] } = await client.query(
        `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Gerente sem filial no perfil') RETURNING id`, [a.group.id],
      );
      await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [roaming.id, a.branch1.id]);
      await client.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [roaming.id, a.managerRole.id]);
      expect((await client.query(`SELECT app.user_limit($1, $2, 'stock_loss') AS v`, [roaming.id, a.branch1.id])).rows[0].v).toBe('500.00');
      expect((await client.query(`SELECT app.user_limit($1, $2, 'stock_loss') AS v`, [roaming.id, a.branch2.id])).rows[0].v).toBe('0');
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [supervisor.id]);
      expect((await client.query(`SELECT app.user_limit($1, $2, 'stock_loss') AS v`, [supervisor.id, a.branch1.id])).rows[0].v).toBe('0');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('a tela de perfis lê e troca os limites, com as travas', async () => {
    await session(async (client, as) => {
      const { rows } = await client.query('SELECT * FROM app.role_limits() WHERE role_id = $1 ORDER BY code', [a.managerRole.id]);
      expect(rows.map((r) => [r.code, r.unit, r.value])).toEqual([
        ['cash_withdrawal', 'money', '1000.00'], ['credit_sale', 'money', '500.00'], ['sale_discount', 'percent', '10.00'], ['stock_loss', 'money', '500.00'],
      ]);
      expect((await client.query('SELECT 1 FROM app.role_limits() WHERE role_id = $1', [a.adminRole.id])).rows).toEqual([]);
      await setLimits(client, a.managerRole, { stock_loss: 200, sale_discount: '' });
      expect(await limit(client, manager, a.branch1, 'stock_loss')).toBe('200.00');
      expect(await limit(client, manager, a.branch1, 'sale_discount')).toBe('0');
      await expectCode(client, () => setLimits(client, a.managerRole, { sale_discount: 101 }), 'FA954');
      await expectCode(client, () => setLimits(client, a.managerRole, { stock_loss: -1 }), 'FA954');
      await expectCode(client, () => setLimits(client, a.managerRole, { voo: 1 }), 'FA004');
      await expectCode(client, () => setLimits(client, a.managerRole, [1]), 'FA005');
      await expectCode(client, () => setLimits(client, a.adminRole, { stock_loss: 1 }), 'FA502');
      await as(manager);
      await expectCode(client, () => setLimits(client, a.managerRole, { stock_loss: 999 }), 'FA002');
      expect((await client.query('SELECT 1 FROM app.role_limits()')).rows).toEqual([]);
      await as(b.admin);
      await expectCode(client, () => setLimits(client, a.managerRole, { stock_loss: 1 }), 'FA002');
    });
  });
});

describe('liberação na perda e no ajuste de estoque', () => {
  it('dentro do limite passa; acima pede liberação de um supervisor que possa e cubra o valor', async () => {
    await session(async (client, as) => {
      const code = await stockedProduct(client);
      await setLimits(client, a.managerRole, { stock_loss: 20 });
      await as(manager);
      await loss(client, code, 2); // R$ 20: no limite.
      await expectCode(client, () => loss(client, code, 3), 'FA949'); // R$ 30.
      await expectCode(client, () => loss(client, code, 3, { supervisorId: manager.id, reason: 'Caixa quebrada' }), 'FA950');
      await expectCode(client, () => loss(client, code, 3, { supervisorId: clerk.id, reason: 'Caixa quebrada' }), 'FA951');
      await expectCode(client, () => loss(client, code, 4, { supervisorId: supervisor.id, reason: 'Caixa quebrada' }), 'FA952'); // R$ 40 > 30.
      await expectCode(client, () => loss(client, code, 3, { supervisorId: supervisor.id, reason: ' ' }), 'FA302');
      await expectCode(client, () => loss(client, code, 3, { supervisorId: supervisor.id }), 'FA302');
      const movementId = await loss(client, code, 3, { supervisorId: supervisor.id, reason: 'Caixa quebrada' });
      await loss(client, code, 4, { supervisorId: a.admin.id, reason: 'Vencidos' });

      await as(a.admin);
      const { rows } = await client.query('SELECT * FROM v_supervisor_release WHERE requested_by = $1 ORDER BY created_at, id', [manager.id]);
      expect(rows.map((r) => [r.action, r.value, r.requester_limit, r.releaser_limit, r.released_by])).toEqual([
        ['stock.loss', '30.00', '20.00', '30.00', supervisor.id],
        ['stock.loss', '40.00', '20.00', null, a.admin.id],
      ]);
      expect(rows[0]).toMatchObject({ reason: 'Caixa quebrada', reference_id: movementId, branch_id: a.branch1.id });
    });
  });

  it('ajuste e inventário contam pelo valor da diferença, nos dois sentidos', async () => {
    await session(async (client, as) => {
      const code = await stockedProduct(client);
      await as(supervisor);
      const adjust = (direction, quantity, release) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
        branchId: a.branch1.id, productLookup: code, direction, quantity, reason: 'Conferência', ...(release ? { release } : {}),
      })]);
      const count = (counted, release) => client.query('SELECT app.count_stock($1::jsonb)', [JSON.stringify({
        branchId: a.branch1.id, productLookup: code, countedQuantity: counted, reason: 'Inventário', ...(release ? { release } : {}),
      })]);
      await adjust('in', 3); // R$ 30: no limite do supervisor.
      await expectCode(client, () => adjust('in', 4), 'FA949');
      await expectCode(client, () => adjust('out', 4), 'FA949');
      await adjust('out', 4, { supervisorId: a.admin.id, reason: 'Recontagem' });
      // Saldo 9: contar 13 é diferença de 4 (R$ 40); contar 6 é diferença de 3 (R$ 30).
      await expectCode(client, () => count(13), 'FA949');
      await expectCode(client, () => count(5), 'FA949'); // Saldo 9, conta 5: diferença de -4 (R$ 40).
      await count(6);
      await count(10, { supervisorId: a.admin.id, reason: 'Achado no depósito' });
      await as(a.admin);
      const { rows } = await client.query('SELECT action, value FROM v_supervisor_release WHERE requested_by = $1 ORDER BY created_at, id', [supervisor.id]);
      expect(rows).toEqual([{ action: 'stock.adjust', value: '40.00' }, { action: 'stock.count', value: '40.00' }]);
    });
  });

  it('produto sem custo médio não pede liberação; o Administrador não tem limite', async () => {
    await session(async (client, as) => {
      const code = gtin();
      await client.query('SELECT app.create_product($1::jsonb)', [JSON.stringify({ displayName: `Sem custo ${code}`, barcode: code })]);
      await client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({ branchId: a.branch1.id, productLookup: code, direction: 'in', quantity: 100, reason: 'Saldo inicial' })]);
      await as(clerk);
      await expectCode(client, () => loss(client, code, 1), 'FA002');
      await as(manager);
      await loss(client, code, 50);
      await as(a.admin);
      const priced = await stockedProduct(client);
      await loss(client, priced, 10);
      expect((await client.query('SELECT 1 FROM v_supervisor_release WHERE requested_by = $1', [a.admin.id])).rows).toEqual([]);
    });
  });
});

describe('desconto', () => {
  it('a pessoa dá sozinha o menor entre o limite dela e o máximo do produto', async () => {
    await session(async (client, as) => {
      const code = gtin();
      const { rows: [{ id: productId }] } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Desconto ${code}`, barcode: code })]);
      const free = gtin();
      const { rows: [{ id: freeId }] } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Livre ${free}`, barcode: free })]);
      await client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({ typeCode: 'max_discount', level: 'product', productLookup: code, value: 15 })]);
      const check = (product, percent) => client.query('SELECT * FROM app.discount_check($1, $2, $3)', [product, a.branch1.id, percent]).then((r) => r.rows[0]);
      await as(manager);
      expect(await check(productId, 5)).toEqual({ status: 'allowed', user_limit: '10.00', product_limit: '15.0000' });
      expect((await check(productId, 10)).status).toBe('allowed');
      expect((await check(productId, 12)).status).toBe('needs_release');
      expect((await check(productId, 20)).status).toBe('needs_override');
      expect(await check(freeId, 50)).toMatchObject({ status: 'needs_release', product_limit: null });
      await as(a.admin);
      expect(await check(productId, 20)).toMatchObject({ status: 'allowed', user_limit: null });
    });
  });
});

describe('supervisor e auditoria', () => {
  it('o supervisor é achado pelo e-mail ou pelo código, só no mesmo grupo, ativo e com senha', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query('INSERT INTO user_credential (user_id, password_hash) VALUES ($1, $2)', [supervisor.id, 'hash-de-teste']);
      const { rows: [{ code }] } = await client.query('SELECT code FROM user_account WHERE id = $1', [supervisor.id]);
      const lookup = async (user, identifier) => {
        await client.query(`SELECT set_config('app.user_id', $1, true)`, [user.id]);
        return (await client.query('SELECT app.supervisor_lookup($1) AS r', [identifier])).rows[0].r;
      };
      expect(await lookup(manager, ` ${supervisor.email.toUpperCase()} `)).toEqual({ userId: supervisor.id, passwordHash: 'hash-de-teste', locked: false });
      expect(await lookup(manager, String(code))).toMatchObject({ userId: supervisor.id });
      expect(await lookup(manager, 'ninguem@limites.test')).toBeNull();
      // Sem senha cadastrada, não é achado.
      expect(await lookup(supervisor, manager.email)).toBeNull();
      expect(await lookup(b.admin, supervisor.email)).toBeNull();
      expect(await lookup(b.admin, String(code))).toBeNull();
      await client.query('UPDATE user_credential SET locked_until = now() + interval \'5 minutes\' WHERE user_id = $1', [supervisor.id]);
      expect(await lookup(manager, supervisor.email)).toMatchObject({ locked: true });
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [supervisor.id]);
      expect(await lookup(manager, supervisor.email)).toBeNull();
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('a lista de liberações mostra estoque e custo da nota, só para quem pode ver', async () => {
    await session(async (client, as) => {
      const code = await stockedProduct(client);
      await setLimits(client, a.managerRole, { stock_loss: 0 });
      await as(manager);
      await loss(client, code, 1, { supervisorId: a.admin.id, reason: 'Avaria' });
      const list = (args = [null, null, null, null]) => client.query('SELECT * FROM app.list_supervisor_releases($1, $2, $3, $4)', args).then((r) => r.rows);
      const mine = (await list()).filter((r) => r.requested_by_name === manager.name);
      expect(mine).toHaveLength(1);
      expect(mine[0]).toMatchObject({ action: 'stock.loss', value: '10.00', requester_limit: '0.00', released_by_name: a.admin.name, branch_name: a.branch1.name, unit: 'money' });
      expect((await list([null, null, null, 'stock.adjust'])).filter((r) => r.requested_by_name === manager.name)).toEqual([]);
      expect((await list([null, '2099-01-01', null, null]))).toEqual([]);
      await as(clerk);
      expect(await list()).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_supervisor_release')).rows).toEqual([]);
      await as(b.admin);
      expect((await list()).filter((r) => r.requested_by_name === manager.name)).toEqual([]);
    });
  });

  it('a liberação não muda depois de gravada e não vale para si mesmo', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      const insert = (requested, released) => client.query(
        `INSERT INTO supervisor_release (economic_group_id, branch_id, action, limit_type_id, requested_by, released_by, value, requester_limit, reason)
         SELECT $1, $2, 'stock.loss', id, $3, $4, 10, 0, 'Teste' FROM limit_type WHERE code = 'stock_loss' RETURNING id`,
        [a.group.id, a.branch1.id, requested, released],
      );
      await client.query('SAVEPOINT s');
      await expect(insert(manager.id, manager.id)).rejects.toSatisfy(hasCode('FA950'));
      await client.query('ROLLBACK TO s');
      const { rows: [{ id }] } = await insert(manager.id, supervisor.id);
      for (const sql of [
        'UPDATE supervisor_release SET value = 1 WHERE id = $1',
        "UPDATE supervisor_release SET reason = 'outro' WHERE id = $1",
        'UPDATE supervisor_release SET deleted_at = now() WHERE id = $1',
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql, [id])).rejects.toSatisfy(hasCode('FA104'));
        await client.query('ROLLBACK TO s');
      }
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});

describe('travas dos limites', () => {
  it('limite só em perfil do grupo e que não seja o Administrador, um por tipo', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      const insert = (groupId, roleId) => client.query(
        `INSERT INTO role_limit (economic_group_id, role_id, limit_type_id, value) SELECT $1, $2, id, 5 FROM limit_type WHERE code = 'sale_discount'`,
        [groupId, roleId],
      );
      for (const [groupId, roleId] of [[a.group.id, a.adminRole.id], [b.group.id, supervisorRole.id]]) {
        await client.query('SAVEPOINT s');
        await expect(insert(groupId, roleId)).rejects.toSatisfy(hasCode('FA004'));
        await client.query('ROLLBACK TO s');
      }
      await client.query('SAVEPOINT s');
      await expect(insert(a.group.id, a.managerRole.id)).rejects.toSatisfy(hasCode('FA008'));
      await client.query('ROLLBACK TO s');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
