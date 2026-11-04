import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runner } from 'node-pg-migrate';
import pg from 'pg';

const here = dirname(fileURLToPath(import.meta.url));

export const migrationsDir = join(here, '..', 'migrations');
export const seedFile = join(here, '..', 'seeds', 'dev.sql');
export const rolesFile = join(here, '..', 'bootstrap', 'sql', 'roles.sql');

/** Lê uma variável obrigatória, com mensagem clara quando ela não existe. */
export function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`A variável ${name} não está definida. Copie .env.example para .env.`);
  }
  return value;
}

/** Configuração de conexão com o papel de dono das tabelas. */
export function migratorConfig(database = process.env.DB_NAME ?? 'farmaerp') {
  return {
    host: process.env.DB_HOST ?? '127.0.0.1',
    port: Number(process.env.DB_PORT ?? 5432),
    user: 'farmaerp_migrator',
    password: requireEnv('FARMAERP_MIGRATOR_PASSWORD'),
    database,
  };
}

/** Aplica as migrations pendentes e retorna os nomes das que foram aplicadas. */
export async function runMigrations(config = migratorConfig()) {
  const applied = await runner({
    databaseUrl: config,
    dir: migrationsDir,
    direction: 'up',
    migrationsSchema: 'db_migrations',
    createMigrationsSchema: true,
    migrationsTable: 'applied_migrations',
    checkOrder: true,
    log: () => {},
  });
  return applied.map((migration) => migration.name);
}

export async function withClient(config, fn) {
  const client = new pg.Client(config);
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

/**
 * Cria os papéis do banco e o prefixo de log com o ID de rastreio.
 * Roda com a senha de administrador e pode ser repetido sem efeito colateral.
 */
export async function bootstrapRoles(adminConfig, { migratorPassword, appPassword }) {
  await withClient(adminConfig, async (client) => {
    await client.query(`SELECT set_config('farmaerp.migrator_password', $1, false)`, [migratorPassword]);
    await client.query(`SELECT set_config('farmaerp.app_password', $1, false)`, [appPassword]);
    await client.query(await readFile(rolesFile, 'utf8'));
    await client.query(`ALTER SYSTEM SET log_line_prefix = '%m [%p] app=%a '`);
    await client.query('SELECT pg_reload_conf()');
  });
}

/** Seed de demonstração, só em desenvolvimento e homologação. */
export async function runSeed(config = migratorConfig(), environment = process.env.APP_ENV) {
  if (environment !== 'development' && environment !== 'homologation') {
    throw new Error(
      `O seed só roda em desenvolvimento ou homologação (APP_ENV: ${environment ?? 'não definido'}).`,
    );
  }
  await withClient(config, async (client) => {
    await client.query(await readFile(seedFile, 'utf8'));
  });
}

/** Espera o banco aceitar conexões: no deploy, ele pode subir depois da API. */
export async function waitForDatabase(config, { timeoutMs = 60_000, intervalMs = 2_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      await withClient(config, (client) => client.query('SELECT 1'));
      return;
    } catch (error) {
      const stillStarting = ['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'ECONNRESET', 'ETIMEDOUT', '57P03']
        .includes(error.code);
      if (!stillStarting || Date.now() >= deadline) {
        throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
  }
}
