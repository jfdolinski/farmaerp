import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, closePools, createFixtures, hasCode, setTerminal, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const newPublicKey = () => randomBytes(32).toString('base64url');

async function createRequest(client, publicKey = newPublicKey(), storage = 'system') {
  const { rows } = await client.query(
    `SELECT app.create_pairing_request($1, 'windows', 'CAIXA-01', '0.1.0', $2) AS result`,
    [publicKey, storage],
  );
  return { publicKey, ...rows[0].result };
}

async function claim(client, code, branchId) {
  const { rows } = await client.query(
    'SELECT app.claim_pairing_request($1, $2) AS id',
    [code, branchId],
  );
  return rows[0].id;
}

/** Cria um terminal pendente, como o admin faria. */
async function pendingTerminal(client, branchId) {
  const request = await createRequest(client);
  return { request, id: await claim(client, request.code, branchId) };
}

const approve = (client, id, name = 'Caixa novo', profile = 'cashier') =>
  client.query('SELECT app.approve_terminal($1, $2, $3)', [id, name, profile]);
const setStatus = (client, id, status, reason = 'Motivo do teste') =>
  client.query('SELECT app.set_terminal_status($1, $2, $3)', [id, status, reason]);
const terminalRow = async (client, id) =>
  (await client.query('SELECT * FROM terminal WHERE id = $1', [id])).rows[0];

describe('solicitação de pareamento', () => {
  it('funciona sem usuário logado e gera código sem símbolos parecidos', async () => {
    await asUser(null, async (client) => {
      const request = await createRequest(client);
      expect(request.code).toMatch(/^[A-HJ-NP-Z2-9]{8}$/);
      expect(new Date(request.expiresAt).getTime()).toBeGreaterThan(Date.now() + 14 * 60_000);
    });
  });

  it('a mesma chave reaproveita o código ainda válido', async () => {
    await asUser(null, async (client) => {
      const first = await createRequest(client);
      const second = await createRequest(client, first.publicKey);
      expect(second.code).toBe(first.code);
      expect(second.requestId).toBe(first.requestId);
    });
  });

  it('códigos sorteados variam', async () => {
    await asUser(null, async (client) => {
      const codes = new Set();
      for (let i = 0; i < 50; i += 1) {
        codes.add((await createRequest(client)).code);
      }
      expect(codes.size).toBe(50);
    });
  });

  it('rejeita uma chave em formato inválido', async () => {
    await asUser(null, async (client) => {
      await expect(createRequest(client, 'chave-curta')).rejects.toSatisfy(hasCode('FA310'));
    });
  });

  it('rejeita a chave de um terminal já cadastrado', async () => {
    await asUser(a.admin.id, async (client) => {
      const { request } = await pendingTerminal(client, a.branch1.id);
      await expect(createRequest(client, request.publicKey)).rejects.toSatisfy(hasCode('FA220'));
    });
  });

  it('a API não lê solicitações pendentes de outros aparelhos', async () => {
    await asUser(a.admin.id, async (client) => {
      const request = await createRequest(client);
      const { rows } = await client.query(
        'SELECT 1 FROM terminal_pairing_request WHERE id = $1',
        [request.requestId],
      );
      expect(rows).toEqual([]);
    });
  });
});

describe('consulta pelo aparelho', () => {
  it('informa a espera e, depois, a situação do terminal', async () => {
    await asUser(a.admin.id, async (client) => {
      const request = await createRequest(client);
      const status = async () =>
        (await client.query('SELECT app.get_pairing_status($1, $2) AS r', [
          request.requestId, request.publicKey,
        ])).rows[0].r;

      expect(await status()).toMatchObject({ status: 'waiting', terminalId: null });

      const id = await claim(client, request.code, a.branch1.id);
      expect(await status()).toMatchObject({ status: 'claimed', terminalId: id, terminalStatus: 'pending' });

      await approve(client, id);
      expect(await status()).toMatchObject({ terminalStatus: 'active' });
    });
  });

  it('exige a chave da solicitação', async () => {
    await asUser(null, async (client) => {
      const request = await createRequest(client);
      await expect(
        client.query('SELECT app.get_pairing_status($1, $2)', [request.requestId, newPublicKey()]),
      ).rejects.toSatisfy(hasCode('FA301'));
    });
  });

  it('código vencido aparece como expirado e pode ser renovado', async () => {
    const request = await asOwnerExpired();
    await asUser(null, async (client) => {
      const { rows } = await client.query('SELECT app.get_pairing_status($1, $2) AS r', [
        request.requestId, request.publicKey,
      ]);
      expect(rows[0].r.status).toBe('expired');

      const renewed = await createRequest(client, request.publicKey);
      expect(renewed.requestId).not.toBe(request.requestId);
    });
  });
});

// Confirma uma solicitação vencida, porque o vencimento depende de outra transação.
async function asOwnerExpired() {
  const client = await appPool.connect();
  let request;
  try {
    await client.query('BEGIN');
    request = await createRequest(client);
    await client.query('COMMIT');
  } finally {
    client.release();
  }
  const { ownerPool } = await import('./helpers.mjs');
  await ownerPool.query(
    `UPDATE terminal_pairing_request SET expires_at = now() - interval '1 minute' WHERE id = $1`,
    [request.requestId],
  );
  return request;
}

describe('aceite do código pelo admin', () => {
  it('mostra o aparelho e aceita o código digitado com hífen e minúsculas', async () => {
    await asUser(a.admin.id, async (client) => {
      const request = await createRequest(client, undefined, 'file');
      const typed = `${request.code.slice(0, 4)}-${request.code.slice(4)}`.toLowerCase();

      const { rows } = await client.query('SELECT app.find_pairing_request($1) AS r', [typed]);
      expect(rows[0].r).toMatchObject({
        platform: 'windows', deviceName: 'CAIXA-01', appVersion: '0.1.0', keyStorage: 'file',
      });

      const id = await claim(client, typed, a.branch1.id);
      expect(await terminalRow(client, id)).toMatchObject({
        status: 'pending', branch_id: a.branch1.id, public_key: request.publicKey, updated_by: a.admin.id,
      });
    });
  });

  it('o código só pode ser usado uma vez', async () => {
    await asUser(a.admin.id, async (client) => {
      const request = await createRequest(client);
      await claim(client, request.code, a.branch1.id);
      await expect(claim(client, request.code, a.branch1.id)).rejects.toSatisfy(hasCode('FA301'));
    });
  });

  it('rejeita código inexistente', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(claim(client, 'AAAAAAAA', a.branch1.id)).rejects.toSatisfy(hasCode('FA301'));
    });
  });

  it('rejeita código vencido', async () => {
    const request = await asOwnerExpired();
    await asUser(a.admin.id, async (client) => {
      await expect(claim(client, request.code, a.branch1.id)).rejects.toSatisfy(hasCode('FA301'));
    });
  });

  it('usuário comum não consulta nem aceita código', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      const request = await createRequest(client);
      await expect(
        client.query('SELECT app.find_pairing_request($1)', [request.code]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
    await asUser(a.oneBranchUser.id, async (client) => {
      const request = await createRequest(client);
      await expect(claim(client, request.code, a.branch1.id)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('sem usuário não aceita código', async () => {
    await asUser(null, async (client) => {
      const request = await createRequest(client);
      await expect(claim(client, request.code, a.branch1.id)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('admin não usa filial de outro grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      const request = await createRequest(client);
      await expect(claim(client, request.code, b.branch1.id)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('rejeita filial excluída', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE branch SET deleted_at = now() WHERE id = $1', [a.branchFree.id]);
      const request = await createRequest(client);
      await expect(claim(client, request.code, a.branchFree.id)).rejects.toSatisfy(hasCode('FA208'));
    });
  });
});

describe('aprovação', () => {
  it('define nome e perfil e ativa o terminal', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await approve(client, id, '  Caixa 9  ', 'self_service');
      expect(await terminalRow(client, id)).toMatchObject({
        status: 'active', name: 'Caixa 9', profile: 'self_service',
      });
    });
  });

  it.each([
    ['nome vazio', '   ', 'cashier', 'FA216'],
    ['sem nome', null, 'cashier', 'FA217'],
    ['sem perfil', 'Caixa 8', null, 'FA217'],
    ['perfil desconhecido', 'Caixa 8', 'gerente', 'FA218'],
  ])('rejeita %s', async (_label, name, profile, code) => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await expect(approve(client, id, name, profile)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('rejeita nome repetido na mesma filial', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await expect(approve(client, id, a.terminal1.name)).rejects.toSatisfy(hasCode('FA215'));
    });
  });

  it('não aprova duas vezes', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await approve(client, id);
      await expect(approve(client, id, 'Outro nome')).rejects.toSatisfy(hasCode('FA303'));
    });
  });

  it('usuário comum e admin de outro grupo não aprovam', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await setUser(client, a.oneBranchUser.id);
      await expect(approve(client, id)).rejects.toSatisfy(hasCode('FA002'));
    });
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await setUser(client, b.admin.id);
      await expect(approve(client, id)).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('situação do terminal', () => {
  const active = async (client) => {
    const { id } = await pendingTerminal(client, a.branch1.id);
    await approve(client, id);
    return id;
  };

  it('bloqueia, desbloqueia e revoga', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await active(client);
      await setStatus(client, id, 'blocked');
      expect((await terminalRow(client, id)).status).toBe('blocked');
      await setStatus(client, id, 'active', null);
      expect((await terminalRow(client, id)).status).toBe('active');
      await setStatus(client, id, 'revoked');
      expect((await terminalRow(client, id)).status).toBe('revoked');
    });
  });

  it('recusa um terminal pendente com revogação', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await setStatus(client, id, 'revoked', 'Aparelho desconhecido');
      expect((await terminalRow(client, id)).status).toBe('revoked');
    });
  });

  it.each(['blocked', 'revoked'])('exige motivo para %s', async (status) => {
    await asUser(a.admin.id, async (client) => {
      const id = await active(client);
      await expect(setStatus(client, id, status, '  ')).rejects.toSatisfy(hasCode('FA302'));
    });
  });

  it.each([
    ['pendente para bloqueado', 'pending', 'blocked'],
    ['pendente para ativo sem aprovação', 'pending', 'active'],
    ['ativo para ativo', 'active', 'active'],
    ['ativo para pendente', 'active', 'pending'],
    ['revogado para ativo', 'revoked', 'active'],
    ['revogado para bloqueado', 'revoked', 'blocked'],
    ['revogado para revogado', 'revoked', 'revoked'],
  ])('rejeita %s', async (_label, from, to) => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      if (from !== 'pending') await approve(client, id);
      if (from === 'revoked') await setStatus(client, id, 'revoked');
      await expect(setStatus(client, id, to)).rejects.toSatisfy(hasCode('FA303'));
    });
  });

  it('o trigger barra a transição mesmo para o dono das tabelas', async () => {
    await asOwner(async (client) => {
      await client.query(`UPDATE terminal SET status = 'revoked' WHERE id = $1`, [a.terminal1.id]);
      await expect(
        client.query(`UPDATE terminal SET status = 'active' WHERE id = $1`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA303'));
    });
  });

  it('a API não muda a situação direto na tabela', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(`UPDATE terminal SET status = 'blocked' WHERE id = $1`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('a API não cria terminal já ativo direto na tabela', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(
          `INSERT INTO terminal (branch_id, name, profile, public_key, status)
           VALUES ($1, 'Burlado', 'cashier', 'chave-burlada', 'active')`,
          [a.branch1.id],
        ),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it.each([
    ['public_key', () => 'outra-chave'],
    ['branch_id', () => a.branch2.id],
  ])('%s não muda depois do cadastro', async (column, value) => {
    await asOwner(async (client) => {
      await expect(
        client.query(`UPDATE terminal SET ${column} = $2 WHERE id = $1`, [a.terminal1.id, value()]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('usuário comum não bloqueia', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      await expect(setStatus(client, a.terminal1.id, 'blocked')).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('admin de outro grupo não bloqueia', async () => {
    await asUser(b.admin.id, async (client) => {
      await expect(setStatus(client, a.terminal1.id, 'blocked')).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('histórico', () => {
  const eventsOf = async (client, id) =>
    (await client.query(
      `SELECT event_type, from_status, to_status, reason, updated_by
         FROM terminal_event WHERE terminal_id = $1 ORDER BY created_at, id`,
      [id],
    )).rows;

  it('registra cada mudança com o motivo e o autor', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      await approve(client, id);
      await setStatus(client, id, 'blocked', 'Suspeita de fraude');
      await setStatus(client, id, 'active', null);
      await setStatus(client, id, 'revoked', 'Aparelho roubado');

      const events = await eventsOf(client, id);
      expect(events.map((event) => [event.event_type, event.reason])).toEqual([
        ['requested', null],
        ['approved', null],
        ['blocked', 'Suspeita de fraude'],
        ['unblocked', null],
        ['revoked', 'Aparelho roubado'],
      ]);
      expect(events.every((event) => event.updated_by === a.admin.id)).toBe(true);
    });
  });

  it('o motivo não vaza para a mudança seguinte', async () => {
    await asOwner(async (client) => {
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      await setStatus(client, a.terminal1.id, 'blocked', 'Primeiro motivo');
      await client.query(`UPDATE terminal SET status = 'active' WHERE id = $1`, [a.terminal1.id]);
      const events = await eventsOf(client, a.terminal1.id);
      expect(events.at(-1)).toMatchObject({ event_type: 'unblocked', reason: null });
    });
  });

  it('não pode ser alterado nem apagado, nem pelo dono das tabelas', async () => {
    await asOwner(async (client) => {
      await client.query(`UPDATE terminal SET status = 'blocked' WHERE id = $1`, [a.terminal1.id]);
      await client.query('SAVEPOINT s');
      await expect(
        client.query(`UPDATE terminal_event SET reason = 'Alterado' WHERE terminal_id = $1`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA107'));
      await client.query('ROLLBACK TO SAVEPOINT s');
      await expect(client.query('DELETE FROM terminal_event')).rejects.toSatisfy(hasCode('FA103'));
    });
  });

  it('a API não grava direto no histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(
          `INSERT INTO terminal_event (terminal_id, event_type, to_status) VALUES ($1, 'approved', 'active')`,
          [a.terminal1.id],
        ),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('cada usuário só lê o histórico dos terminais que enxerga', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch2.id);
      expect(await eventsOf(client, id)).toHaveLength(1);

      await setUser(client, a.oneBranchUser.id);
      expect(await eventsOf(client, id)).toEqual([]);

      await setUser(client, b.admin.id);
      expect(await eventsOf(client, id)).toEqual([]);
    });
  });
});

describe('sinal de vida e monitoramento', () => {
  const heartbeat = (client, version = '0.1.0', sync = null, pending = null) =>
    client.query('SELECT app.record_terminal_heartbeat($1, $2, $3)', [version, sync, pending]);

  it('exige o terminal autenticado na transação', async () => {
    await asUser(null, async (client) => {
      await expect(heartbeat(client)).rejects.toSatisfy(hasCode('FA306'));
    });
  });

  it('mantém uma linha por terminal e não altera a tabela terminal', async () => {
    await asUser(a.admin.id, async (client) => {
      const before = await terminalRow(client, a.terminal1.id);
      await setTerminal(client, a.terminal1.id);
      await heartbeat(client, '0.1.0');
      await heartbeat(client, '0.2.0', '2026-11-04T12:00:00Z', 3);
      await setTerminal(client, null);

      const { rows } = await client.query(
        'SELECT * FROM terminal_status WHERE terminal_id = $1',
        [a.terminal1.id],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ app_version: '0.2.0', outbox_pending: 3, version: '2' });

      const after = await terminalRow(client, a.terminal1.id);
      expect(after.version).toBe(before.version);
    });
  });

  it('rejeita pendências negativas', async () => {
    await asUser(null, async (client) => {
      await setTerminal(client, a.terminal1.id);
      await expect(heartbeat(client, '0.1.0', null, -1)).rejects.toSatisfy(hasCode('FA310'));
    });
  });

  it('o terminal autenticado não enxerga outros terminais', async () => {
    await asUser(null, async (client) => {
      await setTerminal(client, a.terminal1.id);
      await heartbeat(client);
      for (const table of ['terminal', 'terminal_status', 'terminal_event', 'v_terminal_monitor']) {
        const { rows } = await client.query(`SELECT * FROM ${table}`);
        expect(rows, table).toEqual([]);
      }
    });
  });

  it('o painel mostra online com sinal recente e offline após 3 minutos', async () => {
    await asOwner(async (client) => {
      await client.query(
        `INSERT INTO terminal_status (terminal_id, last_seen_at, app_version) VALUES
           ($1, now() - interval '2 minutes', '0.1.0'),
           ($2, now() - interval '4 minutes', '0.1.0')`,
        [a.terminal1.id, a.terminal2.id],
      );
      const { rows } = await client.query(
        'SELECT id, connectivity, branch_name FROM v_terminal_monitor WHERE id = ANY ($1)',
        [[a.terminal1.id, a.terminal2.id]],
      );
      const byId = Object.fromEntries(rows.map((row) => [row.id, row]));
      expect(byId[a.terminal1.id].connectivity).toBe('online');
      expect(byId[a.terminal2.id].connectivity).toBe('offline');
      expect(byId[a.terminal1.id].branch_name).toBe(a.branch1.name);
    });
  });

  it('terminal sem nenhum sinal aparece como offline', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await pendingTerminal(client, a.branch1.id);
      const { rows } = await client.query(
        'SELECT connectivity, platform, device_name FROM v_terminal_monitor WHERE id = $1',
        [id],
      );
      expect(rows[0]).toEqual({ connectivity: 'offline', platform: 'windows', device_name: 'CAIXA-01' });
    });
  });

  it('o painel respeita a RLS', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM v_terminal_monitor');
      expect(rows.map((row) => row.id)).toEqual([a.terminal1.id]);
    });
    await asUser(b.admin.id, async (client) => {
      const { rows } = await client.query('SELECT 1 FROM v_terminal_monitor WHERE id = $1', [a.terminal1.id]);
      expect(rows).toEqual([]);
    });
  });
});

describe('dados de autenticação', () => {
  it('retorna a chave e a situação, e nulo para terminal inexistente', async () => {
    await asUser(null, async (client) => {
      const { rows } = await client.query('SELECT app.terminal_auth_info($1) AS info', [a.terminal1.id]);
      expect(rows[0].info).toEqual({ publicKey: a.terminal1.public_key, status: 'active', number: 1 });

      const { rows: missing } = await client.query('SELECT app.terminal_auth_info($1) AS info', [
        '019a0000-0000-7000-8000-00000000dead',
      ]);
      expect(missing[0].info).toBeNull();
    });
  });

  it('terminal excluído não é encontrado', async () => {
    await asOwner(async (client) => {
      await client.query('UPDATE terminal SET deleted_at = now() WHERE id = $1', [a.terminal1.id]);
      const { rows } = await client.query('SELECT app.terminal_auth_info($1) AS info', [a.terminal1.id]);
      expect(rows[0].info).toBeNull();
    });
  });
});
