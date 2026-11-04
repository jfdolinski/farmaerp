import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { bootstrapRoles, runMigrations, runSeed, waitForDatabase, withClient } from '../scripts/lib.mjs';
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
