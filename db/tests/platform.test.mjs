import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setUser } from './helpers.mjs';

// Plataforma: empresa nova como cliente separado. Ninguém de um cliente vê dado do outro.

let a;
let b;
const tag = () => randomBytes(4).toString('hex');

// CNPJ de teste, gerado ao acaso.
function cnpj() {
  const base = Array.from({ length: 12 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits) => {
    const weights = digits.length === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const rest = digits.reduce((sum, d, i) => sum + d * weights[i], 0) % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}

async function asUser(user, fn, { commit = false } = {}) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    const result = await fn(client);
    await client.query(commit ? 'COMMIT' : 'ROLLBACK');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

const tenantData = (overrides = {}) => ({
  groupName: `Farmácia ${tag()}`, cnpj: cnpj(), legalName: 'Farmácia Teste Ltda', tradeName: 'Farmácia Teste',
  branch: { name: 'Matriz', state: 'SP', city: 'São Paulo' },
  admin: { name: 'Dona da Farmácia', email: `dona-${tag()}@farmacia.test` },
  ...overrides,
});
const createTenant = (user, data = tenantData(), hash = 'hash-de-teste') => asUser(user, (client) =>
  client.query('SELECT app.create_tenant($1::jsonb, $2) AS r', [JSON.stringify(data), hash]).then((r) => r.rows[0].r), { commit: true });

let platform;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  platform = a.admin;
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [platform.id]);
});
afterAll(closePools);

describe('plataforma', () => {
  it('só o administrador da plataforma cadastra; o cliente nasce com perfis, empresa, filial e administrador', async () => {
    await expect(createTenant(b.admin)).rejects.toSatisfy(hasCode('FA002'));
    await expect(createTenant(a.oneBranchUser)).rejects.toSatisfy(hasCode('FA002'));
    const data = tenantData();
    const created = await createTenant(platform, data);
    const group = (await ownerPool.query('SELECT * FROM economic_group WHERE id = $1', [created.groupId])).rows[0];
    expect(group.name).toBe(data.groupName);
    const roles = (await ownerPool.query('SELECT name FROM role WHERE economic_group_id = $1 ORDER BY name', [created.groupId])).rows.map((r) => r.name);
    expect(roles).toEqual(['Administrador', 'Balconista', 'Farmacêutico', 'Gerente', 'Operador de caixa']);
    const company = (await ownerPool.query('SELECT * FROM company WHERE id = $1', [created.companyId])).rows[0];
    expect(company).toMatchObject({ economic_group_id: created.groupId, cnpj_root: data.cnpj.slice(0, 8), trade_name: 'Farmácia Teste' });
    const branch = (await ownerPool.query('SELECT * FROM branch WHERE id = $1', [created.branchId])).rows[0];
    expect(branch).toMatchObject({ company_id: created.companyId, cnpj: data.cnpj, name: 'Matriz', state: 'SP' });
    const admin = (await ownerPool.query('SELECT * FROM user_account WHERE id = $1', [created.adminId])).rows[0];
    expect(admin).toMatchObject({ economic_group_id: created.groupId, email: data.admin.email, name: 'Dona da Farmácia' });
    expect((await ownerPool.query('SELECT must_change_password, password_hash FROM user_credential WHERE user_id = $1', [created.adminId])).rows[0])
      .toEqual({ must_change_password: true, password_hash: 'hash-de-teste' });
    const permissions = (await ownerPool.query('SELECT app.user_permission_codes($1) AS p', [created.adminId])).rows[0].p;
    expect(permissions).toContain('structure.manage');
    // O administrador da empresa nova não administra a plataforma.
    const newAdmin = { id: created.adminId };
    expect(await asUser(newAdmin, (client) => client.query('SELECT app.is_platform_admin() AS p').then((r) => r.rows[0].p))).toBe(false);
    await expect(asUser(newAdmin, (client) => client.query('SELECT * FROM app.list_tenants()'))).rejects.toSatisfy(hasCode('FA002'));
  });

  it('dados obrigatórios, CNPJ e e-mail sem repetir', async () => {
    await expect(createTenant(platform, tenantData({ groupName: ' ' }))).rejects.toSatisfy(hasCode('FA847'));
    await expect(createTenant(platform, tenantData({ admin: { name: 'X', email: '' } }))).rejects.toSatisfy(hasCode('FA848'));
    await expect(createTenant(platform, tenantData({ admin: { name: '', email: 'x@y.test' } }))).rejects.toSatisfy(hasCode('FA848'));
    await expect(createTenant(platform, tenantData({ cnpj: '11111111111111' }))).rejects.toSatisfy(hasCode('FA211'));
    await expect(createTenant(platform, tenantData(), ' ')).rejects.toSatisfy(hasCode('FA005'));
    const first = tenantData();
    await createTenant(platform, first);
    await expect(createTenant(platform, tenantData({ cnpj: first.cnpj }))).rejects.toSatisfy(hasCode('FA213'));
    await expect(createTenant(platform, tenantData({ admin: { name: 'Outra', email: first.admin.email.toUpperCase() } })))
      .rejects.toSatisfy(hasCode('FA406'));
    // Nada fica pela metade: o grupo da tentativa recusada não existe.
    const groups = (await ownerPool.query('SELECT count(*)::int AS n FROM economic_group WHERE name = $1', [first.groupName])).rows[0].n;
    expect(groups).toBe(1);
  });

  it('a lista mostra só o que identifica cada cliente', async () => {
    const data = tenantData();
    const created = await createTenant(platform, data);
    const rows = await asUser(platform, (client) => client.query('SELECT * FROM app.list_tenants()').then((r) => r.rows));
    const row = rows.find((r) => r.group_id === created.groupId);
    expect(row).toMatchObject({
      name: data.groupName, branch_count: 1, user_count: 1, admin_email: data.admin.email,
      companies: [{ legal_name: 'Farmácia Teste Ltda', trade_name: 'Farmácia Teste', cnpj_root: data.cnpj.slice(0, 8) }],
    });
    expect(Object.keys(row).sort()).toEqual(['admin_email', 'branch_count', 'companies', 'created_at', 'group_id', 'name', 'user_count']);
  });

  it('nenhuma tabela mostra a um cliente o que é do outro', async () => {
    const created = await createTenant(platform);
    const tenantAdmin = { id: created.adminId };
    const tables = (await ownerPool.query(`
      SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v')
         AND EXISTS (SELECT 1 FROM pg_attribute at WHERE at.attrelid = c.oid AND at.attname = 'economic_group_id' AND NOT at.attisdropped)
       ORDER BY 1`)).rows.map((r) => r.relname);
    expect(tables.length).toBeGreaterThan(50);
    const leaks = async (user, ownGroup) => asUser(user, async (client) => {
      const found = [];
      for (const table of tables) {
        await client.query('SAVEPOINT s');
        try {
          const { rows } = await client.query(`SELECT count(*)::int AS n FROM public.${table} WHERE economic_group_id <> $1`, [ownGroup]);
          if (rows[0].n > 0) found.push(table);
        } catch (error) {
          // Tabela que a API não lê direto (só pelas funções): também não vaza.
          if (error.code !== '42501') throw error;
        }
        await client.query('ROLLBACK TO s');
      }
      return found;
    });
    expect(await leaks(tenantAdmin, created.groupId)).toEqual([]);
    expect(await leaks(a.admin, a.group.id)).toEqual([]);
    // Filiais e terminais (sem a coluna do grupo) também não aparecem.
    const branches = await asUser(tenantAdmin, (client) => client.query('SELECT id FROM public.branch').then((r) => r.rows.map((x) => x.id)));
    expect(branches).toEqual([created.branchId]);
    const terminals = await asUser(tenantAdmin, (client) => client.query('SELECT count(*)::int AS n FROM public.terminal').then((r) => r.rows[0].n));
    expect(terminals).toBe(0);
    // E as funções de lista da retaguarda.
    const lists = await asUser(tenantAdmin, async (client) => ({
      customers: (await client.query("SELECT * FROM app.list_credit_accounts('all', NULL)")).rows.length,
      conflicts: (await client.query('SELECT * FROM app.list_sync_conflicts(NULL, NULL)')).rows.length,
      policies: (await client.query('SELECT branch_id FROM app.list_credit_policies()')).rows.map((r) => r.branch_id),
    }));
    expect(lists).toEqual({ customers: 0, conflicts: 0, policies: [created.branchId] });
  });
});
