import { afterAll, describe, expect, it } from 'vitest';
import { closePools, ownerPool } from './helpers.mjs';

// CNPJ alfanumérico (NT Conjunta DFe 2025.001, NT 2026.004): as conferências de formato da chave de
// acesso aceitam letras nas posições do CNPJ (7 a 18) e só ali.

afterAll(closePools);

const ALFA_KEY = '35261112ABC34501DE35550010000001231123456788';
const NUMERIC_KEY = '35261111222333000181550010000001231123456781';

describe('CNPJ alfanumérico (0093)', () => {
  it('as restrições da chave aceitam letras só no CNPJ', async () => {
    const names = [
      'fiscal_document_access_key_check', 'document_import_note_key_check', 'imported_sale_key_check', 'imported_stock_note_key_check',
      'import_waiting_note_key_check', 'central_nfe_access_key_check',
    ];
    const { rows } = await ownerPool.query(
      "SELECT conname, substring(pg_get_constraintdef(oid) FROM '~ ''([^'']+)''') AS pattern FROM pg_constraint WHERE conname = ANY($1)",
      [names],
    );
    expect(rows.map((row) => row.conname).sort()).toEqual([...names].sort());
    for (const { conname, pattern } of rows) {
      const check = async (value) => (await ownerPool.query('SELECT $1 ~ $2 AS ok', [value, pattern])).rows[0].ok;
      expect(await check(ALFA_KEY), conname).toBe(true);
      expect(await check(NUMERIC_KEY), conname).toBe(true);
      expect(await check(`A${NUMERIC_KEY.slice(1)}`), conname).toBe(false);
      expect(await check(`${NUMERIC_KEY.slice(0, 43)}A`), conname).toBe(false);
      expect(await check(ALFA_KEY.toLowerCase()), conname).toBe(false);
    }
  });

  it('o documento da contraparte na nota importada aceita o CNPJ com letras', async () => {
    const { rows: [{ pattern }] } = await ownerPool.query(
      "SELECT substring(pg_get_constraintdef(oid) FROM '~ ''([^'']+)''') AS pattern FROM pg_constraint WHERE conname = 'imported_stock_note_party_document_check'",
    );
    const check = async (value) => (await ownerPool.query('SELECT $1 ~ $2 AS ok', [value, pattern])).rows[0].ok;
    expect(await check('12ABC34501DE35')).toBe(true);
    expect(await check('11222333000181')).toBe(true);
    expect(await check('12345678909')).toBe(true);
    expect(await check('12ABC34501DE3A')).toBe(false);
    expect(await check('1234567890')).toBe(false);
  });

  it('as funções de importação não exigem mais a chave só com números', async () => {
    for (const name of ['import_record_note', 'import_nfce', 'import_nfce_cancel', 'import_nfe']) {
      const { rows: [{ body }] } = await ownerPool.query(
        "SELECT pg_get_functiondef(p.oid) AS body FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'app' AND p.proname = $1",
        [name],
      );
      expect(body, name).not.toContain('[0-9]{44}');
      expect(body, name).toContain('[0-9]{6}[0-9A-Z]{12}[0-9]{26}');
    }
  });
});
