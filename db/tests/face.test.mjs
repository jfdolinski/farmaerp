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

// Código de rosto de teste: 128 float32 (512 bytes), nada de rosto de verdade.
const fakeTemplate = (seed = 1) => {
  const buffer = Buffer.alloc(512);
  for (let i = 0; i < 128; i += 1) buffer.writeFloatLE(Math.sin(seed * 7 + i) / 11.3, i * 4);
  return buffer.toString('base64');
};
const enrollment = (userId, overrides = {}) => ({
  id: uuidV7(), user_id: userId, enrolled_by: manager.id, enrolled_at: iso(), model: 'sface-2021dec-int8',
  template: fakeTemplate(), consent: { id: uuidV7(), term_version: 'biometria-v1', consented_at: iso() }, ...overrides,
});
const faceOf = async (userId) => (await ownerPool.query('SELECT d.data -> \'face\' AS face FROM app.pdv_user_data($1, ARRAY[$2]::uuid[]) d', [a.branch1.id, userId])).rows[0].face;
const templates = async (userId) => (await ownerPool.query('SELECT * FROM face_template WHERE user_id = $1 ORDER BY created_at, id', [userId])).rows;
const consents = async (userId) => (await ownerPool.query('SELECT * FROM biometric_consent WHERE user_id = $1 ORDER BY created_at, id', [userId])).rows;
const revoke = (actor, userId) => committed(actor, (client) => client.query('SELECT app.revoke_face($1, $2)', [userId, '']));

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  manager = await person('Gerente');
});
afterAll(closePools);

describe('rosto do funcionário', () => {
  it('cadastro vindo do PDV: consentimento, só o código do rosto, desce para o PDV; o novo substitui o antigo', async () => {
    const someone = await person('Operador de caixa');
    const first = enrollment(someone.id);
    expect(codes(await push([['face_enrollment', first]]))).toEqual([['applied', null]]);
    const [stored] = await templates(someone.id);
    expect(stored).toMatchObject({ id: first.id, model: 'sface-2021dec-int8', enrolled_by: manager.id, terminal_id: a.terminal1.id, deleted_at: null });
    expect(stored.template.toString('base64')).toBe(first.template);
    expect((await consents(someone.id))[0]).toMatchObject({
      id: first.consent.id, kind: 'face', term_version: 'biometria-v1', collected_by: manager.id, revoked_at: null,
    });
    expect(await faceOf(someone.id)).toEqual({ model: 'sface-2021dec-int8', template: first.template });
    const events = await ownerPool.query("SELECT count(*)::int AS n FROM auth_event WHERE user_id = $1 AND event_type = 'face_enrolled'", [someone.id]);
    expect(events.rows[0].n).toBe(1);

    const second = enrollment(someone.id, { template: fakeTemplate(2) });
    await push([['face_enrollment', second]]);
    const all = await templates(someone.id);
    expect(all.map((t) => [t.id, t.deleted_at === null])).toEqual([[first.id, false], [second.id, true]]);
    expect((await faceOf(someone.id)).template).toBe(second.template);
    // Ninguém da aplicação lê o código do rosto direto; nem altera.
    for (const source of ['v_face_template', 'v_biometric_consent', 'face_template', 'biometric_consent']) {
      await expect(readAs(a.admin, `SELECT * FROM ${source}`)).rejects.toThrow(/permission denied/);
    }
    await expect(ownerPool.query("UPDATE face_template SET template = decode(repeat('00', 512), 'hex') WHERE id = $1", [second.id]))
      .rejects.toSatisfy(hasCode('FA104'));
    expect(await faceOf(operator.id)).toBeNull();
  });

  it('sem a permissão, de outro grupo, inativo, fora do formato ou repetido: conflito', async () => {
    const someone = await person('Operador de caixa');
    const outsider = await person('Gerente', b);
    expect(codes(await push([['face_enrollment', enrollment(someone.id, { enrolled_by: operator.id })]]))).toEqual([['conflict', 'FA822']]);
    expect(codes(await push([
      ['face_enrollment', enrollment(outsider.id)],
      ['face_enrollment', enrollment(someone.id, { enrolled_by: outsider.id })],
    ]))).toEqual([['conflict', 'FA004'], ['conflict', 'FA004']]);
    const bad = [
      enrollment(someone.id, { template: Buffer.alloc(256).toString('base64') }),
      enrollment(someone.id, { template: 12 }),
      enrollment(someone.id, { model: 'outro' }),
      enrollment(someone.id, { consent: null }),
      enrollment(someone.id, { consent: { id: uuidV7(), term_version: 'Biometria V1', consented_at: iso() } }),
      enrollment(someone.id, { consent: { id: 'nada', term_version: 'biometria-v1', consented_at: iso() } }),
      enrollment(someone.id, { enrolled_at: 'ontem' }),
      enrollment(someone.id, { user_id: 'nada' }),
      { ...enrollment(someone.id), id: 'nada' },
    ];
    expect(codes(await push(bad.map((e) => ['face_enrollment', e])))).toEqual(bad.map(() => ['conflict', 'FA962']));
    expect(codes(await push([['face_enrollment', enrollment(someone.id, { enrolled_at: '2026-13-45T10:00:00Z' })]]))).toEqual([['conflict', 'FA962']]);
    const once = enrollment(someone.id);
    await push([['face_enrollment', once]]);
    expect(codes(await push([['face_enrollment', once]]))).toEqual([['conflict', 'FA963']]);
    expect(codes(await push([['face_enrollment', { ...enrollment(someone.id), consent: once.consent }]]))).toEqual([['conflict', 'FA963']]);
    expect(codes(await push([['face_enrollment', { ...enrollment(someone.id), id: once.id }]]))).toEqual([['conflict', 'FA963']]);
    await ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [someone.id]);
    expect(codes(await push([['face_enrollment', enrollment(someone.id)]]))).toEqual([['conflict', 'FA209']]);
    expect(await templates(outsider.id)).toEqual([]);
  });

  it('revogar apaga o rosto e o tira do PDV: a própria pessoa ou quem pode definir o PIN dela', async () => {
    const someone = await person('Operador de caixa');
    await push([['face_enrollment', enrollment(someone.id)]]);
    await expect(revoke(operator, someone.id)).rejects.toSatisfy(hasCode('FA002'));
    await expect(revoke(b.admin, someone.id)).rejects.toSatisfy(hasCode('FA002'));
    await revoke(a.admin, someone.id);
    expect((await templates(someone.id))[0].deleted_at).not.toBeNull();
    expect((await consents(someone.id))[0]).toMatchObject({ revoked_by: a.admin.id });
    expect(await faceOf(someone.id)).toBeNull();
    await expect(revoke(a.admin, someone.id)).rejects.toSatisfy(hasCode('FA823'));
    const events = await ownerPool.query("SELECT count(*)::int AS n FROM auth_event WHERE user_id = $1 AND event_type = 'face_revoked'", [someone.id]);
    expect(events.rows[0].n).toBe(1);
    // A própria pessoa revoga, mesmo sem permissão sobre usuários.
    await push([['face_enrollment', enrollment(operator.id)]]);
    await revoke(operator, operator.id);
    expect(await faceOf(operator.id)).toBeNull();
  });

  it('situação do rosto para a retaguarda, sem o código', async () => {
    const someone = await person('Operador de caixa');
    const done = enrollment(someone.id);
    await push([['face_enrollment', done]]);
    const rows = await readAs(a.admin, 'SELECT * FROM app.face_enrollments()');
    const row = rows.find((r) => r.user_id === someone.id);
    expect(row).toMatchObject({ enrolled_by_name: manager.name, term_version: 'biometria-v1' });
    expect(Object.keys(row).sort()).toEqual(['enrolled_at', 'enrolled_by_name', 'term_version', 'user_id']);
    expect(await readAs(b.admin, 'SELECT * FROM app.face_enrollments()')).toEqual([]);
    // Quem não vê usuários vê só o próprio.
    const cashier = await person('Operador de caixa');
    await push([['face_enrollment', enrollment(cashier.id)]]);
    const own = await readAs(cashier, 'SELECT * FROM app.face_enrollments()');
    expect(own.map((r) => r.user_id)).toEqual([cashier.id]);
    expect(await readAs(a.noBranchUser, 'SELECT * FROM app.face_enrollments()')).toEqual([]);
    const has = (await ownerPool.query("SELECT app.user_has_permission($1, 'users.biometrics', $2) AS ok", [manager.id, a.branch1.id])).rows[0].ok;
    expect(has).toBe(true);
  });
});
