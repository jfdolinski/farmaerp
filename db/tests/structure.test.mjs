import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const DAY = 24 * 60 * 60 * 1000;
const newCompany = (client, cnpj = branchCnpj(randomRoot(), 1), branch = null, legal = 'Empresa Nova Ltda', trade = 'Empresa Nova') =>
  client.query('SELECT app.create_company($1, $2, $3, $4::jsonb) AS result', [cnpj, legal, trade, branch && JSON.stringify(branch)])
    .then((r) => r.rows[0].result);
const newBranch = (client, companyId, data) =>
  client.query('SELECT app.create_branch($1, $2::jsonb) AS id', [companyId, JSON.stringify(data)]).then((r) => r.rows[0].id);
const updateBranch = (client, id, data) =>
  client.query('SELECT app.update_branch($1, $2::jsonb) AS result', [id, JSON.stringify(data)]).then((r) => r.rows[0].result);
const move = (client, id, companyId) =>
  client.query('SELECT app.move_branch($1, $2) AS result', [id, companyId]).then((r) => r.rows[0].result);
const remove = (client, id) => client.query('SELECT app.delete_branch($1)', [id]);
const certificate = (client, branch, cnpj) =>
  client.query('SELECT app.set_branch_certificate($1, $2::jsonb, $3, $4) AS id', [branch.id, JSON.stringify({
    subjectName: `EMPRESA:${cnpj}`,
    cnpj,
    validFrom: new Date(Date.now() - DAY).toISOString(),
    validTo: new Date(Date.now() + 200 * DAY).toISOString(),
    fingerprint: createHash('sha256').update(randomBytes(16)).digest('hex'),
  }), randomBytes(64), randomBytes(32)]);
const activeCertificates = (client, id) =>
  client.query('SELECT count(*)::int AS n FROM branch_certificate WHERE branch_id = $1 AND deleted_at IS NULL', [id]).then((r) => r.rows[0].n);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

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

describe('empresa', () => {
  it('cria com a raiz do CNPJ, sem pontuação e sem filial', async () => {
    await asUser(a.admin.id, async (client) => {
      const root = randomRoot();
      const cnpj = branchCnpj(root, 1);
      const masked = `${cnpj.slice(0, 2)}.${cnpj.slice(2, 5)}.${cnpj.slice(5, 8)}/${cnpj.slice(8, 12)}-${cnpj.slice(12)}`;
      const result = await newCompany(client, masked);
      expect(result.branchId).toBeNull();
      const { rows } = await client.query('SELECT cnpj_root, economic_group_id FROM v_company WHERE id = $1', [result.id]);
      expect(rows[0]).toEqual({ cnpj_root: root, economic_group_id: a.group.id });
    });
  });

  it('cria junto a primeira filial, com o mesmo CNPJ', async () => {
    await asUser(a.admin.id, async (client) => {
      const cnpj = branchCnpj(randomRoot(), 1);
      const result = await newCompany(client, cnpj, { name: 'Matriz', state: 'SP', postalCode: '01310-100' });
      const { rows } = await client.query('SELECT company_id, cnpj, name, state, postal_code FROM v_branch WHERE id = $1', [result.branchId]);
      expect(rows[0]).toEqual({ company_id: result.id, cnpj, name: 'Matriz', state: 'SP', postal_code: '01310100' });
    });
  });

  it('se a filial falha, a empresa não fica', async () => {
    await asUser(a.admin.id, async (client) => {
      const cnpj = branchCnpj(randomRoot(), 1);
      await expectCode(client, () => newCompany(client, cnpj, { name: ' ' }), 'FA216');
      const { rows } = await client.query('SELECT 1 FROM v_company WHERE cnpj_root = $1', [cnpj.slice(0, 8)]);
      expect(rows).toEqual([]);
    });
  });

  it.each([
    ['CNPJ inválido', () => '11111111111111', 'Nome', 'Nome', 'FA211'],
    ['CNPJ vazio', () => '', 'Nome', 'Nome', 'FA211'],
    ['CNPJ nulo', () => null, 'Nome', 'Nome', 'FA211'],
    ['sem razão social', () => branchCnpj(randomRoot(), 1), ' ', 'Nome', 'FA216'],
    ['sem nome fantasia', () => branchCnpj(randomRoot(), 1), 'Nome', null, 'FA216'],
    ['raiz repetida', () => branchCnpj(a.root, 77), 'Nome', 'Nome', 'FA213'],
  ])('recusa %s', async (_label, cnpj, legal, trade, code) => {
    await asUser(a.admin.id, async (client) => {
      await expect(newCompany(client, cnpj(), null, legal, trade)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('edita os nomes, e a raiz continua a mesma', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await newCompany(client);
      await client.query('SELECT app.update_company($1, $2, $3)', [id, 'Razão Editada', 'Fantasia Editada']);
      const { rows } = await client.query('SELECT legal_name, trade_name FROM v_company WHERE id = $1', [id]);
      expect(rows[0]).toEqual({ legal_name: 'Razão Editada', trade_name: 'Fantasia Editada' });
    });
  });

  it('com filial ativa não encerra; sem filial, encerra e libera a raiz', async () => {
    await asUser(a.admin.id, async (client) => {
      const cnpj = branchCnpj(randomRoot(), 1);
      const { id, branchId } = await newCompany(client, cnpj, { name: 'Matriz' });
      await expectCode(client, () => client.query('SELECT app.delete_company($1)', [id]), 'FA105');
      await remove(client, branchId);
      await client.query('SELECT app.delete_company($1)', [id]);
      expect((await client.query('SELECT 1 FROM v_company WHERE id = $1', [id])).rows).toEqual([]);
      await newCompany(client, cnpj);
    });
  });
});

describe('filial', () => {
  it('aceita CNPJ de outra raiz e recusa CNPJ repetido', async () => {
    await asUser(a.admin.id, async (client) => {
      const cnpj = branchCnpj(randomRoot(), 1);
      await newBranch(client, a.company.id, { name: 'Outra raiz', cnpj });
      await expectCode(client, () => newBranch(client, a.company.id, { name: 'Repetida', cnpj }), 'FA212');
      await expectCode(client, () => newBranch(client, a.company.id, { name: 'Ruim', cnpj: '11111111111111' }), 'FA211');
    });
  });

  it('cria os status de produto da filial nova', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const { rows: [product] } = await client.query(
        `INSERT INTO product (economic_group_id, display_name) VALUES ($1, 'Produto') RETURNING id`, [a.group.id],
      );
      const id = await newBranch(client, a.company.id, { name: 'Nova', cnpj: branchCnpj(a.root, 80) });
      const { rows } = await client.query('SELECT 1 FROM product_branch_status WHERE branch_id = $1 AND product_id = $2', [id, product.id]);
      expect(rows).toHaveLength(1);
    });
  });

  it.each([
    ['CEP curto', { postalCode: '123' }, 'FA223'],
    ['código IBGE curto', { cityCode: '123' }, 'FA223'],
    ['telefone curto', { phone: '123' }, 'FA223'],
    ['rua longa demais', { street: 'x'.repeat(151) }, 'FA223'],
    ['número longo demais', { streetNumber: 'x'.repeat(21) }, 'FA223'],
    ['complemento longo demais', { complement: 'x'.repeat(101) }, 'FA223'],
    ['bairro longo demais', { district: 'x'.repeat(101) }, 'FA223'],
    ['cidade longa demais', { city: 'x'.repeat(101) }, 'FA223'],
    ['sem nome', { name: ' ' }, 'FA216'],
  ])('recusa %s', async (_label, data, code) => {
    await asUser(a.admin.id, async (client) => {
      await expect(newBranch(client, a.company.id, { name: 'X', cnpj: branchCnpj(a.root, 81), ...data })).rejects.toSatisfy(hasCode(code));
    });
  });

  it('edita tudo e guarda o endereço limpo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await newBranch(client, a.company.id, { name: 'Antes', cnpj: branchCnpj(a.root, 82) });
      const result = await updateBranch(client, id, {
        name: 'Depois', cnpj: branchCnpj(a.root, 82), state: 'RJ', pmcRegion: '', postalCode: '20040-020',
        street: ' Rua A ', streetNumber: '10', complement: '', district: 'Centro', city: 'Rio', cityCode: '3304557', phone: '(21) 3333-4444',
      });
      expect(result.certificateEnded).toBe(false);
      const { rows } = await client.query(
        'SELECT name, state, pmc_region, postal_code, street, complement, city_code, phone FROM v_branch WHERE id = $1', [id],
      );
      expect(rows[0]).toEqual({
        name: 'Depois', state: 'RJ', pmc_region: null, postal_code: '20040020', street: 'Rua A', complement: null, city_code: '3304557', phone: '2133334444',
      });
    });
  });

  it('não muda de estado deixando a inscrição estadual incoerente', async () => {
    await asUser(a.admin.id, async (client) => {
      const cnpj = branchCnpj(a.root, 83);
      const id = await newBranch(client, a.company.id, { name: 'IE', cnpj, state: 'SP' });
      await client.query('SELECT app.set_branch_state_registration($1, $2)', [id, '110042490114']);
      await expect(updateBranch(client, id, { name: 'IE', cnpj, state: 'RJ' })).rejects.toSatisfy(hasCode('FA908'));
    });
  });

  it('troca de CNPJ na mesma raiz mantém o certificado; em outra raiz encerra e avisa', async () => {
    await asUser(a.admin.id, async (client) => {
      const cnpj = branchCnpj(a.root, 84);
      const id = await newBranch(client, a.company.id, { name: 'Certificada', cnpj });
      await certificate(client, { id }, cnpj);
      const same = await updateBranch(client, id, { name: 'Certificada', cnpj: branchCnpj(a.root, 85) });
      expect(same.certificateEnded).toBe(false);
      expect(await activeCertificates(client, id)).toBe(1);
      const other = await updateBranch(client, id, { name: 'Certificada', cnpj: branchCnpj(randomRoot(), 1) });
      expect(other.certificateEnded).toBe(true);
      expect(await activeCertificates(client, id)).toBe(0);
    });
  });
});

describe('mover filial de empresa', () => {
  it('muda a empresa, guarda o histórico, encerra o certificado e mantém o CSC', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id: target } = await newCompany(client);
      const cnpj = branchCnpj(a.root, 86);
      const id = await newBranch(client, a.company.id, { name: 'Viajante', cnpj });
      await certificate(client, { id }, cnpj);
      await client.query('SELECT app.set_branch_csc($1, $2, $3)', [id, '1', randomBytes(32)]);

      expect(await move(client, id, target)).toEqual({ moved: true, certificateEnded: true });

      expect((await client.query('SELECT company_id FROM v_branch WHERE id = $1', [id])).rows[0].company_id).toBe(target);
      expect(await activeCertificates(client, id)).toBe(0);
      expect((await client.query('SELECT csc_id FROM v_branch_csc WHERE branch_id = $1', [id])).rows).toEqual([{ csc_id: '1' }]);
      const { rows } = await client.query('SELECT from_company_id, to_company_id FROM v_branch_company_event WHERE branch_id = $1', [id]);
      expect(rows).toEqual([{ from_company_id: a.company.id, to_company_id: target }]);
    });
  });

  it('para a mesma empresa não faz nada', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await newBranch(client, a.company.id, { name: 'Parada', cnpj: branchCnpj(a.root, 87) });
      expect(await move(client, id, a.company.id)).toEqual({ moved: false, certificateEnded: false });
      expect((await client.query('SELECT 1 FROM v_branch_company_event WHERE branch_id = $1', [id])).rows).toEqual([]);
    });
  });

  it('não move para outro grupo nem para empresa encerrada', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await newBranch(client, a.company.id, { name: 'Presa', cnpj: branchCnpj(a.root, 88) });
      await expectCode(client, () => move(client, id, b.company.id), 'FA204');
      const { id: closed } = await newCompany(client);
      await client.query('SELECT app.delete_company($1)', [closed]);
      await expectCode(client, () => move(client, id, closed), 'FA204');
    });
  });

  it('não move filial de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(move(client, b.branch1.id, a.company.id)).rejects.toSatisfy(hasCode('FA006'));
    });
  });

  it('sem passar pela função, a empresa continua imutável, mesmo para o dono das tabelas', async () => {
    await asOwner(async (client) => {
      const { rows: [other] } = await client.query(
        `INSERT INTO company (economic_group_id, legal_name, trade_name, cnpj_root) VALUES ($1, 'X', 'X', $2) RETURNING id`,
        [a.group.id, randomRoot()],
      );
      await expect(client.query('UPDATE branch SET company_id = $2 WHERE id = $1', [a.branch1.id, other.id])).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('o registro de outra transação não libera a troca', async () => {
    const client = await ownerPool.connect();
    const root = randomRoot();
    try {
      const { rows: [target] } = await client.query(
        `INSERT INTO company (economic_group_id, legal_name, trade_name, cnpj_root) VALUES ($1, 'Evento', 'Evento', $2) RETURNING id`,
        [b.group.id, root],
      );
      await client.query(
        'INSERT INTO branch_company_event (economic_group_id, branch_id, from_company_id, to_company_id) VALUES ($1, $2, $3, $4)',
        [b.group.id, b.branch2.id, b.company.id, target.id],
      );
      await expect(client.query('UPDATE branch SET company_id = $2 WHERE id = $1', [b.branch2.id, target.id])).rejects.toSatisfy(hasCode('FA104'));
    } finally {
      client.release();
    }
  });

  it('a API não escreve direto no histórico', async () => {
    const { rows } = await ownerPool.query(
      `SELECT has_table_privilege('farmaerp_app', 'branch_company_event', 'INSERT') AS ins,
              has_table_privilege('farmaerp_app', 'branch_company_event', 'UPDATE') AS upd`,
    );
    expect(rows[0]).toEqual({ ins: false, upd: false });
  });
});

describe('encerrar filial', () => {
  it('com terminal em uso não encerra', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(remove(client, a.branch1.id)).rejects.toSatisfy(hasCode('FA224'));
    });
  });

  it('com saldo em estoque não encerra', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await newBranch(client, a.company.id, { name: 'Com saldo', cnpj: branchCnpj(a.root, 89) });
      const { rows: [product] } = await client.query(
        `INSERT INTO product (economic_group_id, display_name) VALUES ($1, 'Produto') RETURNING id`, [a.group.id],
      );
      await client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, reason)
         VALUES ($1, $2, $3, 'adjustment', 1, 'Teste')`,
        [a.group.id, id, product.id],
      );
      await expect(remove(client, id)).rejects.toSatisfy(hasCode('FA224'));
    });
  });

  it('sem terminal e sem saldo encerra, levando vínculos, certificado e CSC', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const cnpj = branchCnpj(a.root, 90);
      const id = await newBranch(client, a.company.id, { name: 'Vazia', cnpj });
      const linked = await userWith(client, ['products.view'], { branches: [{ id }] });
      await certificate(client, { id }, cnpj);
      await client.query('SELECT app.set_branch_csc($1, $2, $3)', [id, '1', randomBytes(32)]);

      await remove(client, id);

      expect((await client.query('SELECT 1 FROM v_branch WHERE id = $1', [id])).rows).toEqual([]);
      expect((await client.query('SELECT deleted_at FROM branch WHERE id = $1', [id])).rows[0].deleted_at).not.toBeNull();
      expect((await client.query('SELECT 1 FROM user_branch WHERE user_id = $1 AND deleted_at IS NULL', [linked.id])).rows).toEqual([]);
      expect(await activeCertificates(client, id)).toBe(0);
      expect((await client.query('SELECT 1 FROM branch_csc WHERE branch_id = $1 AND deleted_at IS NULL', [id])).rows).toEqual([]);
      // O CNPJ fica livre para outro cadastro.
      await newBranch(client, a.company.id, { name: 'Vazia', cnpj });
    });
  });

  it('terminal revogado não impede', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await newBranch(client, a.company.id, { name: 'Revogada', cnpj: branchCnpj(a.root, 91) });
      await client.query(
        `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, 'Caixa', 'cashier', 'revoked', $2)`,
        [id, `chave-${randomInt(1e9)}`],
      );
      await remove(client, id);
      expect((await client.query('SELECT 1 FROM v_branch WHERE id = $1', [id])).rows).toEqual([]);
    });
  });
});

describe('quem altera', () => {
  const CALLS = [
    ['criar empresa', (client) => newCompany(client)],
    ['editar empresa', (client) => client.query('SELECT app.update_company($1, $2, $3)', [a.company.id, 'X', 'X'])],
    ['encerrar empresa', (client) => client.query('SELECT app.delete_company($1)', [a.company.id])],
    ['criar filial', (client) => newBranch(client, a.company.id, { name: 'X', cnpj: branchCnpj(a.root, 92) })],
    ['editar filial', (client) => updateBranch(client, a.branch1.id, { name: 'X', cnpj: a.branch1.cnpj })],
    ['mover filial', (client) => move(client, a.branch1.id, a.company.id)],
    ['encerrar filial', (client) => remove(client, a.branch1.id)],
  ];

  it.each(CALLS)('Gerente não pode %s', async (_label, call) => {
    await asOwner(async (client) => {
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
      await setUser(client, manager.id);
      await expect(call(client)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it.each(CALLS)('structure.manage em uma filial só não basta para %s', async (_label, call) => {
    await asOwner(async (client) => {
      const local = await userWith(client, ['structure.manage'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, local.id);
      await expect(call(client)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('structure.manage no grupo todo pode', async () => {
    await asOwner(async (client) => {
      const manager = await userWith(client, ['structure.manage']);
      await setUser(client, manager.id);
      const { id } = await newCompany(client);
      await newBranch(client, id, { name: 'Filial', cnpj: branchCnpj(randomRoot(), 1) });
    });
  });

  it('outro grupo não enxerga nem altera', async () => {
    await asUser(a.admin.id, async (client) => {
      const { id } = await newCompany(client);
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM v_company WHERE id = $1', [id])).rows).toEqual([]);
      for (const [call, code] of [
        [() => client.query('SELECT app.update_company($1, $2, $3)', [id, 'X', 'X']), 'FA006'],
        [() => client.query('SELECT app.delete_company($1)', [id]), 'FA006'],
        [() => newBranch(client, id, { name: 'X', cnpj: branchCnpj(randomRoot(), 1) }), 'FA204'],
        [() => updateBranch(client, a.branch1.id, { name: 'X', cnpj: a.branch1.cnpj }), 'FA006'],
        [() => remove(client, a.branch1.id), 'FA006'],
      ]) {
        await expectCode(client, call, code);
      }
    });
  });
});
