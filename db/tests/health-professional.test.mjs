import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Profissionais da saúde (prescritores): cadastro na retaguarda, descida para os caixas do grupo e
// cadastro rápido feito no caixa (subida pela outbox).

let a;
let b;
let pharmacist;
let clockMs = Date.now();
let sequence = 0;

function uuidV7() {
  clockMs += 1;
  const bytes = randomBytes(16);
  bytes.writeUIntBE(clockMs, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
// Número no conselho único por execução (o banco de teste não é zerado).
const registration = () => String(randomInt(100000, 999999999));

async function run(setup, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setup(client);
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);
const save = (user, data, id = null) =>
  asUser(user, 'SELECT app.save_health_professional($1, $2::jsonb) AS id', [id, JSON.stringify(data)]).then((r) => r[0].id);
const list = (user, search = null, inactive = false) =>
  asUser(user, 'SELECT * FROM app.list_health_professionals($1, $2)', [search, inactive]);

async function pull(terminal, cursor = null) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query('SELECT app.pdv_pull($1, NULL, NULL, 5000) AS r', [cursor]);
    return rows[0].r;
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}
const professionalsIn = (page) => new Map(page.items.filter((i) => i.type === 'health_professional').map((i) => [i.id, i.data]));

async function push(terminal, payload) {
  sequence += 1;
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
      { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind: 'health_professional', payload },
    ])]);
    await client.query('COMMIT');
    return rows[0].r.results[0];
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows: [user] } = await ownerPool.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Farmacêutica ${randomInt(1e6)}`],
  );
  const { rows: [role] } = await ownerPool.query(
    "SELECT * FROM role WHERE economic_group_id = $1 AND name = 'Farmacêutico'", [a.group.id],
  );
  await ownerPool.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [user.id, role.id]);
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  pharmacist = user;
});
afterAll(closePools);

describe('cadastro na retaguarda', () => {
  it('inclui e altera com a permissão; repetido e inválido são recusados', async () => {
    const number = registration();
    const data = { name: '  Dra. Ana Prescritora ', council: 'CRM', registration: number, state: 'sp', specialty: 'Pediatria' };
    await expect(save(a.oneBranchUser, data)).rejects.toSatisfy(hasCode('FA002'));
    const id = await save(pharmacist, data);
    expect((await ownerPool.query('SELECT name, state, specialty, active FROM health_professional WHERE id = $1', [id])).rows[0])
      .toEqual({ name: 'Dra. Ana Prescritora', state: 'SP', specialty: 'Pediatria', active: true });
    // Mesmo conselho, número (com zero à esquerda ou letra minúscula) e UF: repetido.
    await expect(save(a.admin, { ...data, registration: `00${number}` })).rejects.toSatisfy(hasCode('FA733'));
    // Outra UF ou outro conselho é outro registro; outro grupo também.
    await save(a.admin, { ...data, state: 'RJ' });
    await save(a.admin, { ...data, council: 'CRO' });
    await save(b.admin, data);
    for (const bad of [
      { ...data, name: 'Ab' }, { ...data, council: 'XYZ' }, { ...data, registration: '12 34' }, { ...data, state: 'S' },
      { ...data, specialty: 'x' }, { ...data, active: 'sim' }, { council: 'CRM' },
    ]) {
      await expect(save(a.admin, { ...bad, registration: bad.registration ?? registration() })).rejects.toSatisfy(hasCode('FA734'));
    }
    await expect(asUser(a.admin, 'SELECT app.save_health_professional(NULL, $1::jsonb)', ['[]'])).rejects.toSatisfy(hasCode('FA734'));

    // Alteração: sem especialidade e inativo.
    await save(a.admin, { ...data, specialty: '', active: false }, id);
    expect((await ownerPool.query('SELECT specialty, active FROM health_professional WHERE id = $1', [id])).rows[0])
      .toEqual({ specialty: null, active: false });
    // Sem 'active', fica como estava.
    await save(a.admin, { ...data, name: 'Dra. Ana Prescritora Silva' }, id);
    expect((await ownerPool.query('SELECT active FROM health_professional WHERE id = $1', [id])).rows[0].active).toBe(false);
    await expect(save(b.admin, data, id)).rejects.toSatisfy(hasCode('FA006'));
  });

  it('lista por nome ou número, só do grupo; inativo só quando pedido', async () => {
    const number = registration();
    const id = await save(a.admin, { name: 'Dr. Bruno Listado', council: 'CRM', registration: number, state: 'MG' });
    const inactive = await save(a.admin, { name: 'Dr. Bruno Inativo', council: 'CRM', registration: registration(), state: 'MG', active: false });
    expect((await list(pharmacist, 'bruno listado')).map((r) => r.id)).toEqual([id]);
    expect((await list(pharmacist, `0${number}`)).map((r) => r.id)).toEqual([id]);
    expect((await list(pharmacist, 'Dr. Bruno')).map((r) => r.id)).toEqual([id]);
    expect((await list(pharmacist, 'Dr. Bruno', true)).map((r) => r.id).sort()).toEqual([id, inactive].sort());
    expect((await list(pharmacist, 'Dr. Bruno'))[0]).toMatchObject({ can_manage: true, state: 'MG' });
    expect(await list(b.admin, 'Dr. Bruno')).toEqual([]);
    // Leitura direta também fica no grupo (RLS).
    expect(await asUser(b.admin, 'SELECT id FROM v_health_professional WHERE id = $1', [id])).toEqual([]);
    expect(await asUser(a.admin, 'SELECT id FROM v_health_professional WHERE id = $1', [id])).toEqual([{ id }]);
    await expect(list(a.oneBranchUser)).rejects.toSatisfy(hasCode('FA002'));
  });
});

describe('caixa', () => {
  it('desce para os caixas do grupo; mudança e inativação descem de novo', async () => {
    const data = { name: 'Dra. Carla Descida', council: 'CRM', registration: registration(), state: 'PR' };
    const id = await save(a.admin, data);
    const first = await pull(a.terminal1);
    expect(professionalsIn(first).get(id)).toMatchObject({ name: 'Dra. Carla Descida', council: 'CRM', state: 'PR', specialty: null });
    expect(professionalsIn(await pull(b.terminal1)).has(id)).toBe(false);

    await save(a.admin, { ...data, active: false }, id);
    const step = await pull(a.terminal1, first.until);
    expect(professionalsIn(step).has(id)).toBe(true);
    expect(professionalsIn(step).get(id)).toBeNull();
    // Na carga inicial, o inativo não desce.
    expect(professionalsIn(await pull(a.terminal2)).has(id)).toBe(false);
  });

  it('cadastro rápido no caixa: entra com o id do caixa; repetido não muda nada; inválido vira conflito', async () => {
    const number = registration();
    const id = uuidV7();
    expect(await push(a.terminal1, { id, name: 'Dr. Davi Caixa', council: 'CRM', registration: number, state: 'sc' }))
      .toMatchObject({ status: 'applied', code: null });
    expect((await ownerPool.query('SELECT economic_group_id, state FROM health_professional WHERE id = $1', [id])).rows[0])
      .toEqual({ economic_group_id: a.group.id, state: 'SC' });
    // Outro caixa manda o mesmo profissional com outro id: a central fica com o primeiro.
    const other = uuidV7();
    expect(await push(a.terminal2, { id: other, name: 'Davi', council: 'CRM', registration: `0${number}`, state: 'SC' }))
      .toMatchObject({ status: 'applied', code: null });
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM health_professional WHERE id = $1', [other])).rows[0].n).toBe(0);
    // Id já usado por outro profissional: conflito.
    expect(await push(a.terminal1, { id, name: 'Dr. Outro', council: 'CRM', registration: registration(), state: 'SC' }))
      .toMatchObject({ status: 'conflict', code: 'FA734' });
    for (const bad of [
      { id: uuidV7(), name: 'D', council: 'CRM', registration: registration(), state: 'SC' },
      { id: uuidV7(), name: 'Dr. Erro', council: 'XX', registration: registration(), state: 'SC' },
      { id: 'nada', name: 'Dr. Erro', council: 'CRM', registration: registration(), state: 'SC' },
    ]) {
      expect(await push(a.terminal1, bad)).toMatchObject({ status: 'conflict', code: 'FA734' });
    }
    // O do caixa desce para os outros caixas do grupo.
    expect(professionalsIn(await pull(a.terminal2)).get(id)).toMatchObject({ name: 'Dr. Davi Caixa' });
  });

  it('a API não grava direto na tabela', async () => {
    await expect(asUser(a.admin, "INSERT INTO health_professional (economic_group_id, name, council, registration, state) VALUES ($1, 'Dr. Direto', 'CRM', '1', 'SP')", [a.group.id]))
      .rejects.toThrow();
  });
});
