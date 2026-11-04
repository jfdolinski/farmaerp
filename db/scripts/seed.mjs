import { readFile } from 'node:fs/promises';
import pg from 'pg';
import { migratorConfig, seedFile } from './lib.mjs';

if (process.env.NODE_ENV === 'production') {
  throw new Error('O seed de desenvolvimento não pode rodar em produção.');
}

const client = new pg.Client(migratorConfig());
await client.connect();
try {
  await client.query(await readFile(seedFile, 'utf8'));
  console.log('Seed de desenvolvimento aplicado.');
} finally {
  await client.end();
}
