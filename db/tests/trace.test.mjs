import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, asOwner, asUser, closePools, createFixtures, setTrace } from './helpers.mjs';

const TRACE_1 = '019a0000-0000-7000-8000-0000000000a1';
const TRACE_2 = '019a0000-0000-7000-8000-0000000000a2';

let a;

beforeAll(async () => {
  ({ a } = await createFixtures());
});
afterAll(closePools);

describe('trace_id na auditoria', () => {
  it('é gravado na inclusão', async () => {
    await asUser(a.admin.id, async (client) => {
      await setTrace(client, TRACE_1);
      const { rows } = await client.query(
        `INSERT INTO region (branch_group_id, name) VALUES ($1, 'Com rastreio') RETURNING trace_id`,
        [a.branchGroup.id],
      );
      expect(rows[0].trace_id).toBe(TRACE_1);
    });
  });

  it('guarda o ID da última alteração', async () => {
    await asUser(a.admin.id, async (client) => {
      await setTrace(client, TRACE_1);
      await client.query(`UPDATE region SET name = 'Primeira' WHERE id = $1`, [a.region.id]);
      await setTrace(client, TRACE_2);
      const { rows } = await client.query(
        `UPDATE region SET name = 'Segunda' WHERE id = $1 RETURNING trace_id`,
        [a.region.id],
      );
      expect(rows[0].trace_id).toBe(TRACE_2);
    });
  });

  it('ignora o valor enviado pelo cliente', async () => {
    await asUser(a.admin.id, async (client) => {
      await setTrace(client, TRACE_1);
      const { rows } = await client.query(
        'UPDATE region SET trace_id = $2 WHERE id = $1 RETURNING trace_id',
        [a.region.id, TRACE_2],
      );
      expect(rows[0].trace_id).toBe(TRACE_1);
    });
  });

  it('fica nulo em alterações sem rastreio, como migrations e seeds', async () => {
    await asOwner(async (client) => {
      const { rows } = await client.query(
        `UPDATE region SET name = 'Sem rastreio' WHERE id = $1 RETURNING trace_id`,
        [a.region.id],
      );
      expect(rows[0].trace_id).toBeNull();
    });
  });

  it('aparece nas views', async () => {
    await asUser(a.admin.id, async (client) => {
      await setTrace(client, TRACE_1);
      await client.query(`UPDATE region SET name = 'Na view' WHERE id = $1`, [a.region.id]);
      const { rows } = await client.query('SELECT trace_id FROM v_region WHERE id = $1', [a.region.id]);
      expect(rows[0].trace_id).toBe(TRACE_1);
    });
  });

  it('rejeita um ID malformado', async () => {
    await asUser(a.admin.id, async (client) => {
      await setTrace(client, 'nao-e-um-uuid');
      await expect(
        client.query(`UPDATE region SET name = 'Inválido' WHERE id = $1`, [a.region.id]),
      ).rejects.toMatchObject({ code: '22P02' });
    });
  });

  it('não vaza para a transação seguinte na mesma conexão', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setTrace(client, TRACE_1);
      await client.query('COMMIT');

      const { rows } = await client.query('SELECT app.current_trace_id() AS trace_id');
      expect(rows[0].trace_id).toBeNull();
    } finally {
      client.release();
    }
  });
});
