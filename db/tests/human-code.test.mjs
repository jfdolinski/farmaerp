import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, closePools, createFixtures, hasCode, ownerPool,
} from './helpers.mjs';

let a;
let b;

// Tabela de exemplo no lugar de produto e cliente, que só nascem na Etapa 2.
// Fica em outro esquema para não entrar nas verificações de conformidade.
beforeAll(async () => {
  ({ a, b } = await createFixtures());
  await ownerPool.query(`
    CREATE SCHEMA IF NOT EXISTS test_human_code;
    GRANT USAGE ON SCHEMA test_human_code TO farmaerp_app;
    CREATE TABLE IF NOT EXISTS test_human_code.item (
      id uuid PRIMARY KEY DEFAULT uuidv7(),
      economic_group_id uuid NOT NULL REFERENCES economic_group (id),
      code bigint NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      deleted_at timestamptz,
      version bigint NOT NULL DEFAULT 1,
      updated_by uuid,
      trace_id uuid
    );
    CALL app.apply_table_standard('test_human_code.item');
    CALL app.apply_human_code('test_human_code.item', 'item');
    CREATE TABLE IF NOT EXISTS test_human_code.other (LIKE test_human_code.item INCLUDING DEFAULTS);
    ALTER TABLE test_human_code.other ADD PRIMARY KEY (id);
    CALL app.apply_table_standard('test_human_code.other');
    CALL app.apply_human_code('test_human_code.other', 'other');
    GRANT SELECT, INSERT, UPDATE ON test_human_code.item, test_human_code.other TO farmaerp_app;
    CREATE POLICY item_all ON test_human_code.item TO farmaerp_app
      USING (economic_group_id = (SELECT app.permission_group('structure.manage')))
      WITH CHECK (economic_group_id = (SELECT app.permission_group('structure.manage')));
  `);
});
afterAll(closePools);

const insertItem = async (client, groupId, table = 'item') =>
  (await client.query(
    `INSERT INTO test_human_code.${table} (economic_group_id) VALUES ($1) RETURNING id, code`,
    [groupId],
  )).rows[0];
const codeOf = async (client, groupId, table) => Number((await insertItem(client, groupId, table)).code);

describe('sequência por grupo econômico', () => {
  it('gera códigos seguidos', async () => {
    await asOwner(async (client) => {
      const first = await codeOf(client, a.group.id);
      expect(await codeOf(client, a.group.id)).toBe(first + 1);
      expect(await codeOf(client, a.group.id)).toBe(first + 2);
    });
  });

  it('cada grupo econômico tem a própria sequência', async () => {
    await asOwner(async (client) => {
      const first = await codeOf(client, a.group.id);
      const otherFirst = await codeOf(client, b.group.id);
      expect(otherFirst).toBe(1);
      expect(await codeOf(client, a.group.id)).toBe(first + 1);
    });
  });

  it('cada tipo de item tem a própria sequência', async () => {
    await asOwner(async (client) => {
      const first = await codeOf(client, a.group.id);
      expect(await codeOf(client, a.group.id, 'other')).toBe(1);
      expect(await codeOf(client, a.group.id)).toBe(first + 1);
    });
  });

  it('o mesmo código pode existir em grupos diferentes', async () => {
    await asOwner(async (client) => {
      expect(await codeOf(client, a.group.id, 'other')).toBe(await codeOf(client, b.group.id, 'other'));
    });
  });
});

describe('concorrência e cancelamento', () => {
  it('uma transação cancelada não deixa buraco', async () => {
    const committed = async () => {
      const client = await ownerPool.connect();
      try {
        return await codeOf(client, a.group.id);
      } finally {
        client.release();
      }
    };
    const before = await committed();

    await asOwner(async (client) => {
      expect(await codeOf(client, a.group.id)).toBe(before + 1);
    });

    expect(await committed()).toBe(before + 1);
  });

  it('inclusões simultâneas geram códigos únicos e seguidos', async () => {
    const insertOne = async () => {
      const client = await ownerPool.connect();
      try {
        return await codeOf(client, b.group.id);
      } finally {
        client.release();
      }
    };
    const start = await insertOne();
    const codes = await Promise.all(Array.from({ length: 8 }, insertOne));

    expect([...codes].sort((x, y) => x - y)).toEqual(
      Array.from({ length: 8 }, (_, i) => start + i + 1),
    );
  });

  it('a segunda transação espera a primeira terminar', async () => {
    const first = await ownerPool.connect();
    const second = await ownerPool.connect();
    try {
      await first.query('BEGIN');
      await insertItem(first, a.group.id);

      await second.query('BEGIN');
      await second.query(`SET LOCAL lock_timeout = '300ms'`);
      await expect(insertItem(second, a.group.id)).rejects.toSatisfy(hasCode('FA008'));
    } finally {
      await first.query('ROLLBACK');
      await second.query('ROLLBACK');
      first.release();
      second.release();
    }
  });
});

describe('uso pela API', () => {
  it('gera o código para o admin', async () => {
    await asUser(a.admin.id, async (client) => {
      expect(await codeOf(client, a.group.id)).toBeGreaterThan(0);
    });
  });

  it('ignora o código enviado pela API', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query(
        `INSERT INTO test_human_code.item (economic_group_id, code) VALUES ($1, 999999) RETURNING code`,
        [a.group.id],
      );
      expect(Number(rows[0].code)).toBeLessThan(999999);
    });
  });

  it('a RLS de outro grupo econômico continua valendo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(insertItem(client, b.group.id)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('o código não muda depois do cadastro', async () => {
    await asOwner(async (client) => {
      const { id } = await insertItem(client, a.group.id);
      await expect(
        client.query('UPDATE test_human_code.item SET code = 5 WHERE id = $1', [id]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('a API não acessa os contadores', async () => {
    const { rows } = await ownerPool.query(`
      SELECT has_table_privilege('farmaerp_app', 'code_counter', 'SELECT') AS can_select,
             has_table_privilege('farmaerp_app', 'code_counter', 'INSERT') AS can_insert,
             has_table_privilege('farmaerp_app', 'code_counter', 'UPDATE') AS can_update,
             has_table_privilege('farmaerp_app', 'v_code_counter', 'SELECT') AS can_view,
             has_function_privilege('farmaerp_app', 'app.next_human_code(uuid, text)', 'EXECUTE') AS can_next`);
    expect(rows[0]).toEqual({
      can_select: false, can_insert: false, can_update: false, can_view: false, can_next: false,
    });
  });

  it('a API não consegue chamar o gerador direto', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(`SELECT app.next_human_code($1, 'item')`, [a.group.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('exclusão lógica', () => {
  it('não reaproveita o código de um registro excluído', async () => {
    await asOwner(async (client) => {
      const { id, code } = await insertItem(client, a.group.id);
      await client.query('UPDATE test_human_code.item SET deleted_at = now() WHERE id = $1', [id]);
      expect(await codeOf(client, a.group.id)).toBe(Number(code) + 1);
    });
  });

  it('nem a migração de dados pode repetir o código de um registro excluído', async () => {
    await asOwner(async (client) => {
      const { id, code } = await insertItem(client, a.group.id);
      await client.query('UPDATE test_human_code.item SET deleted_at = now() WHERE id = $1', [id]);
      await expect(
        client.query(
          'INSERT INTO test_human_code.item (economic_group_id, code) VALUES ($1, $2)',
          [a.group.id, code],
        ),
      ).rejects.toSatisfy(hasCode('FA003'));
    });
  });
});

describe('importação de códigos antigos', () => {
  const importItem = (client, groupId, code) =>
    client.query(
      'INSERT INTO test_human_code.other (economic_group_id, code) VALUES ($1, $2) RETURNING code',
      [groupId, code],
    );

  it('grava o código antigo e avança o contador', async () => {
    await asOwner(async (client) => {
      const { rows } = await importItem(client, a.group.id, 50000);
      expect(Number(rows[0].code)).toBe(50000);
      expect(await codeOf(client, a.group.id, 'other')).toBe(50001);
    });
  });

  it('um código antigo menor não faz o contador voltar', async () => {
    await asOwner(async (client) => {
      await importItem(client, a.group.id, 50000);
      await importItem(client, a.group.id, 200);
      expect(await codeOf(client, a.group.id, 'other')).toBe(50001);
    });
  });

  it('rejeita código antigo repetido', async () => {
    await asOwner(async (client) => {
      await importItem(client, a.group.id, 700);
      await expect(importItem(client, a.group.id, 700)).rejects.toSatisfy(hasCode('FA003'));
    });
  });
});

describe('aplicação do padrão', () => {
  it('recusa tabela sem as colunas necessárias', async () => {
    await asOwner(async (client) => {
      await client.query('CREATE TABLE test_human_code.incomplete (id uuid)');
      await expect(
        client.query(`CALL app.apply_human_code('test_human_code.incomplete', 'x')`),
      ).rejects.toThrow(/colunas obrigatórias: code, economic_group_id/);
    });
  });

  it('rejeita tipo de item com nome inválido', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(`SELECT app.next_human_code($1, 'Nome Inválido')`, [a.group.id]),
      ).rejects.toSatisfy(hasCode('FA108'));
    });
  });

  it('rejeita contador sem grupo econômico', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(`SELECT app.next_human_code(NULL, 'item')`),
      ).rejects.toSatisfy(hasCode('FA108'));
    });
  });
});

describe('número do terminal', () => {
  const approve = (client, id, name = `Caixa ${id}`) =>
    client.query(`SELECT app.approve_terminal($1, $2, 'cashier')`, [id, name]);

  async function pending(client, branchId) {
    const { rows } = await client.query(
      `SELECT app.create_pairing_request($1, 'windows', 'CAIXA', '0.1.0', 'system') AS r`,
      [randomBytes(32).toString('base64url')],
    );
    const claimed = await client.query('SELECT app.claim_pairing_request($1, $2) AS id', [rows[0].r.code, branchId]);
    return claimed.rows[0].id;
  }
  const numberOf = async (client, id) =>
    (await client.query('SELECT number FROM terminal WHERE id = $1', [id])).rows[0].number;

  it('terminal pendente ainda não tem número', async () => {
    await asUser(a.admin.id, async (client) => {
      expect(await numberOf(client, await pending(client, a.branchFree.id))).toBeNull();
    });
  });

  it('recebe números seguidos ao ser aprovado', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await pending(client, a.branchFree.id);
      const second = await pending(client, a.branchFree.id);
      await approve(client, second);
      await approve(client, first);
      expect(await numberOf(client, second)).toBe(1);
      expect(await numberOf(client, first)).toBe(2);
    });
  });

  it('terminal criado já ativo também recebe número, separado por filial', async () => {
    expect(a.terminal1.number).toBe(1);
    expect(a.terminal2.number).toBe(1);
  });

  it('terminal recusado não consome número', async () => {
    await asUser(a.admin.id, async (client) => {
      const refused = await pending(client, a.branchFree.id);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Recusado')`, [refused]);
      expect(await numberOf(client, refused)).toBeNull();

      const next = await pending(client, a.branchFree.id);
      await approve(client, next);
      expect(await numberOf(client, next)).toBe(1);
    });
  });

  it('mantém o número ao ser bloqueado e revogado', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await pending(client, a.branchFree.id);
      await approve(client, id);
      await client.query(`SELECT app.set_terminal_status($1, 'blocked', 'Motivo')`, [id]);
      expect(await numberOf(client, id)).toBe(1);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Motivo')`, [id]);
      expect(await numberOf(client, id)).toBe(1);
    });
  });

  it('não reaproveita o número de um terminal revogado ou excluído', async () => {
    await asUser(a.admin.id, async (client) => {
      const revoked = await pending(client, a.branchFree.id);
      await approve(client, revoked);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Motivo')`, [revoked]);

      const deleted = await pending(client, a.branchFree.id);
      await approve(client, deleted);
      await client.query('UPDATE terminal SET deleted_at = now() WHERE id = $1', [deleted]);

      const next = await pending(client, a.branchFree.id);
      await approve(client, next);
      expect(await numberOf(client, next)).toBe(3);
    });
  });

  it('o número não muda depois de atribuído', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query('UPDATE terminal SET number = 50 WHERE id = $1', [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('a API não define o número direto', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query('UPDATE terminal SET number = 50 WHERE id = $1', [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('terminal ativo não pode ficar sem número', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(`UPDATE terminal SET number = NULL WHERE id = $1`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('avisa ao atingir o limite da filial', async () => {
    await asOwner(async (client) => {
      await client.query(
        `INSERT INTO terminal (branch_id, name, profile, status, public_key, number)
         VALUES ($1, 'Último', 'cashier', 'active', 'chave-limite', 999)`,
        [a.branchFree.id],
      );
      await expect(
        client.query(
          `INSERT INTO terminal (branch_id, name, profile, status, public_key)
           VALUES ($1, 'Excedente', 'cashier', 'active', 'chave-excedente')`,
          [a.branchFree.id],
        ),
      ).rejects.toSatisfy(hasCode('FA311'));
    });
  });

  it('aprovações simultâneas na mesma filial não repetem o número', async () => {
    const setup = await ownerPool.connect();
    let ids;
    try {
      await setup.query('BEGIN');
      await setup.query(`SELECT set_config('app.user_id', $1, true)`, [b.admin.id]);
      ids = [];
      for (let i = 0; i < 4; i += 1) ids.push(await pending(setup, b.branchFree.id));
      await setup.query('COMMIT');
    } finally {
      setup.release();
    }

    await Promise.all(ids.map(async (id) => {
      const client = await appPool.connect();
      try {
        await client.query('BEGIN');
        await client.query(`SELECT set_config('app.user_id', $1, true)`, [b.admin.id]);
        await approve(client, id);
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    }));

    const { rows } = await ownerPool.query(
      'SELECT number FROM terminal WHERE id = ANY ($1) ORDER BY number',
      [ids],
    );
    expect(rows.map((row) => row.number)).toEqual([1, 2, 3, 4]);
  });

  it('aparece na consulta do aparelho, na autenticação e no painel', async () => {
    await asUser(a.admin.id, async (client) => {
      const key = 'c'.repeat(43);
      const { rows } = await client.query(
        `SELECT app.create_pairing_request($1, 'windows', 'CAIXA', '0.1.0', 'system') AS r`,
        [key],
      );
      const { requestId, code } = rows[0].r;
      const id = (await client.query('SELECT app.claim_pairing_request($1, $2) AS id', [code, a.branchFree.id])).rows[0].id;
      await approve(client, id);

      const status = await client.query('SELECT app.get_pairing_status($1, $2) AS r', [requestId, key]);
      expect(status.rows[0].r.terminalNumber).toBe(1);

      const auth = await client.query('SELECT app.terminal_auth_info($1) AS r', [id]);
      expect(auth.rows[0].r.number).toBe(1);

      const monitor = await client.query('SELECT number FROM v_terminal_monitor WHERE id = $1', [id]);
      expect(monitor.rows[0].number).toBe(1);

      const view = await client.query('SELECT number FROM v_terminal WHERE id = $1', [id]);
      expect(view.rows[0].number).toBe(1);
    });
  });
});
