import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  bootstrapAdmin, bootstrapRoles, runMigrations, runSeed, waitForDatabase, withClient,
} from '../scripts/lib.mjs';
import { connectionConfig } from './helpers.mjs';

const DATABASE = 'farmaerp_bootstrap_test';
const admin = (database) => connectionConfig('postgres', process.env.POSTGRES_PASSWORD, database);
const migrator = () => connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD, DATABASE);
const app = () => connectionConfig('farmaerp_app', process.env.FARMAERP_APP_PASSWORD, DATABASE);
const passwords = () => ({
  migratorPassword: process.env.FARMAERP_MIGRATOR_PASSWORD,
  appPassword: process.env.FARMAERP_APP_PASSWORD,
});

const recreate = () =>
  withClient(admin('postgres'), async (client) => {
    await client.query(`DROP DATABASE IF EXISTS ${DATABASE} WITH (FORCE)`);
    await client.query(`CREATE DATABASE ${DATABASE}`);
  });

beforeAll(recreate);
afterAll(() =>
  withClient(admin('postgres'), (client) => client.query(`DROP DATABASE IF EXISTS ${DATABASE} WITH (FORCE)`)),
);

describe('preparação do banco', () => {
  it('em um banco novo, o dono não consegue criar objetos antes dos papéis', async () => {
    await expect(
      withClient(migrator(), (client) => client.query('CREATE SCHEMA antes_dos_papeis')),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('permite aplicar as migrations depois dos papéis', async () => {
    await bootstrapRoles(admin(DATABASE), passwords());
    const applied = await runMigrations(migrator());
    expect(applied.length).toBeGreaterThanOrEqual(7);
  });

  it('pode rodar de novo sem mudar nada nem derrubar o acesso', async () => {
    await bootstrapRoles(admin(DATABASE), passwords());
    await bootstrapRoles(admin(DATABASE), passwords());

    expect(await runMigrations(migrator())).toEqual([]);
    const { rows } = await withClient(app(), (client) => client.query('SELECT count(*)::int AS total FROM branch'));
    expect(rows[0].total).toBe(0);
  });

  it('os papéis ficam sem privilégios especiais', async () => {
    const { rows } = await withClient(admin(DATABASE), (client) =>
      client.query(`SELECT rolname, rolsuper, rolbypassrls, rolcreatedb, rolcreaterole, rolcanlogin
                      FROM pg_roles WHERE rolname LIKE 'farmaerp_%' ORDER BY rolname`),
    );
    expect(rows).toEqual(
      ['farmaerp_app', 'farmaerp_migrator'].map((rolname) => ({
        rolname, rolsuper: false, rolbypassrls: false, rolcreatedb: false, rolcreaterole: false, rolcanlogin: true,
      })),
    );
  });

  it('o papel da API não cria objetos', async () => {
    await expect(
      withClient(app(), (client) => client.query('CREATE TABLE public.invasora (id int)')),
    ).rejects.toMatchObject({ code: '42501' });
  });

  it('configura o prefixo de log com o ID de rastreio', async () => {
    const { rows } = await withClient(admin(DATABASE), (client) => client.query('SHOW log_line_prefix'));
    expect(rows[0].log_line_prefix).toBe('%m [%p] app=%a ');
  });

  it('uma senha com aspas funciona', async () => {
    const hard = `se'nha"com$$aspas`;
    await bootstrapRoles(admin(DATABASE), { ...passwords(), appPassword: hard });
    try {
      const config = { ...app(), password: hard };
      const { rows } = await withClient(config, (client) => client.query('SELECT 1 AS ok'));
      expect(rows[0].ok).toBe(1);
    } finally {
      await bootstrapRoles(admin(DATABASE), passwords());
    }
  });
});

describe('seed por ambiente', () => {
  it.each([null, '', 'production', 'staging'])('recusa o ambiente %j', async (environment) => {
    await expect(runSeed(migrator(), environment)).rejects.toThrow(/só roda em desenvolvimento ou homologação/);
  });

  it('roda em homologação, mais de uma vez', async () => {
    await runSeed(migrator(), 'homologation');
    await runSeed(migrator(), 'homologation');
    const { rows } = await withClient(migrator(), (client) =>
      client.query('SELECT count(*)::int AS total FROM terminal'),
    );
    expect(rows[0].total).toBe(1);
  });

  it('rodar de novo não consome códigos de usuário', async () => {
    const counter = () =>
      withClient(migrator(), async (client) =>
        (await client.query(`SELECT last_value FROM code_counter WHERE entity = 'user'`)).rows[0].last_value);
    const before = await counter();
    await runSeed(migrator(), 'homologation');
    expect(await counter()).toBe(before);
  });
});

describe('espera pelo banco', () => {
  it('retorna quando o banco responde', async () => {
    await expect(waitForDatabase(migrator())).resolves.toBeUndefined();
  });

  it('desiste depois do tempo limite', async () => {
    const offline = { ...migrator(), port: 1 };
    await expect(waitForDatabase(offline, { timeoutMs: 300, intervalMs: 50 })).rejects.toMatchObject({
      code: 'ECONNREFUSED',
    });
  });

  it('não insiste com senha errada', async () => {
    const started = Date.now();
    await expect(
      waitForDatabase({ ...migrator(), password: 'errada' }, { timeoutMs: 30_000 }),
    ).rejects.toBeInstanceOf(pg.DatabaseError);
    expect(Date.now() - started).toBeLessThan(5_000);
  });
});

describe('primeiro administrador', () => {
  const DB2 = 'farmaerp_first_admin_test';
  const owner = () => connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD, DB2);
  const values = { email: 'Dono@Exemplo.com.br', password: 'senha-inicial-de-teste', groupName: 'Rede Teste' };

  beforeAll(async () => {
    await withClient(admin('postgres'), async (client) => {
      await client.query(`DROP DATABASE IF EXISTS ${DB2} WITH (FORCE)`);
      await client.query(`CREATE DATABASE ${DB2}`);
    });
    await bootstrapRoles(admin(DB2), passwords());
    await runMigrations(owner());
  });
  afterAll(() =>
    withClient(admin('postgres'), (client) => client.query(`DROP DATABASE IF EXISTS ${DB2} WITH (FORCE)`)),
  );

  const state = () =>
    withClient(owner(), async (client) => ({
      groups: (await client.query('SELECT name FROM economic_group')).rows,
      users: (await client.query(
        `SELECT u.email, u.is_group_admin, c.must_change_password, c.password_hash
           FROM user_account u JOIN user_credential c ON c.user_id = u.id`,
      )).rows,
    }));

  it('exige o nome do grupo quando ainda não existe nenhum', async () => {
    await expect(bootstrapAdmin(owner(), { ...values, groupName: undefined })).rejects.toThrow(/BOOTSTRAP_GROUP_NAME/);
  });

  it('recusa senha curta', async () => {
    await expect(bootstrapAdmin(owner(), { ...values, password: 'curta' })).rejects.toThrow(/10 caracteres/);
  });

  it('cria o grupo e o admin, com troca obrigatória de senha', async () => {
    expect(await bootstrapAdmin(owner(), values)).toBe('created');
    const { groups, users } = await state();
    expect(groups).toEqual([{ name: 'Rede Teste' }]);
    expect(users).toHaveLength(1);
    expect(users[0]).toMatchObject({
      email: 'dono@exemplo.com.br', is_group_admin: true, must_change_password: true,
    });
    expect(users[0].password_hash).toMatch(/^\$argon2id\$/);
    expect(users[0].password_hash).not.toContain(values.password);
  });

  it('rodar de novo não muda nada, nem a senha', async () => {
    const before = await state();
    expect(await bootstrapAdmin(owner(), { ...values, password: 'outra-senha-de-teste' })).toBe('skipped');
    expect(await state()).toEqual(before);
  });

  it('com o grupo já criado, acrescenta o admin nele', async () => {
    expect(await bootstrapAdmin(owner(), { email: 'outro@exemplo.com.br', password: 'senha-inicial-de-teste' })).toBe('created');
    const { groups, users } = await state();
    expect(groups).toHaveLength(1);
    expect(users).toHaveLength(2);
  });
});
