import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runner } from 'node-pg-migrate';

const here = dirname(fileURLToPath(import.meta.url));

export const migrationsDir = join(here, '..', 'migrations');
export const seedFile = join(here, '..', 'seeds', 'dev.sql');

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
