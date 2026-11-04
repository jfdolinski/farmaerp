import { catalog, codeFromDbError } from '@farmaerp/error-catalog';
import { afterAll, describe, expect, it } from 'vitest';
import { closePools, ownerPool } from './helpers.mjs';

afterAll(closePools);

async function appFunctionSources() {
  const { rows } = await ownerPool.query(`
    SELECT p.proname, p.prosrc
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'app'`);
  return rows;
}

// Mensagem e código de cada RAISE que usa ERRCODE.
function raisedErrors(source) {
  const raise = /RAISE EXCEPTION '((?:[^']|'')*)'\s+USING ERRCODE = '([^']+)'/g;
  return [...source.matchAll(raise)].map(([, message, code]) => ({
    message: message.replace(/''/g, "'"),
    code,
  }));
}

describe('erros levantados pelo banco', () => {
  it('toda função levanta só códigos do catálogo, com a mensagem do catálogo', async () => {
    let total = 0;
    for (const { proname, prosrc } of await appFunctionSources()) {
      for (const { code, message } of raisedErrors(prosrc)) {
        total += 1;
        expect(Object.keys(catalog), `${proname}: ${code}`).toContain(code);
        expect(message, `${proname}: ${code}`).toBe(catalog[code].message);
      }
    }
    expect(total).toBeGreaterThanOrEqual(16);
  });
});

describe('constraints com regra de negócio', () => {
  it('todo CHECK de tabela pública tem código próprio', async () => {
    const { rows } = await ownerPool.query(`
      SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND con.contype = 'c'`);
    expect(rows.length).toBeGreaterThan(0);
    for (const { conname } of rows) {
      expect(codeFromDbError({ code: '23514', constraint: conname }), conname).not.toBe('FA005');
    }
  });

  it('todo índice único de registros ativos tem código próprio', async () => {
    const { rows } = await ownerPool.query(`
      SELECT i.indexname
        FROM pg_indexes i
       WHERE i.schemaname = 'public' AND i.indexname LIKE '%\\_active\\_key'`);
    expect(rows.length).toBeGreaterThan(0);
    for (const { indexname } of rows) {
      expect(codeFromDbError({ code: '23505', constraint: indexname }), indexname).not.toBe('FA003');
    }
  });

  it('o catálogo não cita constraints que não existem mais', async () => {
    const { rows } = await ownerPool.query(`
      SELECT conname AS name FROM pg_constraint
      UNION
      SELECT indexname FROM pg_indexes WHERE schemaname = 'public'`);
    const existing = new Set(rows.map((row) => row.name));
    for (const [code, entry] of Object.entries(catalog)) {
      for (const constraint of entry.dbConstraints) {
        expect(existing.has(constraint), `${code}: ${constraint}`).toBe(true);
      }
    }
  });
});
