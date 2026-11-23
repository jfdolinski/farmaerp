import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;

// CPF gerado na hora, com dígitos válidos: nunca de uma pessoa real.
function cpf() {
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits) => {
    const total = digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0);
    const rest = (total * 10) % 11;
    return rest === 10 ? 0 : rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}
const tag = () => randomBytes(4).toString('hex');

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

/** Chamada do terminal, confirmada como na API. */
async function asTerminal(terminal, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal?.id ?? '');
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows[0].r;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const search = (terminal, query) => asTerminal(terminal, 'SELECT app.pdv_search_customers($1) AS r', [query]);
const fetchCustomer = (terminal, id) => asTerminal(terminal, 'SELECT app.pdv_get_customer($1) AS r', [id]);
const pullPage = (terminal, cursor = null, until = null, after = null, limit = 1000) =>
  asTerminal(terminal, 'SELECT app.pdv_pull($1, $2, $3, $4) AS r', [cursor, until, after, limit]);
async function pullAll(terminal, cursor = null) {
  let page = await pullPage(terminal, cursor);
  const items = [...page.items];
  while (page.next) {
    page = await pullPage(terminal, cursor, page.until, page.next);
    items.push(...page.items);
  }
  const byKey = new Map(items.map((item) => [`${item.type}:${item.id}`, item.data]));
  return { until: page.until, items, byKey };
}
const statusOf = async (terminal) => (await ownerPool.query(
  'SELECT last_pull_at, last_push_at, pull_cursor::text AS pull_cursor, initial_load_at FROM terminal_status WHERE terminal_id = $1 AND deleted_at IS NULL',
  [terminal.id],
)).rows[0];

async function newCustomer(fixture, data = {}) {
  const id = await committed(fixture.admin, async (client) => {
    const { rows } = await client.query('SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
      personType: 'individual', document: cpf(), name: `Cliente Sync ${tag()}`, phone: '11988887777', city: 'São Paulo', state: 'SP', ...data,
    })]);
    return rows[0].id;
  });
  return (await ownerPool.query('SELECT * FROM customer WHERE id = $1', [id])).rows[0];
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('busca de cliente pelo PDV', () => {
  it('acha por nome, código ou documento, com o documento mascarado e só do grupo', async () => {
    const marker = `Zeferino ${tag()}`;
    const one = await newCustomer(a, { name: `${marker} Silva` });
    const two = await newCustomer(a, { name: `${marker} Souza` });
    const other = await newCustomer(b, { name: `${marker} Outro` });

    const byName = await search(a.terminal1, marker.toLowerCase());
    expect(byName.map((row) => row.id)).toEqual([one.id, two.id]);
    expect(byName[0]).toMatchObject({ code: Number(one.code), name: one.name, person_type: 'individual', city: 'São Paulo', state: 'SP' });
    expect(byName[0].document_masked).not.toContain(one.document.slice(3, 9));
    expect(JSON.stringify(byName)).not.toContain(one.document);
    expect(Object.keys(byName[0]).sort()).toEqual(['city', 'code', 'document_masked', 'id', 'name', 'person_type', 'state', 'trade_name']);

    expect((await search(a.terminal1, String(one.code))).map((row) => row.id)).toContain(one.id);
    const formatted = `${one.document.slice(0, 3)}.${one.document.slice(3, 6)}.${one.document.slice(6, 9)}-${one.document.slice(9)}`;
    expect((await search(a.terminal1, formatted)).map((row) => row.id)).toEqual([one.id]);
    expect((await search(b.terminal1, marker)).map((row) => row.id)).toEqual([other.id]);
  });

  it('busca curta pede mais informação; no máximo 20 resultados', async () => {
    for (const query of ['', '  ', 'ab', 'a-b', 'x'.repeat(101)]) {
      await expect(search(a.terminal1, query)).rejects.toSatisfy(hasCode('FA961'));
    }
    const marker = `Lote${tag()}`;
    for (let i = 0; i < 22; i += 1) await newCustomer(a, { name: `${marker} ${String(i).padStart(2, '0')}` });
    expect(await search(a.terminal1, marker)).toHaveLength(20);
  });

  it('cliente excluído não aparece; terminal bloqueado não busca', async () => {
    const gone = await newCustomer(a, { name: `Excluido ${tag()}` });
    await ownerPool.query('UPDATE customer SET deleted_at = now() WHERE id = $1', [gone.id]);
    expect(await search(a.terminal1, gone.name)).toEqual([]);
    const blocked = (await ownerPool.query(
      `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', 'blocked', $3) RETURNING *`,
      [a.branch1.id, `Caixa bloqueado ${tag()}`, `chave-${randomUUID()}`],
    )).rows[0];
    await expect(search(blocked, 'Cliente Sync')).rejects.toSatisfy(hasCode('FA304'));
    await expect(fetchCustomer(blocked, gone.id)).rejects.toSatisfy(hasCode('FA304'));
    await expect(search(null, 'Cliente Sync')).rejects.toSatisfy(hasCode('FA306'));
  });

  it('o cliente escolhido desce inteiro e fica registrado para este terminal', async () => {
    const customer = await newCustomer(a, { email: 'cliente@exemplo.test', postalCode: '01001000', street: 'Praça da Sé' });
    const fetched = await fetchCustomer(a.terminal1, customer.id);
    expect(fetched).toMatchObject({
      id: customer.id,
      data: {
        code: Number(customer.code), document: customer.document, name: customer.name, phone: '11988887777',
        email: 'cliente@exemplo.test', postal_code: '01001000', street: 'Praça da Sé', state: 'SP',
      },
    });
    await fetchCustomer(a.terminal1, customer.id);
    const cache = (await ownerPool.query(
      'SELECT terminal_id, economic_group_id FROM pdv_customer_cache WHERE customer_id = $1 AND deleted_at IS NULL', [customer.id],
    )).rows;
    expect(cache).toEqual([{ terminal_id: a.terminal1.id, economic_group_id: a.group.id }]);
    // Cliente de outro grupo ou inexistente: não encontrado.
    const foreign = await newCustomer(b);
    await expect(fetchCustomer(a.terminal1, foreign.id)).rejects.toSatisfy(hasCode('FA006'));
    await expect(fetchCustomer(a.terminal1, randomUUID())).rejects.toSatisfy(hasCode('FA006'));
  });
});

describe('cliente guardado na descida', () => {
  it('só o terminal que guardou recebe as mudanças e a exclusão', async () => {
    const customer = await newCustomer(a);
    await fetchCustomer(a.terminal1, customer.id);
    const full = await pullAll(a.terminal1);
    expect(full.byKey.get(`customer:${customer.id}`)).toMatchObject({ name: customer.name });
    expect((await pullAll(a.terminal2)).byKey.has(`customer:${customer.id}`)).toBe(false);
    const other = (await pullAll(a.terminal2)).until;

    await committed(a.admin, (client) => client.query('SELECT app.update_customer($1, $2::jsonb)', [
      customer.id, JSON.stringify({ personType: 'individual', document: customer.document, name: 'Nome Atualizado Sync' }),
    ]));
    const step = await pullAll(a.terminal1, full.until);
    expect(step.items.map((item) => item.type)).toEqual(['customer']);
    expect(step.byKey.get(`customer:${customer.id}`)).toMatchObject({ name: 'Nome Atualizado Sync' });
    expect((await pullAll(a.terminal2, other)).items).toEqual([]);

    await ownerPool.query('UPDATE customer SET deleted_at = now() WHERE id = $1', [customer.id]);
    const removed = await pullAll(a.terminal1, step.until);
    expect(removed.byKey.get(`customer:${customer.id}`)).toBeNull();
  });

  it('a ordem dos pacotes inclui os clientes no fim', async () => {
    const customer = await newCustomer(a);
    await fetchCustomer(a.terminal1, customer.id);
    const page = await pullPage(a.terminal1, null, null, null, 1);
    let next = page.next;
    const types = [page.items[0].type];
    while (next) {
      const more = await pullPage(a.terminal1, null, page.until, next, 50);
      types.push(...more.items.map((item) => item.type));
      next = more.next;
    }
    expect(types.at(-1)).toBe('customer');
  });
});

describe('situação da sincronização', () => {
  it('a central anota a descida concluída, a carga inicial e a subida', async () => {
    const terminal = (await ownerPool.query(
      `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', 'active', $3) RETURNING *`,
      [a.branch1.id, `Caixa situação ${tag()}`, `chave-${randomUUID()}`],
    )).rows[0];
    expect(await statusOf(terminal)).toBeUndefined();

    // Pacote do meio da janela não conta como descida concluída.
    const first = await pullPage(terminal, null, null, null, 1);
    expect(first.next).not.toBeNull();
    expect((await statusOf(terminal))?.last_pull_at ?? null).toBeNull();

    const load = await pullAll(terminal);
    const afterLoad = await statusOf(terminal);
    expect(afterLoad.pull_cursor).toBe(load.until);
    expect(afterLoad.initial_load_at).not.toBeNull();
    expect(afterLoad.last_pull_at).not.toBeNull();
    expect(afterLoad.last_push_at).toBeNull();

    const step = await pullAll(terminal, load.until);
    const afterStep = await statusOf(terminal);
    expect(afterStep.initial_load_at).toEqual(afterLoad.initial_load_at);
    expect(afterStep.pull_cursor).toBe(step.until);

    const id = (() => {
      const bytes = randomBytes(16);
      bytes.writeUIntBE(Date.now(), 0, 6);
      bytes[6] = (bytes[6] & 0x0f) | 0x70;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = bytes.toString('hex');
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    })();
    await asTerminal(terminal, 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
      { id, sequence: 1, kind: 'log', payload: { level: 'debug', time: new Date().toISOString(), msg: 'x' } },
    ])]);
    const afterPush = await statusOf(terminal);
    expect(afterPush.last_push_at).not.toBeNull();
    expect(afterPush.last_pull_at).toEqual(afterStep.last_pull_at);

    // Na retaguarda: o que falta descer e o conflito aberto.
    const monitor = async (user) => committed(user, (client) =>
      client.query('SELECT * FROM v_terminal_monitor WHERE id = $1', [terminal.id]).then((r) => r.rows[0]));
    let row = await monitor(a.admin);
    expect(row).toMatchObject({ pending_changes: 0, open_conflicts: 1 });
    expect(row.initial_load_at).not.toBeNull();
    // Uma mudança no grupo (cliente) ainda não descida.
    await ownerPool.query("UPDATE customer SET phone = '11977776666' WHERE id = (SELECT id FROM customer WHERE economic_group_id = $1 AND deleted_at IS NULL LIMIT 1)", [a.group.id]);
    row = await monitor(a.admin);
    expect(row.pending_changes).toBeGreaterThan(0);
    await pullAll(terminal, (await statusOf(terminal)).pull_cursor);
    expect((await monitor(a.admin)).pending_changes).toBe(0);
    // A descida nova não apaga a hora da última subida.
    expect((await statusOf(terminal)).last_push_at).toEqual(afterPush.last_push_at);

    // Quem vê terminais sem ver a sincronização não conta os conflitos; outro grupo não vê nada.
    const viewerRow = await monitor(a.oneBranchUser);
    expect(viewerRow.open_conflicts).toBe(0);
    expect(viewerRow.pending_changes).toBe(0);
    expect(await monitor(b.admin)).toBeUndefined();
    // Sem permissão de ver terminais na filial, a defasagem não aparece nem chamando direto.
    expect(await committed(a.noBranchUser, (client) =>
      client.query('SELECT app.terminal_sync_lag($1) AS n', [terminal.id]).then((r) => r.rows[0].n))).toBeNull();
    // Conflito resolvido deixa de contar.
    await committed(a.admin, (client) => client.query(
      `SELECT app.resolve_sync_conflict(id, 'Visto no teste') FROM sync_conflict WHERE terminal_id = $1 AND status = 'open'`, [terminal.id],
    ));
    expect((await monitor(a.admin)).open_conflicts).toBe(0);
    expect(await committed(b.admin, (client) =>
      client.query('SELECT app.terminal_sync_lag($1) AS n', [terminal.id]).then((r) => r.rows[0].n))).toBeNull();
  });

  it('funções internas e o registro de clientes não ficam com a API', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      for (const sql of [
        'SELECT * FROM pdv_customer_cache',
        'SELECT * FROM v_pdv_customer_cache',
        `SELECT app.record_terminal_sync('pull', NULL, true)`,
        `SELECT * FROM app.pdv_customer_data('${a.terminal1.id}', ARRAY[]::uuid[])`,
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql)).rejects.toThrow(/permission denied/);
        await client.query('ROLLBACK TO s');
      }
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
    await expect(ownerPool.query('UPDATE pdv_customer_cache SET customer_id = customer_id WHERE false')).resolves.toBeDefined();
    const row = (await ownerPool.query('SELECT id FROM pdv_customer_cache LIMIT 1')).rows[0];
    await expect(ownerPool.query('UPDATE pdv_customer_cache SET terminal_id = $1 WHERE id = $2', [a.terminal2.id, row.id]))
      .rejects.toSatisfy(hasCode('FA104'));
  });
});
