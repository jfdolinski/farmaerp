import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { asUser, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

// Padrões fiscais da NF-e de devolução ao fornecedor, por filial.

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const DEFAULTS = {
  cfop_internal: '5202', cfop_interstate: '6202', cfop_st_internal: '5411', cfop_st_interstate: '6411',
  simples_csosn: '102', simples_csosn_st: '500', normal_cst: '00', normal_cst_st: '60', pis_cst: '49', cofins_cst: '49',
  transfer_cfop_internal: '5152', transfer_cfop_interstate: '6152',
  transfer_cfop_st_internal: '5409', transfer_cfop_st_interstate: '6409',
};

const list = (client) => client.query('SELECT * FROM app.return_tax_settings()').then((r) => r.rows);
const set = (client, branchId, data) =>
  client.query('SELECT app.set_return_tax_setting($1, $2::jsonb) AS v', [branchId, JSON.stringify(data)]).then((r) => r.rows[0].v);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('padrões fiscais da devolução ao fornecedor', () => {
  it('os padrões de fábrica ficam num só lugar, também como padrão das colunas da tabela', async () => {
    expect((await ownerPool.query('SELECT app.return_tax_defaults() AS d')).rows[0].d).toEqual(DEFAULTS);
    const owner = await ownerPool.connect();
    try {
      await owner.query('BEGIN');
      await owner.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      const row = (await owner.query(
        'INSERT INTO purchase_return_tax_setting (economic_group_id, branch_id) VALUES ($1, $2) RETURNING *',
        [a.group.id, a.branchFree.id],
      )).rows[0];
      for (const [key, value] of Object.entries(DEFAULTS)) expect(row[key]).toBe(value);
    } finally {
      await owner.query('ROLLBACK');
      owner.release();
    }
  });

  it('lista as filiais com os padrões; sem alteração, os de fábrica', async () => {
    await asUser(a.admin.id, async (client) => {
      const rows = await list(client);
      expect(rows.map((r) => r.branch_id).sort()).toEqual([a.branch1.id, a.branch2.id, a.branchFree.id].sort());
      for (const row of rows) expect(row).toMatchObject({ settings: DEFAULTS, customized: false, can_manage: true });
    });
  });

  it('altera só os campos que vierem, aparando espaços; volta ao padrão', async () => {
    await asUser(a.admin.id, async (client) => {
      const changed = await set(client, a.branch1.id, { cfop_internal: ' 5949 ', pis_cst: '99', unknown: 'x', normal_cst: null });
      expect(changed).toEqual({ ...DEFAULTS, cfop_internal: '5949', pis_cst: '99' });
      // Segunda alteração parte da primeira.
      expect(await set(client, a.branch1.id, { simples_csosn: 500 })).toEqual({ ...DEFAULTS, cfop_internal: '5949', pis_cst: '99', simples_csosn: '500' });
      const row = (await list(client)).find((r) => r.branch_id === a.branch1.id);
      expect(row).toMatchObject({ customized: true, settings: { cfop_internal: '5949', simples_csosn: '500' } });
      expect((await list(client)).find((r) => r.branch_id === a.branch2.id).customized).toBe(false);
      expect((await client.query('SELECT app.reset_return_tax_setting($1) AS v', [a.branch1.id])).rows[0].v).toEqual(DEFAULTS);
      expect((await list(client)).find((r) => r.branch_id === a.branch1.id).customized).toBe(false);
      // Uma linha só por filial.
      const count = await client.query('SELECT count(*)::int AS n FROM v_purchase_return_tax_setting WHERE branch_id = $1', [a.branch1.id]);
      expect(count.rows[0].n).toBe(1);
    });
  });

  it('a emissão usa o que foi alterado', async () => {
    await asUser(a.admin.id, async (client) => {
      await set(client, a.branch2.id, { cfop_st_internal: '5413' });
      const { rows } = await client.query('SELECT cfop_st_internal FROM v_purchase_return_tax_setting WHERE branch_id = $1', [a.branch2.id]);
      expect(rows).toEqual([{ cfop_st_internal: '5413' }]);
    });
  });

  it('valor fora da lista ou no formato errado é recusado com FA775, sem mudar nada', async () => {
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => set(client, a.branch1.id, { cfop_internal: '6202' }), 'FA775');
      await expectCode(client, () => set(client, a.branch1.id, { cfop_interstate: '620' }), 'FA775');
      await expectCode(client, () => set(client, a.branch1.id, { simples_csosn: '101' }), 'FA775');
      await expectCode(client, () => set(client, a.branch1.id, { normal_cst: '10' }), 'FA775');
      await expectCode(client, () => set(client, a.branch1.id, { cofins_cst: '01' }), 'FA775');
      await expectCode(client, () => client.query("SELECT app.set_return_tax_setting($1, '[]'::jsonb)", [a.branch1.id]), 'FA775');
      expect((await list(client)).find((r) => r.branch_id === a.branch1.id).settings).toEqual(DEFAULTS);
    });
  });

  it('as colunas da tabela usam a mesma fonte de padrões', async () => {
    const { rows } = await ownerPool.query(`
      SELECT a.attname AS column, pg_get_expr(d.adbin, d.adrelid) AS expr
        FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
       WHERE d.adrelid = 'public.purchase_return_tax_setting'::regclass`);
    for (const column of Object.keys(DEFAULTS)) {
      expect(rows.find((r) => r.column === column)?.expr, column).toContain('return_tax_defaults()');
    }
  });

  it('quem só consulta o fiscal vê os padrões, mas não altera', async () => {
    // Perfil só com fiscal.view, na filial 1.
    const role = (await ownerPool.query(
      "INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING id", [a.group.id, `Consulta fiscal ${randomUUID().slice(0, 8)}`],
    )).rows[0].id;
    await ownerPool.query("INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'fiscal.view'", [role]);
    const viewer = (await ownerPool.query(
      'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING id', [a.group.id, 'Consulta fiscal'],
    )).rows[0].id;
    await ownerPool.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [viewer, role]);
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [viewer, a.branch1.id]);
    await asUser(viewer, async (client) => {
      const rows = await list(client);
      expect(rows.map((r) => [r.branch_id, r.can_manage])).toEqual([[a.branch1.id, false]]);
      await expectCode(client, () => set(client, a.branch1.id, { pis_cst: '99' }), 'FA002');
    });
  });

  it('só quem tem fiscal.manage na filial altera; filial de outro grupo não existe', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      expect(await list(client)).toEqual([]);
      await expectCode(client, () => set(client, a.branch1.id, { pis_cst: '99' }), 'FA002');
      await expectCode(client, () => client.query('SELECT app.reset_return_tax_setting($1)', [a.branch1.id]), 'FA002');
    });
    await asUser(b.admin.id, async (client) => {
      expect((await list(client)).map((r) => r.branch_id)).not.toContain(a.branch1.id);
      await expectCode(client, () => set(client, a.branch1.id, { pis_cst: '99' }), 'FA006');
      await expectCode(client, () => set(client, randomUUID(), { pis_cst: '99' }), 'FA006');
    });
  });
});
