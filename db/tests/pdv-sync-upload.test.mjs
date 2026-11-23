import { randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;
let viewer;
let resolver;

const tag = () => randomBytes(4).toString('hex');

// UUID v7 como o PDV gera: tempo nos primeiros 48 bits, versão 7 e variante 10.
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

let sequence = 0;
const logItem = (overrides = {}, payload = {}) => {
  sequence += 1;
  return {
    id: uuidV7(),
    sequence,
    kind: 'log',
    payload: {
      level: 'warn', time: new Date().toISOString(), msg: 'Falha de conexão com a API', error_code: 'FA001',
      trace_id: uuidV7(), version: '0.2.0', fields: { route: '/terminals/heartbeat' }, ...payload,
    },
    ...overrides,
  };
};

/** Uma subida confirmada, como a API faz. */
async function push(terminal, items) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal?.id ?? '');
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(items)]);
    await client.query('COMMIT');
    return rows[0].r.results;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function asUserDo(user, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    return await fn(client);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}

const insertUser = async (fixture, roleCodes, branch) => {
  const role = (await ownerPool.query('INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *', [fixture.group.id, `Sync ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)', [role.id, roleCodes]);
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [fixture.group.id, `Pessoa ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, branch.id]);
  return user;
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  viewer = await insertUser(a, ['sync.view'], a.branch1);
  resolver = await insertUser(a, ['sync.view', 'sync.resolve'], a.branch1);
});
afterAll(closePools);

describe('subida', () => {
  it('aplica os logs em ordem e guarda o recibo de cada um', async () => {
    const first = logItem();
    const second = logItem({}, { level: 'error', error_code: 'FA000', msg: 'Erro inesperado', fields: { err: 'StateError' } });
    expect(await push(a.terminal1, [first, second])).toEqual([
      { id: first.id, status: 'applied', code: null },
      { id: second.id, status: 'applied', code: null },
    ]);
    const logs = (await ownerPool.query(
      'SELECT * FROM terminal_log WHERE id = ANY ($1) ORDER BY logged_at, id', [[first.id, second.id]],
    )).rows;
    expect(logs.map((log) => [log.level, log.message, log.error_code, log.terminal_id, log.branch_id])).toEqual([
      ['warn', 'Falha de conexão com a API', 'FA001', a.terminal1.id, a.branch1.id],
      ['error', 'Erro inesperado', 'FA000', a.terminal1.id, a.branch1.id],
    ]);
    expect(logs[0]).toMatchObject({ entry_trace_id: first.payload.trace_id, app_version: '0.2.0', fields: { route: '/terminals/heartbeat' } });
    expect(logs[0].economic_group_id).toBe(a.group.id);
    const receipts = (await ownerPool.query('SELECT id, sequence, status, kind FROM sync_receipt WHERE id = ANY ($1) ORDER BY sequence', [[first.id, second.id]])).rows;
    expect(receipts.map((r) => [r.id, Number(r.sequence), r.status, r.kind])).toEqual([
      [first.id, first.sequence, 'applied', 'log'], [second.id, second.sequence, 'applied', 'log'],
    ]);
  });

  it('reenvio não aplica de novo, mesmo misturado com itens novos', async () => {
    const old = logItem();
    await push(a.terminal1, [old]);
    const fresh = logItem();
    expect(await push(a.terminal1, [old, fresh])).toEqual([
      { id: old.id, status: 'duplicate', result: 'applied', code: null },
      { id: fresh.id, status: 'applied', code: null },
    ]);
    const { rows } = await ownerPool.query('SELECT count(*)::int AS n FROM terminal_log WHERE id = ANY ($1)', [[old.id, fresh.id]]);
    expect(rows[0].n).toBe(2);
  });

  it('item que o banco recusa vira conflito, e a fila segue', async () => {
    const cases = [
      [logItem({}, { level: 'info' }), 'FA958'],
      [logItem({}, { msg: '' }), 'FA958'],
      [logItem({}, { msg: 'x'.repeat(501) }), 'FA958'],
      [logItem({}, { error_code: 'E1' }), 'FA958'],
      [logItem({}, { trace_id: 'nada' }), 'FA958'],
      [logItem({}, { time: 'ontem' }), 'FA958'],
      [logItem({}, { time: undefined }), 'FA958'],
      [logItem({}, { time: '2026-13-45T00:00:00Z' }), 'FA958'],
      [logItem({}, { time: '2026-02-30T25:61:00Z' }), 'FA958'],
      [logItem({}, { time: new Date(Date.now() + 3 * 86400000).toISOString() }), 'FA958'],
      [logItem({}, { time: '2020-01-01T00:00:00Z' }), 'FA958'],
      [logItem({}, { fields: ['lista'] }), 'FA958'],
      [logItem({}, { fields: { big: 'x'.repeat(9000) } }), 'FA958'],
      [logItem({}, { version: 'v'.repeat(51) }), 'FA958'],
      [logItem({ kind: 'promotion' }), 'FA959'],
    ];
    const ok = logItem();
    const results = await push(a.terminal1, [...cases.map(([item]) => item), ok]);
    expect(results.map((r) => [r.status, r.code])).toEqual([...cases.map(([, code]) => ['conflict', code]), ['applied', null]]);

    const [badItem] = cases[0];
    const conflict = (await ownerPool.query('SELECT * FROM sync_conflict WHERE receipt_id = $1', [badItem.id])).rows[0];
    expect(conflict).toMatchObject({
      status: 'open', kind: 'log', error_code: 'FA958', terminal_id: a.terminal1.id, branch_id: a.branch1.id,
      detail: 'O registro enviado pelo terminal é inválido.', payload: badItem.payload,
    });
    expect((await ownerPool.query('SELECT status FROM sync_receipt WHERE id = $1', [badItem.id])).rows[0].status).toBe('conflict');
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM terminal_log WHERE id = $1', [badItem.id])).rows[0].n).toBe(0);
    // O reenvio do conflito também não duplica e informa o código.
    expect(await push(a.terminal1, [badItem])).toEqual([{ id: badItem.id, status: 'duplicate', result: 'conflict', code: 'FA958' }]);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sync_conflict WHERE receipt_id = $1', [badItem.id])).rows[0].n).toBe(1);
  });

  it('pacote fora do formato é recusado inteiro, sem gravar nada', async () => {
    const valid = logItem();
    const nonV7 = randomUUID();
    for (const items of [
      {}, [], Array.from({ length: 501 }, () => logItem()), ['texto'],
      [{ ...logItem(), id: 'nada' }], [{ ...logItem(), id: nonV7 }], [{ ...logItem(), sequence: 0 }],
      [{ ...logItem(), sequence: 'um' }], [{ ...logItem(), kind: 'Log!' }], [{ ...logItem(), payload: 'texto' }],
      [valid, { ...logItem(), sequence: valid.sequence }],
    ]) {
      await expect(push(a.terminal1, items)).rejects.toSatisfy(hasCode('FA956'));
    }
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM sync_receipt WHERE id = $1', [valid.id])).rows[0].n).toBe(0);
    // Item de outro terminal com o mesmo id: recusa.
    const shared = logItem();
    await push(a.terminal1, [shared]);
    await expect(push(a.terminal2, [shared])).rejects.toSatisfy(hasCode('FA956'));
  });

  it('só o terminal ativo sobe', async () => {
    const terminal = (status) => ownerPool.query(
      `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', $3, $4) RETURNING *`,
      [a.branch1.id, `Caixa ${status} ${tag()}`, status, `chave-${randomUUID()}`],
    ).then((r) => r.rows[0]);
    await expect(push(null, [logItem()])).rejects.toSatisfy(hasCode('FA306'));
    for (const [status, code] of [['pending', 'FA307'], ['blocked', 'FA304'], ['revoked', 'FA305']]) {
      await expect(push(await terminal(status), [logItem()])).rejects.toSatisfy(hasCode(code));
    }
  });
});

describe('conflitos na retaguarda', () => {
  let conflictId;

  beforeAll(async () => {
    const item = logItem({}, { level: 'debug' });
    await push(a.terminal1, [item]);
    conflictId = (await ownerPool.query('SELECT id FROM sync_conflict WHERE receipt_id = $1', [item.id])).rows[0].id;
    // Um conflito em outra filial e outro em outro grupo.
    await push(a.terminal2, [logItem({}, { level: 'debug' })]);
    await push(b.terminal1, [logItem({}, { level: 'debug' })]);
  });

  const list = (user, status = 'open') => asUserDo(user, (client) =>
    client.query('SELECT * FROM app.list_sync_conflicts($1, NULL)', [status]).then((r) => r.rows));

  it('cada um vê só as filiais em que tem a permissão', async () => {
    const forViewer = await list(viewer);
    expect(forViewer.some((row) => row.id === conflictId)).toBe(true);
    expect(forViewer.every((row) => row.branch_id === a.branch1.id)).toBe(true);
    expect(forViewer.find((row) => row.id === conflictId)).toMatchObject({
      terminal_name: a.terminal1.name, branch_name: a.branch1.name, error_code: 'FA958', can_resolve: false,
    });
    const forAdmin = await list(a.admin);
    expect(new Set(forAdmin.map((row) => row.branch_id))).toEqual(new Set([a.branch1.id, a.branch2.id]));
    expect((await list(b.admin)).some((row) => row.id === conflictId)).toBe(false);
    expect(await list(a.oneBranchUser)).toEqual([]);
    // A tabela segue a mesma regra: nada de outra filial nem de outro grupo.
    const visible = await asUserDo(viewer, (client) => client.query('SELECT id, branch_id FROM v_sync_conflict').then((r) => r.rows));
    expect(visible.some((row) => row.id === conflictId)).toBe(true);
    expect(visible.every((row) => row.branch_id === a.branch1.id)).toBe(true);
    const others = (await ownerPool.query(
      'SELECT count(*)::int AS n FROM sync_conflict WHERE branch_id <> $1', [a.branch1.id],
    )).rows[0].n;
    expect(others).toBeGreaterThan(0);
    expect(await asUserDo(a.oneBranchUser, (client) => client.query('SELECT id FROM v_sync_conflict').then((r) => r.rows))).toEqual([]);
  });

  it('recibos e logs não são lidos pela API', async () => {
    await asUserDo(a.admin, async (client) => {
      for (const sql of ['SELECT * FROM sync_receipt', 'SELECT * FROM v_terminal_log', 'SELECT * FROM terminal_log']) {
        await client.query('SAVEPOINT s');
        const rows = await client.query(sql).then((r) => r.rows, () => []);
        expect(rows).toEqual([]);
        await client.query('ROLLBACK TO s');
      }
    });
  });

  it('resolver pede permissão, explicação e conflito aberto', async () => {
    const resolve = (user, id, note) => asUserDo(user, async (client) => {
      await client.query('SELECT app.resolve_sync_conflict($1, $2)', [id, note]);
      return client.query('SELECT * FROM app.list_sync_conflicts(NULL, NULL) WHERE id = $1', [id]).then((r) => r.rows[0]);
    });
    await expect(resolve(viewer, conflictId, 'ok')).rejects.toSatisfy(hasCode('FA002'));
    await expect(resolve(b.admin, conflictId, 'ok')).rejects.toSatisfy(hasCode('FA006'));
    await expect(resolve(a.oneBranchUser, conflictId, 'ok')).rejects.toSatisfy(hasCode('FA006'));
    await expect(resolve(resolver, randomUUID(), 'ok')).rejects.toSatisfy(hasCode('FA006'));
    await expect(resolve(resolver, conflictId, '   ')).rejects.toSatisfy(hasCode('FA302'));
    await expect(resolve(resolver, conflictId, 'x'.repeat(501))).rejects.toSatisfy(hasCode('FA960'));

    const resolved = await resolve(resolver, conflictId, '  PDV antigo, já atualizado.  ');
    expect(resolved).toMatchObject({ status: 'resolved', resolution_note: 'PDV antigo, já atualizado.', resolved_by_name: resolver.name });

    // Confirma e confere: resolvido não volta a ser resolvido, e o conteúdo não muda.
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, resolver.id);
      await client.query('SELECT app.resolve_sync_conflict($1, $2)', [conflictId, 'Resolvido']);
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    await expect(resolve(resolver, conflictId, 'De novo')).rejects.toSatisfy(hasCode('FA960'));
    expect((await list(resolver, 'resolved')).find((row) => row.id === conflictId)).toMatchObject({ resolution_note: 'Resolvido' });
    expect((await list(resolver)).some((row) => row.id === conflictId)).toBe(false);
    await expect(ownerPool.query(`UPDATE sync_conflict SET payload = '{}' WHERE id = $1`, [conflictId])).rejects.toSatisfy(hasCode('FA104'));
    // Resolvido precisa de data, autor e explicação; aberto não tem nenhum dos três.
    for (const sql of [
      'UPDATE sync_conflict SET resolved_at = NULL WHERE id = $1',
      'UPDATE sync_conflict SET resolved_by = NULL WHERE id = $1',
      'UPDATE sync_conflict SET resolution_note = NULL WHERE id = $1',
      `UPDATE sync_conflict SET status = 'open' WHERE id = $1`,
    ]) {
      await expect(ownerPool.query(sql, [conflictId])).rejects.toSatisfy(hasCode('FA960'));
    }
  });

  it('as tabelas recusam por conta própria o que a função já barra', async () => {
    const receipt = (status) => ownerPool.query(
      `INSERT INTO sync_receipt (id, economic_group_id, branch_id, terminal_id, kind, sequence, status)
       VALUES ($1, $2, $3, $4, 'log', 1, $5)`,
      [uuidV7(), a.group.id, a.branch1.id, a.terminal1.id, status],
    );
    await expect(receipt('outro')).rejects.toSatisfy(hasCode('FA956'));
    const log = (level, message = 'x') => ownerPool.query(
      `INSERT INTO terminal_log (id, economic_group_id, branch_id, terminal_id, level, logged_at, message)
       VALUES ($1, $2, $3, $4, $5, now(), $6)`,
      [uuidV7(), a.group.id, a.branch1.id, a.terminal1.id, level, message],
    );
    await expect(log('info')).rejects.toSatisfy(hasCode('FA958'));
    await expect(log('warn', '')).rejects.toSatisfy(hasCode('FA958'));
  });

  it('recibo e log não mudam depois de gravados', async () => {
    const item = logItem();
    await push(a.terminal1, [item]);
    await expect(ownerPool.query(`UPDATE sync_receipt SET status = 'conflict' WHERE id = $1`, [item.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query(`UPDATE terminal_log SET message = 'outro' WHERE id = $1`, [item.id])).rejects.toSatisfy(hasCode('FA104'));
  });
});
