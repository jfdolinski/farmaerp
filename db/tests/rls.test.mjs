import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asUser, branchCnpj, closePools, createFixtures, hasCode, ids, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const selectAll = async (client, table) => (await client.query(`SELECT * FROM ${table}`)).rows;
const sorted = (...rows) => ids(rows);

const ALL_TABLES = [
  'economic_group', 'company', 'branch_group', 'region',
  'branch', 'terminal', 'user_account', 'user_branch',
];

// Os testes usam várias execuções no mesmo banco: comparar só as filiais destes grupos.
const onlyFixtures = (rows, ...fixtures) => {
  const allowed = new Set(fixtures.flatMap((f) => [f.branch1.id, f.branch2.id, f.branchFree.id]));
  return rows.filter((row) => allowed.has(row.id));
};

describe('sem contexto de usuário', () => {
  it.each(ALL_TABLES)('%s não retorna nenhuma linha', async (table) => {
    await asUser(null, async (client) => {
      expect(await selectAll(client, table)).toEqual([]);
    });
  });

  it.each(ALL_TABLES)('v_%s não retorna nenhuma linha', async (table) => {
    await asUser(null, async (client) => {
      expect(await selectAll(client, `v_${table}`)).toEqual([]);
    });
  });

  it('sem nenhum set_config na conexão também não retorna linhas', async () => {
    const { rows } = await appPool.query('SELECT * FROM branch');
    expect(rows).toEqual([]);
  });

  it('não consegue inserir', async () => {
    await asUser(null, async (client) => {
      await expect(
        client.query(
          `INSERT INTO region (branch_group_id, name) VALUES ($1, 'Sem contexto')`,
          [a.branchGroup.id],
        ),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('usuário inexistente não vê nada', async () => {
    await asUser('019a0000-0000-7000-8000-00000000dead', async (client) => {
      expect(await selectAll(client, 'branch')).toEqual([]);
    });
  });
});

describe('usuário comum', () => {
  it('com uma filial vê só a própria filial e seus terminais', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      expect(ids(await selectAll(client, 'branch'))).toEqual([a.branch1.id]);
      expect(ids(await selectAll(client, 'terminal'))).toEqual([a.terminal1.id]);
    });
  });

  it('com duas filiais vê as duas e os terminais das duas', async () => {
    await asUser(a.twoBranchesUser.id, async (client) => {
      expect(ids(await selectAll(client, 'branch'))).toEqual(sorted(a.branch1, a.branch2));
      expect(ids(await selectAll(client, 'terminal'))).toEqual(sorted(a.terminal1, a.terminal2));
    });
  });

  it('sem filial não vê filial nem estrutura', async () => {
    await asUser(a.noBranchUser.id, async (client) => {
      for (const table of ['branch', 'terminal', 'company', 'region', 'branch_group', 'economic_group']) {
        expect(await selectAll(client, table), table).toEqual([]);
      }
    });
  });

  it('vê empresa, região, grupo de filial e grupo econômico da sua filial', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      expect(ids(await selectAll(client, 'company'))).toEqual([a.company.id]);
      expect(ids(await selectAll(client, 'region'))).toEqual([a.region.id]);
      expect(ids(await selectAll(client, 'branch_group'))).toEqual([a.branchGroup.id]);
      expect(ids(await selectAll(client, 'economic_group'))).toEqual([a.group.id]);
    });
  });

  it('vê só o próprio cadastro e os próprios vínculos', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      expect(ids(await selectAll(client, 'user_account'))).toEqual([a.oneBranchUser.id]);
      expect(ids(await selectAll(client, 'user_branch'))).toEqual([a.oneBranchLink.id]);
    });
  });

  it('as views também respeitam a RLS', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      expect(ids(await selectAll(client, 'v_branch'))).toEqual([a.branch1.id]);
      expect(ids(await selectAll(client, 'v_terminal'))).toEqual([a.terminal1.id]);
    });
  });

  it('não vê nada do outro grupo econômico', async () => {
    await asUser(a.twoBranchesUser.id, async (client) => {
      const { rows } = await client.query('SELECT 1 FROM branch WHERE id = $1', [b.branch1.id]);
      expect(rows).toEqual([]);
    });
  });

  it.each([
    ['company', 'trade_name', () => a.company.id],
    ['region', 'name', () => a.region.id],
    ['branch', 'name', () => a.branch1.id],
    ['terminal', 'name', () => a.terminal1.id],
    ['economic_group', 'name', () => a.group.id],
    ['branch_group', 'name', () => a.branchGroup.id],
  ])('não altera %s, mesmo enxergando', async (table, column, id) => {
    await asUser(a.oneBranchUser.id, async (client) => {
      const { rowCount } = await client.query(
        `UPDATE ${table} SET ${column} = 'Invadido' WHERE id = $1`,
        [id()],
      );
      expect(rowCount).toBe(0);
    });
  });

  it('não concede a si mesmo o perfil de administrador', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      await expect(
        client.query('SELECT app.assign_role($1, $2, NULL)', [a.oneBranchUser.id, a.adminRole.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('não cria vínculo com outra filial', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      await expect(
        client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [a.oneBranchUser.id, a.branch2.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('não cria terminal na própria filial', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      await expect(
        client.query(`INSERT INTO terminal (branch_id, public_key) VALUES ($1, 'chave-comum')`, [a.branch1.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('perde o acesso quando o vínculo é excluído', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE user_branch SET deleted_at = now() WHERE id = $1', [a.oneBranchLink.id]);
      await setUser(client, a.oneBranchUser.id);
      expect(await selectAll(client, 'branch')).toEqual([]);
      expect(await selectAll(client, 'terminal')).toEqual([]);
    });
  });

  it('o vínculo excluído não afeta outros usuários da filial', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE user_branch SET deleted_at = now() WHERE id = $1', [a.oneBranchLink.id]);
      await setUser(client, a.twoBranchesUser.id);
      expect(ids(await selectAll(client, 'branch'))).toEqual(sorted(a.branch1, a.branch2));
    });
  });
});

describe('admin do grupo', () => {
  it('vê todas as filiais, usuários e terminais do seu grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const branches = await selectAll(client, 'branch');
      expect(ids(branches)).toEqual(sorted(a.branch1, a.branch2, a.branchFree));

      const users = await selectAll(client, 'user_account');
      expect(users.every((user) => user.economic_group_id === a.group.id)).toBe(true);
      expect(ids(users)).toContain(a.noBranchUser.id);
    });
  });

  it('não vê nada de outro grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      expect(onlyFixtures(await selectAll(client, 'branch'), b)).toEqual([]);
      for (const [table, id] of [
        ['economic_group', b.group.id],
        ['company', b.company.id],
        ['branch_group', b.branchGroup.id],
        ['region', b.region.id],
        ['terminal', b.terminal1.id],
        ['user_account', b.admin.id],
        ['user_branch', b.oneBranchLink.id],
      ]) {
        const { rows } = await client.query(`SELECT 1 FROM ${table} WHERE id = $1`, [id]);
        expect(rows, table).toEqual([]);
      }
    });
  });

  it('não altera registros de outro grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      for (const [table, column, id] of [
        ['economic_group', 'name', b.group.id],
        ['company', 'trade_name', b.company.id],
        ['branch_group', 'name', b.branchGroup.id],
        ['region', 'name', b.region.id],
        ['branch', 'name', b.branch1.id],
        ['terminal', 'name', b.terminal1.id],
        ['user_account', 'name', b.admin.id],
      ]) {
        const { rowCount } = await client.query(`UPDATE ${table} SET ${column} = 'Invadido' WHERE id = $1`, [id]);
        expect(rowCount, table).toBe(0);
      }
    });
  });

  it('não cria registros em outro grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(`INSERT INTO region (branch_group_id, name) VALUES ($1, 'Invadida')`, [b.branchGroup.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('não cria grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(`INSERT INTO economic_group (name) VALUES ('Novo grupo')`),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('cria a estrutura completa com RETURNING', async () => {
    await asUser(a.admin.id, async (client) => {
      const root = randomRoot();
      const { rows: [company] } = await client.query(
        `INSERT INTO company (economic_group_id, legal_name, trade_name, cnpj_root)
         VALUES ($1, 'Nova Ltda', 'Nova', $2) RETURNING *`,
        [a.group.id, root],
      );
      const { rows: [branchGroup] } = await client.query(
        `INSERT INTO branch_group (economic_group_id, name) VALUES ($1, 'Novo grupo') RETURNING *`,
        [a.group.id],
      );
      const { rows: [region] } = await client.query(
        `INSERT INTO region (branch_group_id, name) VALUES ($1, 'Nova região') RETURNING *`,
        [branchGroup.id],
      );
      const { rows: [branch] } = await client.query(
        `INSERT INTO branch (company_id, region_id, name, cnpj)
         VALUES ($1, $2, 'Nova filial', $3) RETURNING *`,
        [company.id, region.id, branchCnpj(root, 1)],
      );
      const { rows: [terminal] } = await client.query(
        `INSERT INTO terminal (branch_id, public_key) VALUES ($1, 'chave-admin') RETURNING *`,
        [branch.id],
      );
      const { rows: [user] } = await client.query(
        `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Novo usuário') RETURNING *`,
        [a.group.id],
      );
      const { rows: [link] } = await client.query(
        `INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2) RETURNING *`,
        [user.id, branch.id],
      );

      expect(terminal.updated_by).toBe(a.admin.id);
      expect(link.updated_by).toBe(a.admin.id);
      expect(terminal.status).toBe('pending');

      // O vínculo recém-criado já vale para o novo usuário.
      await setUser(client, user.id);
      expect(ids(await selectAll(client, 'branch'))).toEqual([branch.id]);
    });
  });

  it('exclui logicamente com a RLS ativa, inclusive com RETURNING', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query(
        'UPDATE terminal SET deleted_at = now() WHERE id = $1 RETURNING deleted_at, version, updated_by',
        [a.terminal2.id],
      );
      expect(rows[0].deleted_at).toBeInstanceOf(Date);
      expect(rows[0].version).toBe('2');
      expect(rows[0].updated_by).toBe(a.admin.id);

      const { rows: active } = await client.query('SELECT 1 FROM v_terminal WHERE id = $1', [a.terminal2.id]);
      expect(active).toEqual([]);
    });
  });

  it('enxerga uma filial excluída e consegue reativá-la', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE branch SET deleted_at = now() WHERE id = $1', [a.branchFree.id]);

      const { rows: active } = await client.query('SELECT 1 FROM v_branch WHERE id = $1', [a.branchFree.id]);
      expect(active).toEqual([]);

      const { rows: reactivated } = await client.query(
        'UPDATE branch SET deleted_at = NULL WHERE id = $1 RETURNING id',
        [a.branchFree.id],
      );
      expect(ids(reactivated)).toEqual([a.branchFree.id]);
    });
  });

  it('uma filial excluída some para o usuário comum', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [link] } = await client.query(
        'INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2) RETURNING id',
        [a.noBranchUser.id, a.branchFree.id],
      );
      await client.query('UPDATE user_branch SET deleted_at = now() WHERE id = $1', [link.id]);
      await client.query('UPDATE branch SET deleted_at = now() WHERE id = $1', [a.branchFree.id]);
      await setUser(client, a.noBranchUser.id);
      expect(await selectAll(client, 'branch')).toEqual([]);
    });
  });

  it('não vincula usuário a filial de outro grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [a.noBranchUser.id, b.branch1.id]),
      ).rejects.toSatisfy(hasCode('FA210'));
    });
  });

  it('não exclui logicamente uma filial com filhos ativos', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query('UPDATE branch SET deleted_at = now() WHERE id = $1', [a.branch1.id]),
      ).rejects.toSatisfy(hasCode('FA105'));
    });
  });

  it('perde o acesso ao ser excluído', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE user_account SET deleted_at = now() WHERE id = $1', [a.secondAdmin.id]);
      await setUser(client, a.secondAdmin.id);
      expect(await selectAll(client, 'branch')).toEqual([]);
      expect(await selectAll(client, 'company')).toEqual([]);
    });
  });

  it('perde o acesso ao deixar de ser admin', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [assigned] } = await client.query('SELECT id FROM user_role WHERE user_id = $1', [a.secondAdmin.id]);
      await client.query('SELECT app.unassign_role($1)', [assigned.id]);
      await setUser(client, a.secondAdmin.id);
      expect(await selectAll(client, 'branch')).toEqual([]);
    });
  });
});

describe('isolamento de contexto', () => {
  it('o usuário definido na transação não vaza para a transação seguinte', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      expect((await client.query('SELECT * FROM company')).rows.length).toBeGreaterThan(0);
      await client.query('COMMIT');

      const { rows } = await client.query('SELECT * FROM company');
      expect(rows).toEqual([]);
    } finally {
      client.release();
    }
  });
});
