import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;
let operator;
let manager;
const tag = () => randomBytes(4).toString('hex');
let clockMs = Date.now();
function uuidV7() {
  clockMs += 1;
  const bytes = randomBytes(16);
  bytes.writeUIntBE(clockMs, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();

async function committed(user, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const readAs = async (user, sql, params = []) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    return (await client.query(sql, params)).rows;
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
const asTerminal = async (sql, params = [], terminal = a.terminal1) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    return (await client.query(sql, params)).rows[0];
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
let sequence = 0;
async function push(entries, terminal = a.terminal1) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(entries.map(([kind, payload]) => {
      sequence += 1;
      return { id: uuidV7(), sequence, kind, payload };
    }))]);
    await client.query('COMMIT');
    return rows[0].r.results;
  } finally {
    client.release();
  }
}
const codes = (results) => results.map((r) => [r.status, r.code]);
const person = async (roleName, groupFixture = a) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [groupFixture.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, groupFixture.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [groupFixture.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, groupFixture.branch1.id]);
  return user;
};

const auth = (overrides = {}) => ({
  id: uuidV7(), user_id: operator.id, event: 'success', purpose: 'login', method: 'pin', authorized_by: null,
  occurred_at: iso(), ...overrides,
});
const eventRow = async (id) => (await ownerPool.query('SELECT * FROM pdv_auth_event WHERE id = $1', [id])).rows[0];
const setMode = (actor, userId, mode) =>
  committed(actor, (client) => client.query('SELECT app.set_user_auth_mode($1, $2, $3)', [userId, mode, '']));
const modeOf = async (userId) => (await ownerPool.query('SELECT pdv_auth_mode FROM user_account WHERE id = $1', [userId])).rows[0].pdv_auth_mode;
const modeEvents = async (userId) => (await ownerPool.query(
  "SELECT count(*)::int AS n FROM auth_event WHERE user_id = $1 AND event_type = 'pdv_auth_mode_set'", [userId],
)).rows[0].n;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  manager = await person('Gerente');
});
afterAll(closePools);

describe('forma de entrar no PDV', () => {
  it('padrão PIN; quem pode gerar senha muda, desce para o PDV e fica registrado; inválida ou sem permissão, não', async () => {
    const someone = await person('Operador de caixa');
    expect(await modeOf(someone.id)).toBe('pin');
    const mark = async () => (await ownerPool.query("SELECT max(xid::text::bigint) AS x FROM sync_change WHERE entity = 'user' AND entity_id = $1", [someone.id])).rows[0].x;
    const before = await mark();
    await setMode(a.admin, someone.id, 'face');
    expect(BigInt(await mark())).toBeGreaterThan(BigInt(before));
    expect(await modeOf(someone.id)).toBe('face');
    const data = (await ownerPool.query('SELECT d.data FROM app.pdv_user_data($1, ARRAY[$2]::uuid[]) d', [a.branch1.id, someone.id])).rows[0];
    expect(data.data).toMatchObject({ auth_mode: 'face' });
    expect(await modeEvents(someone.id)).toBe(1);
    // A mesma forma de novo não registra de novo.
    await setMode(a.admin, someone.id, 'face');
    expect(await modeEvents(someone.id)).toBe(1);
    for (const mode of ['any', 'fingerprint', 'pin']) {
      await setMode(a.admin, someone.id, mode);
      expect(await modeOf(someone.id)).toBe(mode);
    }
    await expect(setMode(a.admin, someone.id, 'senha')).rejects.toSatisfy(hasCode('FA819'));
    await expect(setMode(a.admin, someone.id, null)).rejects.toSatisfy(hasCode('FA819'));
    await expect(setMode(operator, someone.id, 'face')).rejects.toSatisfy(hasCode('FA002'));
    await expect(setMode(b.admin, someone.id, 'face')).rejects.toSatisfy(hasCode('FA002'));
    // Direto na tabela, nem quem pode editar o usuário muda a forma.
    await expect(committed(a.admin, (client) => client.query("UPDATE user_account SET pdv_auth_mode = 'face' WHERE id = $1", [someone.id])))
      .rejects.toSatisfy(hasCode('FA002'));
    expect(await modeOf(someone.id)).toBe('pin');
    await ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [someone.id]);
    await expect(setMode(a.admin, someone.id, 'face')).rejects.toSatisfy(hasCode('FA209'));
  });

  it('o Gerente libera a entrada; o operador, não', async () => {
    const has = async (userId) => (await ownerPool.query(
      "SELECT app.user_has_permission($1, 'users.release_login', $2) AS ok", [userId, a.branch1.id],
    )).rows[0].ok;
    expect(await has(manager.id)).toBe(true);
    expect(await has(operator.id)).toBe(false);
  });
});

describe('autenticação vinda do PDV', () => {
  it('entrada, falha, bloqueio e liberação ficam registrados; fora da forma ou liberada sem permissão vira alerta', async () => {
    const faceUser = await person('Operador de caixa');
    await setMode(a.admin, faceUser.id, 'face');
    const anyUser = await person('Operador de caixa');
    await setMode(a.admin, anyUser.id, 'any');
    const ok = auth();
    const failure = auth({ event: 'failure', purpose: 'approval' });
    const locked = auth({ event: 'locked' });
    const outside = auth({ user_id: faceUser.id });
    const faceFailure = auth({ user_id: faceUser.id, event: 'failure' });
    const anyPin = auth({ user_id: anyUser.id, purpose: 'seller' });
    const anyFace = auth({ user_id: anyUser.id, method: 'face' });
    const pinFinger = auth({ method: 'fingerprint' });
    const released = auth({ user_id: faceUser.id, method: 'manager_release', authorized_by: manager.id });
    const badRelease = auth({ user_id: faceUser.id, method: 'manager_release', authorized_by: operator.id });
    const all = [ok, failure, locked, outside, faceFailure, anyPin, anyFace, pinFinger, released, badRelease];
    expect(codes(await push(all.map((e) => ['auth_event', e]))).map(([s]) => s)).toEqual(all.map(() => 'applied'));
    const alerts = await Promise.all(all.map(async (e) => (await eventRow(e.id)).alert));
    expect(alerts).toEqual([null, null, null, 'outside_mode', null, null, null, 'outside_mode', null, 'release_permission']);
    expect(await eventRow(released.id)).toMatchObject({
      branch_id: a.branch1.id, terminal_id: a.terminal1.id, user_id: faceUser.id, authorized_by: manager.id,
      event: 'success', purpose: 'login', method: 'manager_release',
    });
    expect(await eventRow(failure.id)).toMatchObject({ event: 'failure', purpose: 'approval', method: 'pin' });
    // Ninguém altera o registro.
    await expect(ownerPool.query('UPDATE pdv_auth_event SET alert = NULL WHERE id = $1', [outside.id])).rejects.toSatisfy(hasCode('FA104'));

    // Retaguarda: por filial, por período e só as marcadas.
    const marked = await readAs(a.admin, 'SELECT * FROM app.list_pdv_auth_events($1, NULL, NULL, true)', [a.branch1.id]);
    expect(marked.map((r) => r.id).sort()).toEqual([outside.id, pinFinger.id, badRelease.id].sort());
    const row = (await readAs(a.admin, 'SELECT * FROM app.list_pdv_auth_events($1)', [a.branch1.id])).find((r) => r.id === badRelease.id);
    expect(row).toMatchObject({ user_name: faceUser.name, authorized_by_name: operator.name, method: 'manager_release', alert: 'release_permission' });
    expect((await readAs(a.admin, 'SELECT * FROM app.list_pdv_auth_events($1)', [a.branch2.id])).length).toBe(0);
    expect((await readAs(a.admin, "SELECT * FROM app.list_pdv_auth_events(NULL, (now() AT TIME ZONE 'America/Sao_Paulo')::date + 1, NULL)")).length).toBe(0);
    expect((await readAs(a.admin, "SELECT * FROM app.list_pdv_auth_events(NULL, NULL, (now() AT TIME ZONE 'America/Sao_Paulo')::date - 1)")).length).toBe(0);
    expect(await readAs(b.admin, 'SELECT * FROM app.list_pdv_auth_events()')).toEqual([]);
    // Sem "Ver usuários", não vê.
    expect(await readAs(a.oneBranchUser, 'SELECT * FROM app.list_pdv_auth_events()')).toEqual([]);
    expect(await readAs(a.oneBranchUser, 'SELECT * FROM v_pdv_auth_event')).toEqual([]);
  });

  it('fora do formato, de outro grupo ou repetida: conflito', async () => {
    const outsider = await person('Gerente', b);
    const bad = [
      auth({ event: 'ok' }), auth({ purpose: 'x' }), auth({ method: 'senha' }), auth({ authorized_by: manager.id }),
      auth({ method: 'manager_release' }), auth({ method: 'manager_release', authorized_by: manager.id, event: 'failure' }),
      auth({ method: 'manager_release', authorized_by: operator.id, user_id: operator.id }), auth({ occurred_at: 'ontem' }),
      auth({ user_id: 'nada' }), { ...auth(), id: 'nada' }, auth({ event: null }),
    ];
    expect(codes(await push(bad.map((e) => ['auth_event', e])))).toEqual(bad.map(() => ['conflict', 'FA962']));
    expect(codes(await push([
      ['auth_event', auth({ user_id: outsider.id })],
      ['auth_event', auth({ method: 'manager_release', authorized_by: outsider.id })],
    ]))).toEqual([['conflict', 'FA004'], ['conflict', 'FA004']]);
    const once = auth();
    await push([['auth_event', once]]);
    expect(codes(await push([['auth_event', once]]))).toEqual([['conflict', 'FA963']]);
    expect(codes(await push([['auth_event', auth({ occurred_at: '2026-13-45T10:00:00Z' })]]))).toEqual([['conflict', 'FA962']]);
  });
});
