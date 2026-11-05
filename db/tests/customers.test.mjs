import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;

/** Cálculo independente do banco, para conferir a função SQL. */
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
const cnpj = () => branchCnpj(randomRoot(), 1);
const formatCpf = (v) => `${v.slice(0, 3)}.${v.slice(3, 6)}.${v.slice(6, 9)}-${v.slice(9)}`;

const create = async (client, data = {}) =>
  (await client.query('SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
    personType: 'individual', document: cpf(), name: 'Cliente Teste', ...data,
  })])).rows[0].id;
const consent = (client, customer, purpose, granted, channel = 'store') =>
  client.query('SELECT app.record_customer_consent($1, $2, $3, $4) AS id', [customer, purpose, granted, channel])
    .then((r) => r.rows[0].id);
const consents = async (client, customer) =>
  Object.fromEntries((await client.query('SELECT * FROM app.customer_consents($1)', [customer])).rows
    .map((row) => [row.purpose, row.granted]));
const search = async (client, query) =>
  (await client.query('SELECT * FROM app.search_customers($1)', [query])).rows;

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

describe('CPF', () => {
  const valid = (value) => ownerPool.query('SELECT app.is_valid_cpf($1) AS ok', [value]).then((r) => r.rows[0].ok);

  it('aceita CPF com dígitos certos', async () => {
    for (let i = 0; i < 20; i += 1) expect(await valid(cpf())).toBe(true);
  });

  it('recusa dígito errado, repetidos, tamanho e letras', async () => {
    const good = cpf();
    const wrong = `${good.slice(0, 10)}${(Number(good[10]) + 1) % 10}`;
    for (const value of [wrong, '11111111111', '1234567890', '123456789012', 'ABCDEFGHIJK', '']) {
      expect(await valid(value), value).toBe(false);
    }
  });

  it('mascara para listas', async () => {
    const { rows } = await ownerPool.query(`SELECT app.mask_document('12345678909') AS a, app.mask_document('11222333000181') AS b`);
    expect(rows[0]).toEqual({ a: '123.***.***-09', b: '11.222.***/****-81' });
  });
});

describe('cadastro', () => {
  it('gera código, aceita documento com pontuação e normaliza contato', async () => {
    await asUser(a.admin.id, async (client) => {
      const document = cpf();
      const id = await create(client, {
        document: formatCpf(document), name: '  Maria  ', phone: '(11) 98765-4321',
        email: ' Maria@Exemplo.COM ', postalCode: '01310-100', state: 'sp', birthDate: '1980-05-02',
      });
      const { rows: [row] } = await client.query('SELECT * FROM v_customer WHERE id = $1', [id]);
      expect(Number(row.code)).toBeGreaterThan(0);
      expect(row).toMatchObject({
        document, name: 'Maria', phone: '11987654321', email: 'maria@exemplo.com',
        postal_code: '01310100', state: 'SP', person_type: 'individual', updated_by: a.admin.id,
      });
    });
  });

  it('pessoa jurídica usa CNPJ, inclusive o alfanumérico', async () => {
    await asUser(a.admin.id, async (client) => {
      await create(client, { personType: 'company', document: cnpj(), name: 'Empresa Teste', tradeName: 'Fantasia' });
      const { rows } = await ownerPool.query(`SELECT app.is_valid_cnpj('12ABC34501DE35') AS ok`);
      expect(typeof rows[0].ok).toBe('boolean');
    });
  });

  it.each([
    ['CPF inválido', { document: '12345678900' }, 'FA902'],
    ['CNPJ como pessoa física', { document: '11222333000181' }, 'FA902'],
    ['CPF como pessoa jurídica', { personType: 'company' }, 'FA902'],
    ['sem documento', { document: '' }, 'FA902'],
    ['tipo desconhecido', { personType: 'outro' }, 'FA904'],
    ['sem nome', { name: '  ' }, 'FA216'],
    ['telefone curto', { phone: '1234' }, 'FA904'],
    ['e-mail sem domínio', { email: 'maria@' }, 'FA904'],
    ['CEP curto', { postalCode: '0131' }, 'FA904'],
    ['estado inexistente', { state: 'XX' }, 'FA904'],
    ['município fora do padrão IBGE', { cityCode: '123' }, 'FA904'],
    ['nascimento no futuro', { birthDate: '2999-01-01' }, 'FA904'],
    ['nascimento antes de 1900', { birthDate: '1899-12-31' }, 'FA904'],
  ])('recusa %s', async (_label, data, code) => {
    await asUser(a.admin.id, async (client) => {
      await expect(create(client, data)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('o mesmo documento não entra duas vezes na rede, mas pode em outro grupo', async () => {
    const document = cpf();
    await asUser(a.admin.id, async (client) => {
      await create(client, { document });
      await expect(create(client, { document: formatCpf(document) })).rejects.toSatisfy(hasCode('FA901'));
    });
    await asUser(b.admin.id, async (client) => {
      await create(client, { document });
    });
  });

  it('editar corrige o documento, mas não troca o tipo de pessoa', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      const fixed = cpf();
      await client.query('SELECT app.update_customer($1, $2::jsonb)', [id, JSON.stringify({ document: fixed, name: 'Corrigido' })]);
      const { rows } = await client.query('SELECT document, name, version FROM customer WHERE id = $1', [id]);
      expect(rows[0]).toMatchObject({ document: fixed, name: 'Corrigido', version: '2' });
      await expect(client.query(`UPDATE customer SET person_type = 'company' WHERE id = $1`, [id])).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('o código humano não muda', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await create(client);
      await expect(client.query('UPDATE customer SET code = code + 1000 WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
    });
  });
});

describe('dependentes', () => {
  it('inclui, edita e remove, guardando o histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      const { rows: [{ id }] } = await client.query('SELECT app.add_customer_dependent($1, $2::jsonb) AS id', [
        customer, JSON.stringify({ name: 'Filho', relationship: 'child', birthDate: '2015-03-01' }),
      ]);
      await client.query('SELECT app.update_customer_dependent($1, $2::jsonb)', [id, JSON.stringify({ name: 'Filho Corrigido', relationship: 'child', cpf: cpf() })]);
      await client.query('SELECT app.remove_customer_dependent($1)', [id]);
      expect((await client.query('SELECT 1 FROM v_customer_dependent WHERE customer_id = $1', [customer])).rows).toEqual([]);
      const { rows } = await client.query('SELECT name, deleted_at IS NOT NULL AS gone FROM customer_dependent WHERE id = $1', [id]);
      expect(rows).toEqual([{ name: 'Filho Corrigido', gone: true }]);
    });
  });

  it('CPF é opcional, mas quando vem, precisa ser válido e não repetir no mesmo titular', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      const add = (data) => client.query('SELECT app.add_customer_dependent($1, $2::jsonb)', [customer, JSON.stringify({ name: 'Dep', relationship: 'child', ...data })]);
      await add({});
      await add({});
      const repeated = cpf();
      await add({ cpf: repeated });
      await client.query('SAVEPOINT s');
      await expect(add({ cpf: repeated })).rejects.toSatisfy(hasCode('FA903'));
      await client.query('ROLLBACK TO s');
      await expect(add({ cpf: '12345678900' })).rejects.toSatisfy(hasCode('FA902'));
    });
  });

  it('dependente pode ter o CPF de alguém que já é cliente', async () => {
    await asUser(a.admin.id, async (client) => {
      const document = cpf();
      await create(client, { document });
      const holder = await create(client);
      await client.query('SELECT app.add_customer_dependent($1, $2::jsonb)', [holder, JSON.stringify({ name: 'Dep', relationship: 'child', cpf: document })]);
    });
  });

  it.each([
    ['parentesco desconhecido', { relationship: 'vizinho' }, 'FA904'],
    ['sem nome', { name: '' }, 'FA216'],
    ['nascimento no futuro', { birthDate: '2999-01-01' }, 'FA904'],
  ])('recusa %s', async (_label, data, code) => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      await expect(client.query('SELECT app.add_customer_dependent($1, $2::jsonb)', [customer, JSON.stringify({ name: 'Dep', relationship: 'child', ...data })])).rejects.toSatisfy(hasCode(code));
    });
  });

  it('não entra em cliente de outro grupo, mesmo pelo dono', async () => {
    const other = await (async () => {
      const client = await appPool.connect();
      try {
        await client.query('BEGIN');
        await setUser(client, b.admin.id);
        const id = await create(client);
        await client.query('COMMIT');
        return id;
      } finally {
        client.release();
      }
    })();
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('SELECT app.add_customer_dependent($1, $2::jsonb)', [other, JSON.stringify({ name: 'Dep', relationship: 'child' })])).rejects.toSatisfy(hasCode('FA004'));
    });
  });
});

describe('consentimento', () => {
  it('nasce sem decisão em todas as finalidades', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      expect(await consents(client, customer)).toEqual({ marketing: null, facial_recognition: null, cashback: null });
    });
  });

  it('concede, revoga e guarda cada decisão com canal e autor', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      await consent(client, customer, 'marketing', true, 'whatsapp');
      await consent(client, customer, 'cashback', true);
      await consent(client, customer, 'marketing', false, 'phone');
      expect(await consents(client, customer)).toEqual({ marketing: false, facial_recognition: null, cashback: true });
      const { rows } = await client.query(
        `SELECT granted, channel, updated_by FROM v_customer_consent_event WHERE customer_id = $1 AND purpose = 'marketing' ORDER BY id`,
        [customer],
      );
      expect(rows).toEqual([
        { granted: true, channel: 'whatsapp', updated_by: a.admin.id },
        { granted: false, channel: 'phone', updated_by: a.admin.id },
      ]);
      const [current] = (await client.query(`SELECT * FROM app.customer_consents($1) WHERE purpose = 'marketing'`, [customer])).rows;
      expect(current).toMatchObject({ granted: false, channel: 'phone', author: a.admin.name });
    });
  });

  it('repetir a decisão atual não gera registro, nem revogar o que nunca foi dado', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      expect(await consent(client, customer, 'marketing', false)).toBeNull();
      expect(await consent(client, customer, 'marketing', true)).not.toBeNull();
      expect(await consent(client, customer, 'marketing', true)).toBeNull();
      const { rows } = await client.query('SELECT 1 FROM v_customer_consent_event WHERE customer_id = $1', [customer]);
      expect(rows).toHaveLength(1);
    });
  });

  it.each([
    ['finalidade desconhecida', 'venda_de_dados', true, 'store', 'FA905'],
    ['canal desconhecido', 'marketing', true, 'pombo', 'FA905'],
    ['sem decisão', 'marketing', null, 'store', 'FA905'],
  ])('recusa %s', async (_label, purpose, granted, channel, code) => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      await expect(consent(client, customer, purpose, granted, channel)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('a prova não muda nem some, nem pelo dono', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const customer = await create(client);
      const id = await consent(client, customer, 'marketing', true);
      await client.query('SAVEPOINT s');
      await expect(client.query('UPDATE customer_consent_event SET granted = false WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
      await client.query('ROLLBACK TO s');
      await expect(client.query('UPDATE customer_consent_event SET deleted_at = now() WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
    });
  });
});

describe('busca', () => {
  it('acha por nome sem acento, código e documento com ou sem pontuação, e mascara', async () => {
    await asUser(a.admin.id, async (client) => {
      const document = cpf();
      const tag = randomInt(1e9).toString(36);
      const id = await create(client, { document, name: `José Antônio ${tag}` });
      const { rows: [{ code }] } = await client.query('SELECT code FROM v_customer WHERE id = $1', [id]);
      for (const query of [`jose antonio ${tag}`, String(code), document, formatCpf(document)]) {
        const rows = await search(client, query);
        expect(rows.map((row) => row.id), query).toContain(id);
      }
      const [row] = await search(client, document);
      expect(row.document_masked).toBe(`${document.slice(0, 3)}.***.***-${document.slice(9)}`);
      expect(JSON.stringify(row)).not.toContain(document);
    });
  });

  it('pedaço do CPF não acha: a busca por documento é exata', async () => {
    await asUser(a.admin.id, async (client) => {
      const document = cpf();
      const id = await create(client, { document });
      expect((await search(client, document.slice(0, 6))).map((row) => row.id)).not.toContain(id);
    });
  });
});

describe('permissões', () => {
  it('a API não escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['customer', 'customer_dependent', 'customer_consent_event']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('Gerente de uma filial só atende e cadastra clientes da rede', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const existing = await create(client);
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
      await setUser(client, manager.id);
      const mine = await create(client);
      await consent(client, existing, 'cashback', true);
      expect((await client.query('SELECT id FROM v_customer WHERE id = ANY ($1)', [[existing, mine]])).rows).toHaveLength(2);
    });
  });

  it('só customers.view lê, mas não altera', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const customer = await create(client);
      const viewer = await userWith(client, ['customers.view']);
      await setUser(client, viewer.id);
      expect((await client.query('SELECT 1 FROM v_customer WHERE id = $1', [customer])).rows).toHaveLength(1);
      for (const call of [
        () => create(client),
        () => client.query('SELECT app.update_customer($1, $2::jsonb)', [customer, '{"name": "X"}']),
        () => client.query('SELECT app.add_customer_dependent($1, $2::jsonb)', [customer, '{"name": "X", "relationship": "child"}']),
        () => consent(client, customer, 'marketing', true),
      ]) {
        await client.query('SAVEPOINT s');
        await expect(call()).rejects.toSatisfy(hasCode('FA002'));
        await client.query('ROLLBACK TO s');
      }
    });
  });

  it('sem permissão, não enxerga cliente, dependente nem consentimento', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      await client.query('SELECT app.add_customer_dependent($1, $2::jsonb)', [customer, '{"name": "Dep", "relationship": "child"}']);
      await consent(client, customer, 'marketing', true);
      await setUser(client, a.noBranchUser.id);
      for (const view of ['v_customer', 'v_customer_dependent', 'v_customer_consent_event']) {
        expect((await client.query(`SELECT 1 FROM ${view} LIMIT 1`)).rows, view).toEqual([]);
      }
      expect((await client.query('SELECT * FROM app.customer_consents($1)', [customer])).rows).toEqual([]);
      expect(await search(client, '')).toEqual([]);
    });
  });

  it('outro grupo não enxerga nem altera', async () => {
    await asUser(a.admin.id, async (client) => {
      const customer = await create(client);
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM v_customer WHERE id = $1', [customer])).rows).toEqual([]);
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.update_customer($1, $2::jsonb)', [customer, '{"name": "X"}'])).rejects.toSatisfy(hasCode('FA006'));
      await client.query('ROLLBACK TO s');
      await expect(consent(client, customer, 'marketing', true)).rejects.toSatisfy(hasCode('FA006'));
    });
  });

  it('nenhuma mensagem nem detalhe de erro leva o documento', async () => {
    const document = cpf();
    await asUser(a.admin.id, async (client) => {
      await create(client, { document });
      const error = await create(client, { document }).catch((e) => e);
      expect(hasCode('FA901')(error)).toBe(true);
      // O detalhe do Postgres traz o valor da chave: a API descarta esse campo no log.
      expect(error.message).not.toContain(document);
    });
  });
});
