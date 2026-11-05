import { randomInt, randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { catalog, codeFromDbError } from '@farmaerp/error-catalog';
import pg from 'pg';

const envFile = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '.env');
try {
  process.loadEnvFile(envFile);
} catch {
  // Sem arquivo .env (como no CI), valem as variáveis do ambiente.
}

export const TEST_DATABASE = 'farmaerp_test';

export function connectionConfig(user, password, database = TEST_DATABASE) {
  return {
    host: process.env.DB_HOST ?? '127.0.0.1',
    port: Number(process.env.DB_PORT ?? 5432),
    user,
    password,
    database,
  };
}

export const ownerPool = new pg.Pool(
  connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD),
);
export const appPool = new pg.Pool(
  connectionConfig('farmaerp_app', process.env.FARMAERP_APP_PASSWORD),
);

export async function closePools() {
  await Promise.all([ownerPool.end(), appPool.end()]);
}

async function inRolledBackTransaction(pool, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    return await fn(client);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}

/** Define o usuário da transação, como a API fará. */
export function setUser(client, userId) {
  return client.query(`SELECT set_config('app.user_id', $1, true)`, [userId ?? '']);
}

/** Define o terminal autenticado da transação, como a API fará. */
export function setTerminal(client, terminalId) {
  return client.query(`SELECT set_config('app.terminal_id', $1, true)`, [terminalId ?? '']);
}

/** Define o ID de rastreio da transação, como a API fará. */
export function setTrace(client, traceId) {
  return client.query(`SELECT set_config('app.trace_id', $1, true)`, [traceId ?? '']);
}

/**
 * Confere se o erro é traduzido para o código do catálogo. Quando o próprio banco
 * levanta o código, a mensagem também precisa ser a do catálogo.
 */
export function hasCode(expected) {
  return (error) =>
    codeFromDbError(error) === expected &&
    (error.code !== expected || error.message === catalog[expected].message);
}

/** Executa como a API (farmaerp_app) com o usuário informado e desfaz tudo no final. */
export function asUser(userId, fn) {
  return inRolledBackTransaction(appPool, async (client) => {
    await setUser(client, userId);
    return fn(client);
  });
}

/** Executa como dono das tabelas e desfaz tudo no final. */
export function asOwner(fn) {
  return inRolledBackTransaction(ownerPool, fn);
}

/** UUID válido que não é da versão 7. */
export const uuidV4 = () => randomUUID();

/** Cálculo independente do banco, para conferir a função SQL. */
export function withCheckDigits(base) {
  const weights = [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
  const digit = (text, w) => {
    const total = [...text].reduce((sum, c, i) => sum + (c.charCodeAt(0) - 48) * w[i], 0);
    const remainder = total % 11;
    return remainder < 2 ? 0 : 11 - remainder;
  };
  const first = digit(base, weights);
  return `${base}${first}${digit(`${base}${first}`, [6, ...weights])}`;
}

export const randomRoot = () => String(randomInt(10_000_000, 100_000_000));
export const branchCnpj = (root, order = 1) =>
  withCheckDigits(`${root}${String(order).padStart(4, '0')}`);

async function insert(client, table, values) {
  const columns = Object.keys(values);
  const placeholders = columns.map((_, i) => `$${i + 1}`).join(', ');
  const { rows } = await client.query(
    `INSERT INTO ${table} (${columns.join(', ')}) VALUES (${placeholders}) RETURNING *`,
    Object.values(values),
  );
  return rows[0];
}

async function createGroupStructure(client, label) {
  const group = await insert(client, 'economic_group', { name: `Grupo ${label}` });
  const root = randomRoot();
  const company = await insert(client, 'company', {
    economic_group_id: group.id,
    legal_name: `Empresa ${label} Ltda`,
    trade_name: `Empresa ${label}`,
    cnpj_root: root,
  });
  const branchGroup = await insert(client, 'branch_group', {
    economic_group_id: group.id,
    name: `Grupo de filial ${label}`,
  });
  const region = await insert(client, 'region', {
    branch_group_id: branchGroup.id,
    name: `Região ${label}`,
  });
  const newBranch = (order, regionId) =>
    insert(client, 'branch', {
      company_id: company.id,
      region_id: regionId,
      name: `Filial ${label} ${order}`,
      cnpj: branchCnpj(root, order),
    });
  const branch1 = await newBranch(1, region.id);
  const branch2 = await newBranch(2, region.id);
  const branchFree = await newBranch(3, null);
  const newTerminal = (branch, order) =>
    insert(client, 'terminal', {
      branch_id: branch.id,
      name: `Caixa ${order}`,
      profile: 'cashier',
      status: 'active',
      public_key: `chave-${randomUUID()}`,
    });
  const terminal1 = await newTerminal(branch1, 1);
  const terminal2 = await newTerminal(branch2, 2);
  // Perfil mínimo para os testes: enxerga os terminais das próprias filiais.
  const viewer = await insert(client, 'role', { economic_group_id: group.id, name: 'Consulta' });
  await client.query(
    `INSERT INTO role_permission (role_id, permission_id)
     SELECT $1, id FROM permission WHERE code = 'terminals.view'`,
    [viewer.id],
  );
  const adminRole = (await client.query(
    `SELECT * FROM role WHERE economic_group_id = $1 AND system_key = 'administrator'`,
    [group.id],
  )).rows[0];
  const managerRole = (await client.query(
    `SELECT * FROM role WHERE economic_group_id = $1 AND name = 'Gerente'`,
    [group.id],
  )).rows[0];
  const newUser = async (name, role = null) => {
    const user = await insert(client, 'user_account', { economic_group_id: group.id, name });
    if (role) await insert(client, 'user_role', { user_id: user.id, role_id: role.id });
    return user;
  };
  const admin = await newUser(`Admin ${label}`, adminRole);
  const secondAdmin = await newUser(`Segundo admin ${label}`, adminRole);
  const oneBranchUser = await newUser(`Usuário uma filial ${label}`, viewer);
  const twoBranchesUser = await newUser(`Usuário duas filiais ${label}`, viewer);
  const noBranchUser = await newUser(`Usuário sem filial ${label}`);
  const link = (user, branch) =>
    insert(client, 'user_branch', { user_id: user.id, branch_id: branch.id });
  const oneBranchLink = await link(oneBranchUser, branch1);
  await link(twoBranchesUser, branch1);
  await link(twoBranchesUser, branch2);

  return {
    group, root, company, branchGroup, region, branch1, branch2, branchFree,
    terminal1, terminal2, admin, secondAdmin, oneBranchUser, twoBranchesUser,
    noBranchUser, oneBranchLink, viewer, adminRole, managerRole,
  };
}

/** Cria e confirma dois grupos econômicos independentes. */
export async function createFixtures() {
  const client = await ownerPool.connect();
  try {
    await client.query('BEGIN');
    const a = await createGroupStructure(client, 'A');
    const b = await createGroupStructure(client, 'B');
    await client.query('COMMIT');
    return { a, b };
  } finally {
    client.release();
  }
}

export const ids = (rows) => rows.map((row) => row.id).sort();
