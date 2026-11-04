import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, asUser, closePools, createFixtures, hasCode, uuidV4,
} from './helpers.mjs';

let a;

beforeAll(async () => {
  ({ a } = await createFixtures());
});
afterAll(closePools);

const insertGroup = (client, name = 'Grupo teste') =>
  client.query('INSERT INTO economic_group (name) VALUES ($1) RETURNING *', [name]);

describe('UUID v7', () => {
  it('gera UUID v7 por padrão', async () => {
    await asOwner(async (client) => {
      const { rows } = await insertGroup(client);
      const { rows: version } = await client.query('SELECT uuid_extract_version($1::uuid) AS v', [rows[0].id]);
      expect(version[0].v).toBe(7);
    });
  });

  it('mantém o UUID v7 gerado pelo cliente', async () => {
    await asOwner(async (client) => {
      const id = '019a0000-0000-7000-8000-0000000000ff';
      const { rows } = await client.query(
        'INSERT INTO economic_group (id, name) VALUES ($1, $2) RETURNING id',
        [id, 'Grupo com id do cliente'],
      );
      expect(rows[0].id).toBe(id);
    });
  });

  it('rejeita UUID de outra versão', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query('INSERT INTO economic_group (id, name) VALUES ($1, $2)', [uuidV4(), 'Grupo inválido']),
      ).rejects.toSatisfy(hasCode('FA106'));
    });
  });
});

describe('auditoria e versão', () => {
  it('começa na versão 1, mesmo se o cliente informar outra', async () => {
    await asOwner(async (client) => {
      const { rows } = await client.query(
        'INSERT INTO economic_group (name, version) VALUES ($1, 99) RETURNING version',
        ['Grupo versão'],
      );
      expect(rows[0].version).toBe('1');
    });
  });

  it('incrementa a versão e atualiza updated_at a cada alteração', async () => {
    await asOwner(async (client) => {
      const { rows: [created] } = await insertGroup(client);
      const { rows: [first] } = await client.query(
        `UPDATE economic_group SET name = 'Novo nome', version = 500 WHERE id = $1 RETURNING *`,
        [created.id],
      );
      const { rows: [second] } = await client.query(
        `UPDATE economic_group SET name = 'Outro nome' WHERE id = $1 RETURNING *`,
        [created.id],
      );
      expect(first.version).toBe('2');
      expect(second.version).toBe('3');
      expect(second.updated_at.getTime()).toBeGreaterThanOrEqual(created.updated_at.getTime());
    });
  });

  it('preenche updated_by com o usuário da transação e ignora o valor enviado', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query(
        `UPDATE company SET trade_name = 'Novo nome', updated_by = $2 WHERE id = $1 RETURNING updated_by`,
        [a.company.id, a.oneBranchUser.id],
      );
      expect(rows[0].updated_by).toBe(a.admin.id);
    });
  });

  it('não permite alterar id', async () => {
    await asOwner(async (client) => {
      const { rows: [created] } = await insertGroup(client);
      await expect(
        client.query(
          `UPDATE economic_group SET id = '019a0000-0000-7000-8000-0000000000fe' WHERE id = $1`,
          [created.id],
        ),
      ).rejects.toSatisfy(hasCode('FA101'));
    });
  });

  it('não permite alterar created_at', async () => {
    await asOwner(async (client) => {
      const { rows: [created] } = await insertGroup(client);
      await expect(
        client.query(`UPDATE economic_group SET created_at = '2000-01-01' WHERE id = $1`, [created.id]),
      ).rejects.toSatisfy(hasCode('FA102'));
    });
  });

  it('gera erro quando o usuário da transação está malformado', async () => {
    await asUser('nao-e-um-uuid', async (client) => {
      await expect(client.query('SELECT * FROM branch')).rejects.toThrow(/invalid input syntax for type uuid/);
    });
  });
});

describe('exclusão', () => {
  it('bloqueia DELETE mesmo para o dono das tabelas', async () => {
    await asOwner(async (client) => {
      await expect(client.query('DELETE FROM terminal')).rejects.toSatisfy(hasCode('FA103'));
    });
  });

  it('bloqueia TRUNCATE mesmo para o dono das tabelas', async () => {
    await asOwner(async (client) => {
      await expect(client.query('TRUNCATE user_branch')).rejects.toSatisfy(hasCode('FA103'));
    });
  });

  it('nega DELETE para a API', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('DELETE FROM terminal')).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('a exclusão lógica mantém o registro na tabela e o tira da view', async () => {
    await asOwner(async (client) => {
      await client.query('UPDATE terminal SET deleted_at = now() WHERE id = $1', [a.terminal1.id]);
      const { rows: table } = await client.query('SELECT 1 FROM terminal WHERE id = $1', [a.terminal1.id]);
      const { rows: view } = await client.query('SELECT 1 FROM v_terminal WHERE id = $1', [a.terminal1.id]);
      expect(table).toHaveLength(1);
      expect(view).toHaveLength(0);
    });
  });

  it('um registro excluído libera os valores únicos para um novo registro', async () => {
    await asOwner(async (client) => {
      await client.query('UPDATE terminal SET deleted_at = now() WHERE id = $1', [a.terminal1.id]);
      const { rowCount } = await client.query(
        `INSERT INTO terminal (branch_id, name, profile, status, public_key)
         VALUES ($1, $2, 'cashier', 'active', $3)`,
        [a.branch1.id, a.terminal1.name, a.terminal1.public_key],
      );
      expect(rowCount).toBe(1);
    });
  });

  it('um valor único repetido é rejeitado entre registros ativos', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(
          `INSERT INTO terminal (branch_id, public_key) VALUES ($1, $2)`,
          [a.branch1.id, a.terminal1.public_key],
        ),
      ).rejects.toSatisfy(hasCode('FA220'));
    });
  });
});
