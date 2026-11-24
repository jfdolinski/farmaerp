import { pbkdf2Sync, randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;

const tag = () => randomBytes(4).toString('hex');
function uuidV7() {
  const bytes = randomBytes(16);
  bytes.writeUIntBE(Date.now(), 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const pinHash = (pin, salt = randomBytes(16)) =>
  `pbkdf2-sha256$210000$${salt.toString('base64')}$${pbkdf2Sync(pin, salt, 210000, 32, 'sha256').toString('base64')}`;

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
const setPin = (actor, target, hash) => committed(actor, (client) => client.query('SELECT app.set_user_pin($1, $2, $3)', [target.id, hash, '10.0.0.1']));
async function pull(terminal, cursor = null) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    let page = (await client.query('SELECT app.pdv_pull($1, NULL, NULL, 1000) AS r', [cursor])).rows[0].r;
    const items = [...page.items];
    while (page.next) {
      page = (await client.query('SELECT app.pdv_pull($1, $2, $3, 1000) AS r', [cursor, page.until, page.next])).rows[0].r;
      items.push(...page.items);
    }
    await client.query('COMMIT');
    return { until: page.until, format: page.format, get: (type, id) => items.find((item) => item.type === type && item.id === id)?.data };
  } finally {
    client.release();
  }
}
const person = async (fixture, roleCodes = []) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [fixture.group.id, `Pessoa PIN ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, fixture.branch1.id]);
  if (roleCodes.length > 0) {
    const role = (await ownerPool.query('INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *', [fixture.group.id, `Perfil PIN ${tag()}`])).rows[0];
    await ownerPool.query('INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)', [role.id, roleCodes]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, fixture.branch1.id]);
  }
  return user;
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('PIN do PDV', () => {
  it('quem pode gerar senha temporária define o PIN; o hash desce para o PDV da filial', async () => {
    const operator = await person(a, ['sales.sell']);
    const before = await pull(a.terminal1);
    expect(before.format).toBe(4);
    expect(before.get('user', operator.id)).toMatchObject({ pin_hash: null });

    const hash = pinHash('2580');
    await setPin(a.admin, operator, hash);
    const step = await pull(a.terminal1, before.until);
    expect(step.get('user', operator.id)).toMatchObject({ pin_hash: hash, permissions: ['sales.sell'] });
    const events = (await ownerPool.query(`SELECT event_type, ip_address FROM auth_event WHERE user_id = $1`, [operator.id])).rows;
    expect(events).toEqual([{ event_type: 'pin_set', ip_address: '10.0.0.1' }]);

    // Trocar o PIN mantém um registro só, com o hash novo.
    const second = pinHash('7391');
    await setPin(a.admin, operator, second);
    const rows = (await ownerPool.query('SELECT pin_hash FROM user_pin WHERE user_id = $1 AND deleted_at IS NULL', [operator.id])).rows;
    expect(rows).toEqual([{ pin_hash: second }]);
    // Outra filial do grupo, onde a pessoa não tem perfil, não recebe.
    expect((await pull(a.terminal2)).get('user', operator.id)).toBeUndefined();
  });

  it('sem permissão, de outro grupo ou inativo: recusa', async () => {
    const target = await person(a);
    const plain = await person(a, ['sales.sell']);
    await expect(setPin(plain, target, pinHash('2580'))).rejects.toSatisfy(hasCode('FA002'));
    await expect(setPin(b.admin, target, pinHash('2580'))).rejects.toSatisfy(hasCode('FA002'));
    await expect(setPin(a.admin, { id: randomUUID() }, pinHash('2580'))).rejects.toSatisfy(hasCode('FA002'));
    // Quem pode gerar senha na loja não age sobre quem tem permissão que ele não tem.
    const storeManager = await person(a, ['users.reset_password', 'users.view']);
    const stronger = await person(a, ['sales.sell', 'stock.adjust']);
    await expect(setPin(storeManager, stronger, pinHash('2580'))).rejects.toSatisfy(hasCode('FA002'));
    const weaker = await person(a, ['users.view']);
    await setPin(storeManager, weaker, pinHash('2580'));
    const inactive = await person(a);
    await ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [inactive.id]);
    await expect(setPin(a.admin, inactive, pinHash('2580'))).rejects.toSatisfy(hasCode('FA209'));
  });

  it('só aceita o hash no formato combinado', async () => {
    const target = await person(a);
    for (const hash of ['2580', 'pbkdf2-sha256$210000$abc$def', pinHash('2580').replace('pbkdf2-sha256', 'md5'), `${pinHash('2580')}x`]) {
      await expect(setPin(a.admin, target, hash)).rejects.toSatisfy(hasCode('FA965'));
    }
  });

  it('a API não lê o PIN', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      for (const sql of ['SELECT * FROM user_pin', 'SELECT * FROM v_user_pin']) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql)).rejects.toThrow(/permission denied/);
        await client.query('ROLLBACK TO s');
      }
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('os dados fiscais trazem o último número de venda do terminal', async () => {
    const operator = await person(a, ['sales.sell']);
    expect((await pull(a.terminal1)).get('fiscal', a.branch1.id).last_sale_number).toBeNull();
    const sessionId = uuidV7();
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setTerminal(client, a.terminal1.id);
      const result = (await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
        { id: sessionId, sequence: 1, kind: 'cash_session_open', payload: { id: sessionId, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 } },
      ])])).rows[0].r;
      await client.query('COMMIT');
      expect(result.results[0].status).toBe('applied');
    } finally {
      client.release();
    }
    await ownerPool.query(
      `INSERT INTO sale (economic_group_id, branch_id, terminal_id, cash_session_id, number, code, sold_by, sold_at, subtotal, discount_total, total)
       VALUES ($1, $2, $3, $4, 41, '1-000041', $5, now(), 0, 0, 0)`,
      [a.group.id, a.branch1.id, a.terminal1.id, sessionId, operator.id],
    );
    expect((await pull(a.terminal1)).get('fiscal', a.branch1.id).last_sale_number).toBe(41);
    expect((await pull(a.terminal2)).get('fiscal', a.branch2.id).last_sale_number).toBeNull();
  });
});
