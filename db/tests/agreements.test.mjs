import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;

function cpf() {
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits) => {
    const rest = (digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0) * 10) % 11;
    return rest === 10 ? 0 : rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}

const customer = async (client, data = {}) =>
  (await client.query('SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
    personType: 'individual', document: cpf(), name: 'Cliente', ...data,
  })])).rows[0].id;
const agreement = async (client, name = `Convênio ${randomInt(1e9)}`, cnpj = null) =>
  (await client.query('SELECT app.create_agreement($1, $2) AS id', [name, cnpj])).rows[0].id;
const link = (client, customerId, agreementId, registration = `M${randomInt(1e9)}`, limit = 500) =>
  client.query('SELECT app.link_customer_agreement($1, $2, $3, $4) AS id', [customerId, agreementId, registration, limit])
    .then((r) => r.rows[0].id);

async function userWith(client, codes, { branches = [], scope = null } = {}) {
  const { rows: [user] } = await client.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [a.group.id, `Usuário ${randomInt(1e9)}`],
  );
  const { rows: [role] } = await client.query(
    'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [a.group.id, `Perfil ${randomInt(1e9)}`],
  );
  await client.query(
    'INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)',
    [role.id, codes],
  );
  for (const branch of branches) {
    await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
  }
  await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, scope?.id ?? null]);
  return user;
}

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('inscrição estadual', () => {
  const valid = (value, state) =>
    ownerPool.query('SELECT app.is_valid_state_registration($1, $2) AS ok', [value, state]).then((r) => r.rows[0].ok);

  it.each([
    ['110042490114', 'SP', true],
    ['11004249011', 'SP', false],
    ['1234567', 'RJ', false],
    ['12345678', 'RJ', true],
    ['12345678', 'BA', true],
    ['123456789', 'BA', true],
    ['1234567890123', 'MG', true],
    ['ISENTO', 'SP', true],
    ['12A456789', 'SC', false],
    ['123456789', 'XX', false],
  ])('%s em %s: %s', async (value, state, expected) => {
    expect(await valid(value, state)).toBe(expected);
  });

  it('o cliente grava com pontuação, isento em qualquer grafia, e exige o estado', async () => {
    await asUser(a.admin.id, async (client) => {
      const company = branchCnpj(randomRoot(), 1);
      const id = await customer(client, { personType: 'company', document: company, state: 'SP', stateRegistration: '110.042.490.114' });
      const { rows } = await client.query('SELECT state_registration FROM v_customer WHERE id = $1', [id]);
      expect(rows[0].state_registration).toBe('110042490114');
      const exempt = await customer(client, { stateRegistration: 'isento', state: 'RS' });
      expect((await client.query('SELECT state_registration FROM v_customer WHERE id = $1', [exempt])).rows[0].state_registration).toBe('ISENTO');
      await client.query('SAVEPOINT s');
      await expect(customer(client, { stateRegistration: '110042490114' })).rejects.toSatisfy(hasCode('FA908'));
      await client.query('ROLLBACK TO s');
      await expect(customer(client, { stateRegistration: '1100424901', state: 'SP' })).rejects.toSatisfy(hasCode('FA908'));
    });
  });

  it('a edição também grava a inscrição', async () => {
    await asUser(a.admin.id, async (client) => {
      const document = cpf();
      const id = await customer(client, { document });
      await client.query('SELECT app.update_customer($1, $2::jsonb)', [id, JSON.stringify({ document, name: 'X', state: 'RJ', stateRegistration: '12345678' })]);
      expect((await client.query('SELECT state_registration FROM v_customer WHERE id = $1', [id])).rows[0].state_registration).toBe('12345678');
    });
  });
});

describe('convênio', () => {
  it('cria, renomeia e não repete o nome no grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await agreement(client, 'Prefeitura');
      await client.query('SELECT app.update_agreement($1, $2, $3)', [id, 'Prefeitura Municipal', null]);
      await agreement(client, 'Outro');
      await expect(agreement(client, 'prefeitura municipal')).rejects.toSatisfy(hasCode('FA215'));
    });
  });

  it('CNPJ do convênio é opcional, mas quando vem precisa ser válido', async () => {
    await asUser(a.admin.id, async (client) => {
      await agreement(client, 'Com CNPJ', branchCnpj(randomRoot(), 1));
      await expect(agreement(client, 'CNPJ ruim', '11111111111111')).rejects.toSatisfy(hasCode('FA902'));
    });
  });

  it('sem nome é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(agreement(client, '  ')).rejects.toSatisfy(hasCode('FA216'));
    });
  });

  it('com cliente vinculado não sai; sem vínculo, sai', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await agreement(client);
      const linkId = await link(client, await customer(client), id);
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.delete_agreement($1)', [id])).rejects.toSatisfy(hasCode('FA105'));
      await client.query('ROLLBACK TO s');
      await client.query('SELECT app.unlink_customer_agreement($1)', [linkId]);
      await client.query('SELECT app.delete_agreement($1)', [id]);
    });
  });
});

describe('vínculo do cliente', () => {
  it('vincula com matrícula e limite, edita e encerra, guardando o histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      const customerId = await customer(client);
      const agreementId = await agreement(client);
      const id = await link(client, customerId, agreementId, 'M-1', 300);
      await client.query('SELECT app.update_customer_agreement($1, $2, $3)', [id, 'M-2', 450.5]);
      const { rows } = await client.query('SELECT registration, credit_limit, version FROM v_customer_agreement WHERE id = $1', [id]);
      expect(rows[0]).toEqual({ registration: 'M-2', credit_limit: '450.50', version: '2' });
      await client.query('SELECT app.unlink_customer_agreement($1)', [id]);
      expect((await client.query('SELECT 1 FROM v_customer_agreement WHERE id = $1', [id])).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM customer_agreement WHERE id = $1', [id])).rows).toHaveLength(1);
    });
  });

  it('um cliente não entra duas vezes no mesmo convênio, nem a matrícula se repete nele', async () => {
    await asUser(a.admin.id, async (client) => {
      const agreementId = await agreement(client);
      const first = await customer(client);
      await link(client, first, agreementId, 'M-9');
      await client.query('SAVEPOINT s');
      await expect(link(client, first, agreementId, 'M-10')).rejects.toSatisfy(hasCode('FA909'));
      await client.query('ROLLBACK TO s');
      await expect(link(client, await customer(client), agreementId, 'm-9')).rejects.toSatisfy(hasCode('FA910'));
    });
  });

  it('a mesma matrícula pode existir em outro convênio', async () => {
    await asUser(a.admin.id, async (client) => {
      await link(client, await customer(client), await agreement(client), 'M-1');
      await link(client, await customer(client), await agreement(client), 'M-1');
    });
  });

  it.each([
    ['limite negativo', 'M-1', -1, 'FA911'],
    ['sem matrícula', ' ', 100, 'FA911'],
  ])('recusa %s', async (_label, registration, limit, code) => {
    await asUser(a.admin.id, async (client) => {
      await expect(link(client, await customer(client), await agreement(client), registration, limit)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('não vincula cliente ou convênio de outro grupo', async () => {
    await asOwner(async (client) => {
      await setUser(client, b.admin.id);
      const otherCustomer = await customer(client);
      const otherAgreement = await agreement(client);
      await setUser(client, a.admin.id);
      const mine = await agreement(client);
      await client.query('SAVEPOINT s');
      await expect(link(client, otherCustomer, mine)).rejects.toSatisfy(hasCode('FA004'));
      await client.query('ROLLBACK TO s');
      await expect(link(client, await customer(client), otherAgreement)).rejects.toSatisfy(hasCode('FA004'));
    });
  });
});

describe('permissões', () => {
  it('a API não escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['agreement', 'customer_agreement']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('o Gerente vê os convênios do cliente, mas não cria nem vincula', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const customerId = await customer(client);
      const agreementId = await agreement(client);
      await link(client, customerId, agreementId);
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
      await setUser(client, manager.id);
      expect((await client.query('SELECT 1 FROM v_customer_agreement WHERE customer_id = $1', [customerId])).rows).toHaveLength(1);
      for (const call of [
        () => agreement(client),
        () => link(client, customerId, agreementId),
      ]) {
        await client.query('SAVEPOINT s');
        await expect(call()).rejects.toSatisfy(hasCode('FA002'));
        await client.query('ROLLBACK TO s');
      }
    });
  });

  it('agreements.manage em uma filial só não basta: o limite é crédito da rede', async () => {
    await asOwner(async (client) => {
      const local = await userWith(client, ['agreements.manage'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, local.id);
      await expect(agreement(client)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('outro grupo não enxerga nem altera', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await agreement(client);
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM v_agreement WHERE id = $1', [id])).rows).toEqual([]);
      await expect(client.query('SELECT app.update_agreement($1, $2, $3)', [id, 'X', null])).rejects.toSatisfy(hasCode('FA006'));
    });
  });

  it('sem permissão de clientes, não enxerga convênio nem vínculo', async () => {
    await asUser(a.admin.id, async (client) => {
      await link(client, await customer(client), await agreement(client));
      await setUser(client, a.noBranchUser.id);
      expect((await client.query('SELECT 1 FROM v_agreement LIMIT 1')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_customer_agreement LIMIT 1')).rows).toEqual([]);
    });
  });
});
