import pg from 'pg';
import { runMigrations } from '../scripts/lib.mjs';
import { closePools, connectionConfig, TEST_DATABASE } from './helpers.mjs';

async function withAdmin(database, fn) {
  const client = new pg.Client(connectionConfig('postgres', process.env.POSTGRES_PASSWORD, database));
  await client.connect();
  try {
    await fn(client);
  } finally {
    await client.end();
  }
}

/** Recria o banco de testes do zero; o banco de desenvolvimento não é tocado. */
export default async function setup() {
  await withAdmin('postgres', async (client) => {
    await client.query(`DROP DATABASE IF EXISTS ${TEST_DATABASE} WITH (FORCE)`);
    await client.query(`CREATE DATABASE ${TEST_DATABASE}`);
    await client.query(`GRANT CREATE ON DATABASE ${TEST_DATABASE} TO farmaerp_migrator`);
  });
  await withAdmin(TEST_DATABASE, async (client) => {
    await client.query('GRANT CREATE, USAGE ON SCHEMA public TO farmaerp_migrator');
    await client.query('GRANT USAGE ON SCHEMA public TO farmaerp_app');
  });

  await runMigrations(
    connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD),
  );
  await closePools();
}
