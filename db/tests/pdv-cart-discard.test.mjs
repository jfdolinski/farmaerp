import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal } from './helpers.mjs';

// Parte A do lote de 26/11: venda descartada no PDV (uma permissão por tela) e permissão própria
// para os cadastros feitos no caixa (cliente e prescritor).

let a;
let b;
const people = {};
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

/** CPF com dígitos certos, gerado ao acaso (não é de ninguém de propósito). */
function cpf() {
  const digits = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(digits).size === 1) digits[0] = (digits[0] + 1) % 10;
  for (const size of [9, 10]) {
    const sum = digits.slice(0, size).reduce((total, digit, index) => total + digit * (size + 1 - index), 0);
    const rest = (sum * 10) % 11;
    digits.push(rest === 10 ? 0 : rest);
  }
  return digits.join('');
}

async function asTerminal(terminal, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
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

async function push(terminal, kind, payload) {
  sequence += 1;
  const rows = await asTerminal(terminal, 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
    { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind, payload },
  ])]);
  return rows[0].r.results[0];
}

/** Pessoa do grupo A com o perfil padrão dado, na filial 1. */
async function personWith(roleName) {
  const { rows: [user] } = await ownerPool.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${randomInt(1e6)}`],
  );
  const { rows: [role] } = await ownerPool.query('SELECT * FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName]);
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  return user;
}

const discard = (overrides = {}) => ({
  id: uuidV7(), screen: 'cashier', user_id: people.manager.id, items_count: 3, total: 45.9,
  discarded_at: '2026-11-26T18:00:00.000Z', ...overrides,
});
const stored = async (id) => (await ownerPool.query('SELECT * FROM pdv_cart_discard WHERE id = $1', [id])).rows[0];

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  for (const [key, role] of [['manager', 'Gerente'], ['pharmacist', 'Farmacêutico'], ['cashier', 'Operador de caixa'], ['clerk', 'Balconista']]) {
    people[key] = await personWith(role);
  }
});
afterAll(closePools);

describe('perfis padrão', () => {
  it('cada perfil recebe as permissões do PDV da tabela aprovada; o Administrador tem todas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT r.name, pg_catalog.array_agg(p.code ORDER BY p.code) AS codes
        FROM role r
        JOIN role_permission rp ON rp.role_id = r.id AND rp.deleted_at IS NULL
        JOIN permission p ON p.id = rp.permission_id AND p.code LIKE 'pdv.%'
       WHERE r.economic_group_id = $1
       GROUP BY r.name`, [a.group.id]);
    const byRole = Object.fromEntries(rows.map((row) => [row.name, row.codes]));
    const all = ['pdv.customer_create', 'pdv.prescriber_create', 'pdv.quote_clear', 'pdv.sale_cancel', 'pdv.self_service_cancel'];
    expect(byRole).toEqual({
      Gerente: all,
      Farmacêutico: all,
      'Operador de caixa': ['pdv.customer_create', 'pdv.prescriber_create', 'pdv.quote_clear'],
      Balconista: ['pdv.customer_create', 'pdv.quote_clear'],
    });
    const has = async (user, code) => (await ownerPool.query('SELECT app.user_has_permission($1, $2, $3) AS ok', [user.id, code, a.branch1.id])).rows[0].ok;
    for (const code of all) expect(await has(a.admin, code)).toBe(true);
    expect(await has(people.cashier, 'pdv.sale_cancel')).toBe(false);
  });
});

describe('venda descartada no PDV', () => {
  it('registra quem estava, quem liberou e a tela; sem alerta quando quem respondeu tinha a permissão', async () => {
    const own = discard();
    expect(await push(a.terminal1, 'cart_discard', own)).toMatchObject({ status: 'applied' });
    expect(await stored(own.id)).toMatchObject({
      economic_group_id: a.group.id, branch_id: a.branch1.id, terminal_id: a.terminal1.id, screen: 'cashier',
      user_id: people.manager.id, authorized_by: null, items_count: 3, total: '45.90', alert: null,
    });
    // O operador não tem "cancelar no caixa": o gerente liberou.
    const released = discard({ user_id: people.cashier.id, authorized_by: people.manager.id });
    expect(await push(a.terminal1, 'cart_discard', released)).toMatchObject({ status: 'applied' });
    expect(await stored(released.id)).toMatchObject({ user_id: people.cashier.id, authorized_by: people.manager.id, alert: null });
    // O balconista limpa o próprio orçamento.
    const quote = discard({ screen: 'quote', user_id: people.clerk.id });
    expect(await push(a.terminal1, 'cart_discard', quote)).toMatchObject({ status: 'applied' });
    expect((await stored(quote.id)).alert).toBeNull();
  });

  it('marca o alerta quando quem respondeu não tinha a permissão da tela (perfil mudou com o caixa sem internet)', async () => {
    const alone = discard({ user_id: people.cashier.id });
    expect(await push(a.terminal1, 'cart_discard', alone)).toMatchObject({ status: 'applied' });
    expect((await stored(alone.id)).alert).toBe('release_permission');
    // Liberado pelo balconista, que não cancela no autoatendimento.
    const byClerk = discard({ screen: 'self_service', user_id: people.cashier.id, authorized_by: people.clerk.id });
    expect(await push(a.terminal1, 'cart_discard', byClerk)).toMatchObject({ status: 'applied' });
    expect((await stored(byClerk.id)).alert).toBe('release_permission');
    // A permissão vale na filial do terminal: na filial 2 o gerente não tem perfil.
    const otherBranch = discard();
    expect(await push(a.terminal2, 'cart_discard', otherBranch)).toMatchObject({ status: 'applied' });
    expect(await stored(otherBranch.id)).toMatchObject({ branch_id: a.branch2.id, alert: 'release_permission' });
  });

  it('recusa formato errado, pessoa de outro grupo e o mesmo descarte com outro registro', async () => {
    for (const bad of [
      discard({ screen: 'kiosk' }),
      discard({ items_count: 0 }),
      discard({ items_count: '3' }),
      discard({ total: -1 }),
      discard({ total: 1.234 }),
      discard({ discarded_at: '2026-11-26 18:00' }),
      discard({ user_id: 'x' }),
      discard({ authorized_by: people.manager.id }),
      discard({ id: '019a0000-0000-4000-8000-000000000001' }),
    ]) {
      expect(await push(a.terminal1, 'cart_discard', bad)).toMatchObject({ status: 'conflict', code: 'FA962' });
    }
    expect(await push(a.terminal1, 'cart_discard', discard({ user_id: b.admin.id }))).toMatchObject({ status: 'conflict', code: 'FA004' });
    expect(await push(a.terminal1, 'cart_discard', discard({ authorized_by: b.admin.id }))).toMatchObject({ status: 'conflict', code: 'FA004' });
    const once = discard();
    expect(await push(a.terminal1, 'cart_discard', once)).toMatchObject({ status: 'applied' });
    expect(await push(a.terminal1, 'cart_discard', once)).toMatchObject({ status: 'conflict', code: 'FA963' });
  });

  it('ninguém altera o registro; a retaguarda vê só o próprio grupo', async () => {
    const one = discard();
    await push(a.terminal1, 'cart_discard', one);
    await expect(ownerPool.query('UPDATE pdv_cart_discard SET total = 1 WHERE id = $1', [one.id])).rejects.toThrow();
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [b.admin.id]);
      expect((await client.query('SELECT count(*)::int AS n FROM v_pdv_cart_discard WHERE id = $1', [one.id])).rows[0].n).toBe(0);
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      expect((await client.query('SELECT count(*)::int AS n FROM v_pdv_cart_discard WHERE id = $1', [one.id])).rows[0].n).toBe(1);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});

describe('cadastros no caixa', () => {
  const create = (terminal, user, data) =>
    asTerminal(terminal, 'SELECT app.pdv_create_customer($1, $2::jsonb) AS r', [user?.id ?? null, JSON.stringify(data)]).then((r) => r[0].r);

  it('cliente: vale "Cadastrar cliente no PDV" (o balconista do orçamento também), não mais só "Vender"', async () => {
    await expect(create(a.terminal1, people.clerk, { name: 'Cliente do Orçamento', document: cpf() })).resolves.toMatchObject({ id: expect.any(String) });
    // Perfil com "Vender" e sem o cadastro.
    const { rows: [role] } = await ownerPool.query(
      'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Só vende ${randomInt(1e6)}`],
    );
    await ownerPool.query("INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'sales.sell'", [role.id]);
    const { rows: [seller] } = await ownerPool.query(
      'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Vendedor ${randomInt(1e6)}`],
    );
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [seller.id, a.branch1.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [seller.id, role.id, a.branch1.id]);
    await expect(create(a.terminal1, seller, { name: 'Cliente Sem Permissão', document: cpf() })).rejects.toSatisfy(hasCode('FA002'));
  });

  it('prescritor: quem cadastrou precisa da permissão na filial; caixa antigo (sem quem cadastrou) segue aceito', async () => {
    const professional = (createdBy) => ({
      id: uuidV7(), name: 'Dra. Fictícia', council: 'CRM', registration: String(randomInt(1e5, 1e6)), state: 'SC',
      ...(createdBy === undefined ? {} : { created_by: createdBy }),
    });
    expect(await push(a.terminal1, 'health_professional', professional(people.cashier.id))).toMatchObject({ status: 'applied' });
    expect(await push(a.terminal1, 'health_professional', professional())).toMatchObject({ status: 'applied' });
    expect(await push(a.terminal1, 'health_professional', professional(people.clerk.id))).toMatchObject({ status: 'conflict', code: 'FA002' });
    expect(await push(a.terminal2, 'health_professional', professional(people.cashier.id))).toMatchObject({ status: 'conflict', code: 'FA002' });
    expect(await push(a.terminal1, 'health_professional', professional(b.admin.id))).toMatchObject({ status: 'conflict', code: 'FA002' });
    expect(await push(a.terminal1, 'health_professional', professional('x'))).toMatchObject({ status: 'conflict', code: 'FA002' });
  });
});
