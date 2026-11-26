import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal } from './helpers.mjs';

// Cadastro de cliente na tela de vendas do PDV (com internet).

let a;
let b;
let cashier;

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
const create = (terminal, operator, data) =>
  asTerminal(terminal, 'SELECT app.pdv_create_customer($1, $2::jsonb) AS r', [operator?.id ?? null, JSON.stringify(data)])
    .then((r) => r[0].r);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows: [user] } = await ownerPool.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Operador ${randomInt(1e6)}`],
  );
  const { rows: [role] } = await ownerPool.query("SELECT * FROM role WHERE economic_group_id = $1 AND name = 'Operador de caixa'", [a.group.id]);
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  cashier = user;
});
afterAll(closePools);

describe('cliente cadastrado no caixa', () => {
  it('o operador que vende na filial cadastra; o cliente já fica guardado no terminal, com os consentimentos marcados', async () => {
    const document = cpf();
    const result = await create(a.terminal1, cashier, {
      name: '  Maria  Fictícia ', document: `${document.slice(0, 3)}.${document.slice(3, 6)}.${document.slice(6, 9)}-${document.slice(9)}`,
      phone: '(11) 98888-7777', birthDate: '1990-05-20', consents: { cashback: true, marketing: false },
    });
    expect(result.data).toMatchObject({ name: 'Maria  Fictícia', document });
    const row = (await ownerPool.query('SELECT * FROM customer WHERE id = $1', [result.id])).rows[0];
    expect(row).toMatchObject({ economic_group_id: a.group.id, person_type: 'individual', document, phone: '11988887777' });
    expect((await ownerPool.query('SELECT purpose, granted, channel FROM customer_consent_event WHERE customer_id = $1', [result.id])).rows)
      .toEqual([{ purpose: 'cashback', granted: true, channel: 'store' }]);
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM pdv_customer_cache WHERE customer_id = $1 AND terminal_id = $2', [result.id, a.terminal1.id])).rows[0].n)
      .toBe(1);

    // CPF repetido no grupo: FA901. Em outro grupo, pode.
    await expect(create(a.terminal2, a.admin, { name: 'Outra Pessoa', document })).rejects.toSatisfy(hasCode('FA901'));
    await expect(create(b.terminal1, b.admin, { name: 'Outra Pessoa', document })).resolves.toMatchObject({ id: expect.any(String) });
  });

  it('recusa operador sem permissão na filial, de outro grupo ou ausente; e dados inválidos', async () => {
    // O operador vende só na filial 1: no terminal da filial 2, não.
    await expect(create(a.terminal2, cashier, { name: 'Cliente Sem Permissão', document: cpf() })).rejects.toSatisfy(hasCode('FA002'));
    await expect(create(a.terminal1, b.admin, { name: 'Cliente Outro Grupo', document: cpf() })).rejects.toSatisfy(hasCode('FA002'));
    await expect(create(a.terminal1, null, { name: 'Cliente Sem Operador', document: cpf() })).rejects.toSatisfy(hasCode('FA002'));
    await ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.secondAdmin.id]);
    await expect(create(a.terminal1, a.secondAdmin, { name: 'Cliente Inativo', document: cpf() })).rejects.toSatisfy(hasCode('FA002'));

    await expect(create(a.terminal1, cashier, { name: 'Jo', document: cpf() })).rejects.toSatisfy(hasCode('FA904'));
    await expect(create(a.terminal1, cashier, { name: '   ', document: cpf() })).rejects.toSatisfy(hasCode('FA904'));
    await expect(create(a.terminal1, cashier, { name: 'Cliente CPF Errado', document: '12345678900' })).rejects.toSatisfy(hasCode('FA902'));
    await expect(create(a.terminal1, cashier, { name: 'Cliente Sem CPF' })).rejects.toSatisfy(hasCode('FA902'));
    await expect(create(a.terminal1, cashier, { name: 'Cliente Fone Curto', document: cpf(), phone: '1234' })).rejects.toSatisfy(hasCode('FA904'));
    await expect(create(a.terminal1, cashier, { name: 'Cliente Nascido Antes', document: cpf(), birthDate: '1800-01-01' })).rejects.toSatisfy(hasCode('FA904'));
    await expect(asTerminal(a.terminal1, 'SELECT app.pdv_create_customer($1, $2::jsonb)', [cashier.id, '[]'])).rejects.toSatisfy(hasCode('FA904'));
  });

  it('sem terminal, não cadastra', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await expect(client.query('SELECT app.pdv_create_customer($1, $2::jsonb)', [cashier.id, JSON.stringify({ name: 'Cliente Teste', document: cpf() })]))
        .rejects.toSatisfy(hasCode('FA306'));
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
