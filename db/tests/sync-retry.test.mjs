import { randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Reaplicar conflitos: o item que a central recusou é aplicado de novo pela retaguarda, com o mesmo
// conteúdo e em nome do terminal de origem.

let a;
let b;
let viewer;
let resolver;
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

let sequence = 0;
const logPayload = (overrides = {}) => ({
  level: 'warn', time: iso(), msg: 'Falha de conexão com a API', error_code: 'FA001', trace_id: uuidV7(), version: '0.2.0',
  fields: {}, ...overrides,
});

async function push(terminal, kind, payload) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    sequence += 1;
    const id = uuidV7();
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([{ id, sequence, kind, payload }])]);
    await client.query('COMMIT');
    return { id, result: rows[0].r.results[0] };
  } finally {
    client.release();
  }
}

/** Conflito como a API antiga deixava: o tipo ainda não existia na central (FA959). */
async function oldConflict(terminal, fixture, kind, payload) {
  sequence += 1;
  const id = uuidV7();
  await ownerPool.query(
    `INSERT INTO sync_receipt (id, economic_group_id, branch_id, terminal_id, kind, sequence, status)
     VALUES ($1, $2, $3, $4, $5, $6, 'conflict')`,
    [id, fixture.group.id, terminal.branch_id, terminal.id, kind, sequence],
  );
  const conflict = (await ownerPool.query(
    `INSERT INTO sync_conflict (economic_group_id, branch_id, terminal_id, receipt_id, kind, error_code, detail, payload)
     VALUES ($1, $2, $3, $4, $5, 'FA959', 'O terminal enviou um tipo de registro desconhecido.', $6) RETURNING *`,
    [fixture.group.id, terminal.branch_id, terminal.id, id, kind, payload],
  )).rows[0];
  return { receiptId: id, conflictId: conflict.id };
}

async function retry(user, id) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    const { rows } = await client.query('SELECT app.retry_sync_conflict($1) AS r', [id]);
    await client.query('COMMIT');
    return rows[0].r;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

const listed = async (user, id) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    return (await client.query('SELECT * FROM app.list_sync_conflicts(NULL, NULL) WHERE id = $1', [id])).rows[0];
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
const conflictRow = async (id) => (await ownerPool.query('SELECT * FROM sync_conflict WHERE id = $1', [id])).rows[0];
const receiptStatus = async (id) => (await ownerPool.query('SELECT status FROM sync_receipt WHERE id = $1', [id])).rows[0].status;

const insertUser = async (fixture, roleCodes) => {
  const role = (await ownerPool.query('INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *', [fixture.group.id, `Reaplicar ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)', [role.id, roleCodes]);
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [fixture.group.id, `Pessoa ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, fixture.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, fixture.branch1.id]);
  return user;
};

// Código de rosto de teste: 128 float32 (512 bytes), nada de rosto de verdade.
const fakeTemplate = (seed = 1) => {
  const buffer = Buffer.alloc(512);
  for (let i = 0; i < 128; i += 1) buffer.writeFloatLE(Math.sin(seed * 7 + i) / 11.3, i * 4);
  return buffer.toString('base64');
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  viewer = await insertUser(a, ['sync.view']);
  resolver = await insertUser(a, ['sync.view', 'sync.resolve']);
  manager = await insertUser(a, ['users.biometrics']);
});
afterAll(closePools);

describe('reaplicar conflito', () => {
  it('o que a central não conhecia é aplicado com o terminal de origem; o recibo vira aplicado e o conflito, resolvido', async () => {
    const payload = logPayload({ msg: 'Aviso guardado no terminal' });
    const { receiptId, conflictId } = await oldConflict(a.terminal1, a, 'log', payload);
    expect(await retry(resolver, conflictId)).toEqual({ status: 'applied' });

    const log = (await ownerPool.query('SELECT * FROM terminal_log WHERE id = $1', [receiptId])).rows[0];
    expect(log).toMatchObject({ terminal_id: a.terminal1.id, branch_id: a.branch1.id, message: 'Aviso guardado no terminal' });
    expect(await receiptStatus(receiptId)).toBe('applied');
    const row = await listed(resolver, conflictId);
    expect(row).toMatchObject({
      status: 'resolved', resolved_by_name: resolver.name, resolution_note: 'Reaplicado com sucesso pela retaguarda.',
      last_retry_by_name: resolver.name, last_retry_code: null, error_code: 'FA959',
    });
    expect(row.last_retry_at).toEqual(row.resolved_at);
    // O reenvio do terminal agora informa aplicado, sem aplicar de novo.
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setTerminal(client, a.terminal1.id);
      const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([{ id: receiptId, sequence: sequence + 1, kind: 'log', payload }])]);
      await client.query('ROLLBACK');
      expect(rows[0].r.results).toEqual([{ id: receiptId, status: 'duplicate', result: 'applied', code: null }]);
    } finally {
      client.release();
    }
    await expect(retry(resolver, conflictId)).rejects.toSatisfy(hasCode('FA960'));
  });

  it('se o banco recusar de novo, o conflito continua aberto com o motivo da última tentativa', async () => {
    const { id } = await push(a.terminal1, 'log', logPayload({ level: 'debug' }));
    const conflictId = (await ownerPool.query('SELECT id FROM sync_conflict WHERE receipt_id = $1', [id])).rows[0].id;
    expect((await listed(resolver, conflictId)).last_retry_at).toBeNull();
    expect(await retry(resolver, conflictId)).toEqual({ status: 'conflict', code: 'FA958' });
    expect(await listed(resolver, conflictId)).toMatchObject({
      status: 'open', resolved_at: null, last_retry_by_name: resolver.name, last_retry_code: 'FA958', error_code: 'FA958',
    });
    expect(await receiptStatus(id)).toBe('conflict');
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM terminal_log WHERE id = $1', [id])).rows[0].n).toBe(0);
    // Ainda dá para marcar como resolvido à mão.
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, resolver.id);
      await client.query('SELECT app.resolve_sync_conflict($1, $2)', [conflictId, 'Aviso sem importância.']);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    expect(await listed(resolver, conflictId)).toMatchObject({ status: 'resolved', last_retry_code: 'FA958' });
  });

  it('pede a permissão de resolver na filial, conflito do próprio grupo e aberto', async () => {
    const { receiptId, conflictId } = await oldConflict(a.terminal1, a, 'log', logPayload());
    await expect(retry(viewer, conflictId)).rejects.toSatisfy(hasCode('FA002'));
    await expect(retry(b.admin, conflictId)).rejects.toSatisfy(hasCode('FA006'));
    await expect(retry(a.oneBranchUser, conflictId)).rejects.toSatisfy(hasCode('FA006'));
    await expect(retry(resolver, randomUUID())).rejects.toSatisfy(hasCode('FA006'));
    expect((await conflictRow(conflictId)).last_retry_at).toBeNull();
    expect(await receiptStatus(receiptId)).toBe('conflict');
    // Na outra filial, só quem tem a permissão lá.
    const other = await oldConflict(a.terminal2, a, 'log', logPayload());
    await expect(retry(resolver, other.conflictId)).rejects.toSatisfy(hasCode('FA006'));
    expect(await retry(a.admin, other.conflictId)).toEqual({ status: 'applied' });
  });

  it('o recibo só muda de conflito para aplicado', async () => {
    const { id } = await push(a.terminal1, 'log', logPayload());
    await expect(ownerPool.query(`UPDATE sync_receipt SET status = 'conflict' WHERE id = $1`, [id])).rejects.toSatisfy(hasCode('FA104'));
    const { receiptId } = await oldConflict(a.terminal1, a, 'log', logPayload());
    for (const sql of [
      `UPDATE sync_receipt SET kind = 'sale' WHERE id = $1`,
      'UPDATE sync_receipt SET sequence = sequence + 1000 WHERE id = $1',
    ]) {
      await expect(ownerPool.query(sql, [receiptId])).rejects.toSatisfy(hasCode('FA104'));
    }
    await ownerPool.query(`UPDATE sync_receipt SET status = 'applied' WHERE id = $1`, [receiptId]);
    await expect(ownerPool.query(`UPDATE sync_receipt SET status = 'conflict' WHERE id = $1`, [receiptId])).rejects.toSatisfy(hasCode('FA104'));
  });

  it('a tentativa registrada precisa de data e autor', async () => {
    const { conflictId } = await oldConflict(a.terminal1, a, 'log', logPayload());
    for (const sql of [
      'UPDATE sync_conflict SET last_retry_at = now() WHERE id = $1',
      `UPDATE sync_conflict SET last_retry_code = 'FA958' WHERE id = $1`,
      `UPDATE sync_conflict SET last_retry_at = now(), last_retry_by = '${resolver.id}', last_retry_code = 'E1' WHERE id = $1`,
    ]) {
      await expect(ownerPool.query(sql, [conflictId])).rejects.toSatisfy(hasCode('FA960'));
    }
  });

  it('cadastro do rosto que a central não conhecia volta pelo reaplicar; a lista não mostra o código do rosto', async () => {
    const someone = await insertUser(a, []);
    const payload = {
      id: uuidV7(), user_id: someone.id, enrolled_by: manager.id, enrolled_at: iso(-3600000), model: 'sface-2021dec-int8',
      template: fakeTemplate(), consent: { id: uuidV7(), term_version: 'biometria-v1', consented_at: iso(-3600000) },
    };
    const { conflictId } = await oldConflict(a.terminal1, a, 'face_enrollment', payload);
    const before = await listed(resolver, conflictId);
    expect(before.payload).toMatchObject({ id: payload.id, user_id: someone.id, template: '(oculto)' });
    expect(JSON.stringify(before)).not.toContain(payload.template);

    expect(await retry(resolver, conflictId)).toEqual({ status: 'applied' });
    const stored = (await ownerPool.query('SELECT * FROM face_template WHERE user_id = $1', [someone.id])).rows;
    expect(stored.map((t) => [t.id, t.terminal_id, t.deleted_at])).toEqual([[payload.id, a.terminal1.id, null]]);
    expect(stored[0].template.toString('base64')).toBe(payload.template);
  });
});
