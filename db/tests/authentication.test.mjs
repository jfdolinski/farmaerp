import { createHash, randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const HASH = '$argon2id$exemplo';
const IP = '203.0.113.7';
const tokenHash = () => createHash('sha256').update(randomBytes(32)).digest('hex');
const email = () => `${randomBytes(6).toString('hex')}@exemplo.com.br`;

const setEmail = (client, user, value = email()) =>
  client.query('UPDATE user_account SET email = $2 WHERE id = $1 RETURNING email', [user.id, value]);

/** Dá acesso a um usuário, como o admin faria. */
async function grantAccess(client, user, value = email()) {
  await setUser(client, a.admin.id);
  await setEmail(client, user, value);
  await client.query('SELECT app.set_temporary_password($1, $2, $3)', [user.id, HASH, IP]);
  return value;
}
const lookup = async (client, value) =>
  (await client.query('SELECT app.auth_lookup($1) AS r', [value])).rows[0].r;
const fail = (client, userId) => client.query('SELECT app.auth_login_failed($1, $2)', [userId, IP]);
const succeed = async (client, userId, hash = tokenHash()) => {
  const { rows } = await client.query('SELECT app.auth_login_succeeded($1, $2, $3) AS r', [userId, hash, IP]);
  return { hash, ...rows[0].r };
};
const validate = async (client, hash) =>
  (await client.query('SELECT app.validate_session($1) AS r', [hash])).rows[0].r;

describe('usuário', () => {
  it('recebe código sequencial por grupo econômico', async () => {
    await asOwner(async (client) => {
      const insert = async (groupId) =>
        Number((await client.query(
          `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Novo') RETURNING code`,
          [groupId],
        )).rows[0].code);
      const first = await insert(a.group.id);
      expect(await insert(a.group.id)).toBe(first + 1);
    });
  });

  it('a API não escolhe o código', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query(
        `INSERT INTO user_account (economic_group_id, name, code) VALUES ($1, 'Novo', 999999) RETURNING code`,
        [a.group.id],
      );
      expect(Number(rows[0].code)).toBeLessThan(999999);
    });
  });

  it('o código não muda', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query('UPDATE user_account SET code = 5000 WHERE id = $1', [a.noBranchUser.id]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('normaliza o e-mail', async () => {
    await asOwner(async (client) => {
      const { rows } = await setEmail(client, a.noBranchUser, '  Fulano@Exemplo.COM.br ');
      expect(rows[0].email).toBe('fulano@exemplo.com.br');
    });
  });

  it('e-mail vazio vira sem e-mail', async () => {
    await asOwner(async (client) => {
      const { rows } = await setEmail(client, a.noBranchUser, '   ');
      expect(rows[0].email).toBeNull();
    });
  });

  it('rejeita e-mail inválido', async () => {
    await asOwner(async (client) => {
      await expect(setEmail(client, a.noBranchUser, 'sem-arroba')).rejects.toSatisfy(hasCode('FA407'));
    });
  });

  it('o e-mail é único na plataforma, mesmo entre grupos', async () => {
    await asOwner(async (client) => {
      const value = email();
      await setEmail(client, a.noBranchUser, value);
      await expect(setEmail(client, b.noBranchUser, value.toUpperCase())).rejects.toSatisfy(hasCode('FA406'));
    });
  });

  it('usuário sem e-mail é permitido, como o operador de caixa', async () => {
    await asOwner(async (client) => {
      const { rowCount } = await client.query(
        `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Operador')`,
        [a.group.id],
      );
      expect(rowCount).toBe(1);
    });
  });
});

describe('último administrador', () => {
  // Grupo próprio, com um único admin.
  async function soloAdmin(client) {
    const { rows: [group] } = await client.query(`INSERT INTO economic_group (name) VALUES ('Solo') RETURNING id`);
    const { rows: [admin] } = await client.query(
      `INSERT INTO user_account (economic_group_id, name, is_group_admin) VALUES ($1, 'Admin', true) RETURNING id`,
      [group.id],
    );
    return { group, admin };
  }

  it.each([
    ['perder o papel', 'is_group_admin = false'],
    ['ser desativado', 'is_active = false'],
    ['ser excluído', 'deleted_at = now()'],
  ])('não pode %s', async (_label, change) => {
    await asOwner(async (client) => {
      const { admin } = await soloAdmin(client);
      await expect(
        client.query(`UPDATE user_account SET ${change} WHERE id = $1`, [admin.id]),
      ).rejects.toSatisfy(hasCode('FA405'));
    });
  });

  it('pode sair se existir outro administrador ativo', async () => {
    await asOwner(async (client) => {
      const { rowCount } = await client.query(
        'UPDATE user_account SET is_active = false WHERE id = $1',
        [a.secondAdmin.id],
      );
      expect(rowCount).toBe(1);
    });
  });

  it('outro administrador desativado não conta', async () => {
    await asOwner(async (client) => {
      const { group, admin } = await soloAdmin(client);
      const { rows: [second] } = await client.query(
        `INSERT INTO user_account (economic_group_id, name, is_group_admin) VALUES ($1, 'Outro', true) RETURNING id`,
        [group.id],
      );
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [second.id]);
      await expect(
        client.query('UPDATE user_account SET is_active = false WHERE id = $1', [admin.id]),
      ).rejects.toSatisfy(hasCode('FA405'));
    });
  });

  it('dois administradores saindo ao mesmo tempo não deixam o grupo sem nenhum', async () => {
    const setup = await ownerPool.connect();
    let group;
    let first;
    let second;
    try {
      ({ group, admin: first } = await soloAdmin(setup));
      ({ rows: [second] } = await setup.query(
        `INSERT INTO user_account (economic_group_id, name, is_group_admin) VALUES ($1, 'Outro', true) RETURNING id`,
        [group.id],
      ));
    } finally {
      setup.release();
    }

    const results = await Promise.allSettled([first, second].map((user) =>
      ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [user.id])));

    expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    const { rows } = await ownerPool.query(
      'SELECT count(*)::int AS total FROM user_account WHERE economic_group_id = $1 AND is_active',
      [group.id],
    );
    expect(rows[0].total).toBe(1);
  });
});

describe('credenciais', () => {
  it('a API não lê nem grava credenciais e sessões direto', async () => {
    const { rows } = await ownerPool.query(`
      SELECT has_table_privilege('farmaerp_app', 'user_credential', 'SELECT') AS read_credential,
             has_table_privilege('farmaerp_app', 'user_credential', 'UPDATE') AS write_credential,
             has_table_privilege('farmaerp_app', 'v_user_credential', 'SELECT') AS view_credential,
             has_table_privilege('farmaerp_app', 'user_session', 'SELECT') AS read_session,
             has_table_privilege('farmaerp_app', 'user_session', 'INSERT') AS write_session,
             has_table_privilege('farmaerp_app', 'auth_event', 'INSERT') AS write_event`);
    expect(Object.values(rows[0]).every((value) => value === false)).toBe(true);
  });

  it('funções internas não ficam abertas para a API', async () => {
    const { rows } = await ownerPool.query(`
      SELECT has_function_privilege('farmaerp_app', 'app.record_auth_event(uuid, text, text)', 'EXECUTE') AS record,
             has_function_privilege('farmaerp_app', 'app.revoke_sessions_of(uuid, text)', 'EXECUTE') AS revoke`);
    expect(rows[0]).toEqual({ record: false, revoke: false });
  });

  it('usuário comum não define senha de outro', async () => {
    await asUser(a.oneBranchUser.id, async (client) => {
      await expect(
        client.query('SELECT app.set_temporary_password($1, $2, $3)', [a.noBranchUser.id, HASH, IP]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('admin não define senha em outro grupo econômico', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query('SELECT app.set_temporary_password($1, $2, $3)', [b.noBranchUser.id, HASH, IP]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('exige e-mail para dar acesso', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query('SELECT app.set_temporary_password($1, $2, $3)', [a.noBranchUser.id, HASH, IP]),
      ).rejects.toSatisfy(hasCode('FA408'));
    });
  });

  it('não dá acesso a usuário desativado', async () => {
    await asUser(a.admin.id, async (client) => {
      await setEmail(client, a.noBranchUser);
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.noBranchUser.id]);
      await expect(
        client.query('SELECT app.set_temporary_password($1, $2, $3)', [a.noBranchUser.id, HASH, IP]),
      ).rejects.toSatisfy(hasCode('FA209'));
    });
  });

  it('senha temporária exige troca no primeiro acesso', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      expect((await succeed(client, a.noBranchUser.id)).mustChangePassword).toBe(true);
    });
  });

  it('o admin vê quem tem acesso, sem ver a senha', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      const { rows } = await client.query('SELECT app.user_ids_with_access() AS ids');
      expect(rows[0].ids).toContain(a.noBranchUser.id);
      expect(JSON.stringify(rows[0])).not.toContain(HASH);
    });
  });
});

describe('consulta para login', () => {
  it('não acusa e-mail desconhecido nem usuário sem acesso', async () => {
    await asUser(a.admin.id, async (client) => {
      expect(await lookup(client, 'ninguem@exemplo.com.br')).toBeNull();
      const value = email();
      await setEmail(client, a.noBranchUser, value);
      expect(await lookup(client, value)).toBeNull();
    });
  });

  it('encontra sem diferenciar maiúsculas', async () => {
    await asUser(a.admin.id, async (client) => {
      const value = await grantAccess(client, a.noBranchUser);
      expect(await lookup(client, ` ${value.toUpperCase()} `)).toMatchObject({
        userId: a.noBranchUser.id, passwordHash: HASH, locked: false,
      });
    });
  });

  it('usuário desativado não entra', async () => {
    await asUser(a.admin.id, async (client) => {
      const value = await grantAccess(client, a.noBranchUser);
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.noBranchUser.id]);
      expect(await lookup(client, value)).toBeNull();
    });
  });
});

describe('tentativas', () => {
  it('bloqueia na quinta falha seguida', async () => {
    await asUser(a.admin.id, async (client) => {
      const value = await grantAccess(client, a.noBranchUser);
      for (let i = 0; i < 4; i += 1) await fail(client, a.noBranchUser.id);
      expect((await lookup(client, value)).locked).toBe(false);
      await fail(client, a.noBranchUser.id);
      expect((await lookup(client, value)).locked).toBe(true);
    });
  });

  it('um login certo zera as falhas', async () => {
    await asUser(a.admin.id, async (client) => {
      const value = await grantAccess(client, a.noBranchUser);
      for (let i = 0; i < 4; i += 1) await fail(client, a.noBranchUser.id);
      await succeed(client, a.noBranchUser.id);
      for (let i = 0; i < 4; i += 1) await fail(client, a.noBranchUser.id);
      expect((await lookup(client, value)).locked).toBe(false);
    });
  });

  it('o bloqueio termina depois de 15 minutos', async () => {
    await asOwner(async (client) => {
      const value = email();
      await setEmail(client, a.noBranchUser, value);
      await client.query(
        `INSERT INTO user_credential (user_id, password_hash, locked_until) VALUES ($1, $2, now() - interval '1 second')`,
        [a.noBranchUser.id, HASH],
      );
      expect((await lookup(client, value)).locked).toBe(false);
    });
  });

  it('falhas durante o bloqueio não o prolongam e ficam registradas', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      for (let i = 0; i < 6; i += 1) await fail(client, a.noBranchUser.id);
      const { rows } = await client.query(
        `SELECT event_type, count(*)::int AS total FROM auth_event
          WHERE user_id = $1 AND event_type LIKE 'login_%' GROUP BY event_type`,
        [a.noBranchUser.id],
      );
      const totals = Object.fromEntries(rows.map((row) => [row.event_type, row.total]));
      expect(totals).toEqual({ login_failure: 5, login_locked: 1 });
    });
  });

  it('e-mail desconhecido gera evento sem usuário', async () => {
    await asOwner(async (client) => {
      await fail(client, null);
      const { rows } = await client.query(
        `SELECT user_id, event_type FROM auth_event ORDER BY created_at DESC, id DESC LIMIT 1`,
      );
      expect(rows[0]).toEqual({ user_id: null, event_type: 'login_failure' });
    });
  });
});

describe('sessão', () => {
  const session = async (client) => {
    await grantAccess(client, a.noBranchUser);
    return succeed(client, a.noBranchUser.id);
  };

  it('retorna os dados do usuário', async () => {
    await asUser(a.admin.id, async (client) => {
      const { hash } = await session(client);
      expect(await validate(client, hash)).toMatchObject({
        userId: a.noBranchUser.id, isAdmin: false, mustChangePassword: true,
      });
    });
  });

  it('token desconhecido não vale', async () => {
    await asUser(null, async (client) => {
      expect(await validate(client, tokenHash())).toBeNull();
    });
  });

  it('expira depois de 8 horas sem uso', async () => {
    await asOwner(async (client) => {
      const hash = tokenHash();
      await client.query(
        `INSERT INTO user_session (user_id, token_hash, last_seen_at) VALUES ($1, $2, now() - interval '8 hours 1 minute')`,
        [a.noBranchUser.id, hash],
      );
      expect(await validate(client, hash)).toBeNull();
    });
  });

  it('expira depois de 12 horas, mesmo em uso', async () => {
    await asOwner(async (client) => {
      const hash = tokenHash();
      await client.query(
        `INSERT INTO user_session (user_id, token_hash, created_at) VALUES ($1, $2, now() - interval '12 hours 1 minute')`,
        [a.noBranchUser.id, hash],
      );
      expect(await validate(client, hash)).toBeNull();
    });
  });

  it('renova o último uso no máximo uma vez por minuto', async () => {
    await asOwner(async (client) => {
      const hash = tokenHash();
      await client.query(
        `INSERT INTO user_session (user_id, token_hash, last_seen_at) VALUES ($1, $2, now() - interval '30 minutes')`,
        [a.noBranchUser.id, hash],
      );
      await validate(client, hash);
      const version = async () =>
        (await client.query('SELECT version FROM user_session WHERE token_hash = $1', [hash])).rows[0].version;
      expect(await version()).toBe('2');
      await validate(client, hash);
      expect(await version()).toBe('2');
    });
  });

  it('sair encerra a sessão', async () => {
    await asUser(a.admin.id, async (client) => {
      const { hash } = await session(client);
      await client.query('SELECT app.end_session($1, $2)', [hash, IP]);
      expect(await validate(client, hash)).toBeNull();
    });
  });

  it.each([
    ['desativar', 'is_active = false'],
    ['trocar o e-mail', `email = 'outro.email@exemplo.com.br'`],
  ])('%s encerra as sessões na hora', async (_label, change) => {
    await asUser(a.admin.id, async (client) => {
      const { hash } = await session(client);
      await client.query(`UPDATE user_account SET ${change} WHERE id = $1`, [a.noBranchUser.id]);
      expect(await validate(client, hash)).toBeNull();
    });
  });

  it('excluir encerra as sessões na hora', async () => {
    await asOwner(async (client) => {
      const hash = tokenHash();
      await client.query('INSERT INTO user_session (user_id, token_hash) VALUES ($1, $2)', [a.noBranchUser.id, hash]);
      await client.query('UPDATE user_account SET deleted_at = now() WHERE id = $1', [a.noBranchUser.id]);
      expect(await validate(client, hash)).toBeNull();
    });
  });

  it('usuário desativado perde o acesso às filiais', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.oneBranchUser.id]);
      await setUser(client, a.oneBranchUser.id);
      expect((await client.query('SELECT * FROM branch')).rows).toEqual([]);
    });
  });

  it('administrador desativado perde o papel na hora', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.secondAdmin.id]);
      await setUser(client, a.secondAdmin.id);
      const { rows } = await client.query('SELECT app.admin_economic_group_id() AS id');
      expect(rows[0].id).toBeNull();
    });
  });

  it('a senha temporária encerra as sessões', async () => {
    await asUser(a.admin.id, async (client) => {
      const { hash } = await session(client);
      await client.query('SELECT app.set_temporary_password($1, $2, $3)', [a.noBranchUser.id, HASH, IP]);
      expect(await validate(client, hash)).toBeNull();
    });
  });

  it('trocar a própria senha mantém a sessão atual e encerra as outras', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      const current = await succeed(client, a.noBranchUser.id);
      const other = await succeed(client, a.noBranchUser.id);

      await setUser(client, a.noBranchUser.id);
      await client.query('SELECT app.change_own_password($1, $2, $3)', ['$argon2id$nova', current.hash, IP]);

      expect(await validate(client, current.hash)).toMatchObject({ mustChangePassword: false });
      expect(await validate(client, other.hash)).toBeNull();

      const { rows } = await client.query('SELECT app.current_password_hash() AS h');
      expect(rows[0].h).toBe('$argon2id$nova');
    });
  });

  it('sem usuário não troca senha', async () => {
    await asUser(null, async (client) => {
      await expect(
        client.query('SELECT app.change_own_password($1, $2, $3)', [HASH, tokenHash(), IP]),
      ).rejects.toSatisfy(hasCode('FA402'));
    });
  });

  it('o hash do token precisa ter o formato certo', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      await expect(succeed(client, a.noBranchUser.id, 'token-puro')).rejects.toSatisfy(hasCode('FA410'));
    });
  });
});

describe('histórico', () => {
  const events = async (client, userId) =>
    (await client.query(
      'SELECT event_type, host(ip_address) AS ip FROM auth_event WHERE user_id = $1 ORDER BY created_at, id',
      [userId],
    )).rows;

  it('registra o ciclo completo com o IP', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      await fail(client, a.noBranchUser.id);
      const { hash } = await succeed(client, a.noBranchUser.id);
      await client.query('SELECT app.end_session($1, $2)', [hash, IP]);

      expect(await events(client, a.noBranchUser.id)).toEqual(
        ['password_reset', 'login_failure', 'login_success', 'logout'].map((event_type) => ({ event_type, ip: IP })),
      );
    });
  });

  it('não pode ser alterado nem apagado', async () => {
    await asOwner(async (client) => {
      const { rows: [event] } = await client.query(
        `INSERT INTO auth_event (user_id, event_type, ip_address) VALUES ($1, 'logout', $2) RETURNING id`,
        [a.admin.id, IP],
      );
      await client.query('SAVEPOINT s');
      await expect(
        client.query(`UPDATE auth_event SET event_type = 'login_success' WHERE id = $1`, [event.id]),
      ).rejects.toSatisfy(hasCode('FA107'));
      await client.query('ROLLBACK TO SAVEPOINT s');
      await expect(
        client.query(`UPDATE auth_event SET ip_address = '198.51.100.1' WHERE id = $1`, [event.id]),
      ).rejects.toSatisfy(hasCode('FA107'));
      await client.query('ROLLBACK TO SAVEPOINT s');
      await expect(client.query('DELETE FROM auth_event')).rejects.toSatisfy(hasCode('FA103'));
    });
  });

  it('o IP é apagado depois de 90 dias, e o evento fica', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
    });
    await asOwner(async (client) => {
      const insert = async (age) =>
        (await client.query(
          `INSERT INTO auth_event (user_id, event_type, ip_address, created_at)
           VALUES ($1, 'logout', $2, now() - $3::interval) RETURNING id`,
          [a.admin.id, IP, age],
        )).rows[0].id;
      const old = await insert('91 days');
      const recent = await insert('89 days');
      await client.query(
        `INSERT INTO user_credential (user_id, password_hash) VALUES ($1, $2)
         ON CONFLICT (user_id) WHERE deleted_at IS NULL DO NOTHING`,
        [a.admin.id, HASH],
      );
      await succeed(client, a.admin.id);

      const ipOf = async (id) =>
        (await client.query('SELECT host(ip_address) AS ip FROM auth_event WHERE id = $1', [id])).rows[0];
      expect(await ipOf(old)).toEqual({ ip: null });
      expect(await ipOf(recent)).toEqual({ ip: IP });
    });
  });

  it('o admin lê o histórico só do próprio grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await grantAccess(client, a.noBranchUser);
      expect(await events(client, a.noBranchUser.id)).toHaveLength(1);
      await setUser(client, b.admin.id);
      expect(await events(client, a.noBranchUser.id)).toEqual([]);
      await setUser(client, a.oneBranchUser.id);
      expect(await events(client, a.noBranchUser.id)).toEqual([]);
    });
  });

  it('a API não grava no histórico direto', async () => {
    const client = await appPool.connect();
    try {
      await expect(
        client.query(`INSERT INTO auth_event (event_type) VALUES ('logout')`),
      ).rejects.toSatisfy(hasCode('FA002'));
    } finally {
      client.release();
    }
  });
});
