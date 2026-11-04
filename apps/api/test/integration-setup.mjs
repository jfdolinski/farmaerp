// Recria o banco de integração com migrations e seed. O banco de desenvolvimento não é tocado.
import { join } from 'node:path';
import pg from 'pg';
import { runMigrations, runSeed } from '../../../db/scripts/lib.mjs';

const DATABASE = 'farmaerp_integration';

export default async function setup() {
  try {
    process.loadEnvFile(join(import.meta.dirname, '..', '..', '..', '.env'));
  } catch {
    // Sem arquivo .env, valem as variáveis do ambiente.
  }

  const connection = (user, password, database) => ({
    host: process.env.DB_HOST ?? '127.0.0.1',
    port: Number(process.env.DB_PORT ?? 5432),
    user,
    password,
    database,
  });
  const withClient = async (config, fn) => {
    const client = new pg.Client(config);
    await client.connect();
    try {
      await fn(client);
    } finally {
      await client.end();
    }
  };
  const admin = (database) =>
    connection('postgres', process.env.POSTGRES_PASSWORD, database);
  const migrator = connection(
    'farmaerp_migrator',
    process.env.FARMAERP_MIGRATOR_PASSWORD,
    DATABASE,
  );

  await withClient(admin('postgres'), async (client) => {
    await client.query(`DROP DATABASE IF EXISTS ${DATABASE} WITH (FORCE)`);
    await client.query(`CREATE DATABASE ${DATABASE}`);
    await client.query(`GRANT CREATE ON DATABASE ${DATABASE} TO farmaerp_migrator`);
  });
  await withClient(admin(DATABASE), async (client) => {
    await client.query('GRANT CREATE, USAGE ON SCHEMA public TO farmaerp_migrator');
    await client.query('GRANT USAGE ON SCHEMA public TO farmaerp_app');
  });

  await runMigrations(migrator);
  await runSeed(migrator, 'development');
}
