import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  // Inscrição estadual depende do estado da filial.
  await ownerPool.query("UPDATE branch SET state = 'SP' WHERE id = ANY ($1)", [[a.branch1.id, a.branch2.id, b.branch1.id]]);
});
afterAll(closePools);

const DAY = 24 * 60 * 60 * 1000;

/** Dados que a API lê do arquivo .pfx; aqui são montados à mão. */
const meta = (fixture, { cnpj = branchCnpj(fixture.root, 1), validTo = new Date(Date.now() + 200 * DAY) } = {}) => ({
  subjectName: `EMPRESA ${fixture.root}:${cnpj}`,
  cnpj,
  validFrom: new Date(Date.now() - DAY).toISOString(),
  validTo: validTo.toISOString(),
  fingerprint: createHash('sha256').update(randomBytes(16)).digest('hex'),
});
const setCertificate = (client, branch, data) =>
  client.query('SELECT app.set_branch_certificate($1, $2::jsonb, $3, $4) AS id', [
    branch.id, JSON.stringify(data), randomBytes(64), randomBytes(32),
  ]).then((r) => r.rows[0].id);
const setCsc = (client, branch, id = '000001') =>
  client.query('SELECT app.set_branch_csc($1, $2, $3) AS id', [branch.id, id, randomBytes(48)]).then((r) => r.rows[0].id);

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

const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('regime tributário', () => {
  it('grava o regime da empresa e recusa código fora da lista', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SELECT app.set_company_tax_regime($1, $2::smallint)', [a.company.id, 1]);
      expect((await client.query('SELECT tax_regime FROM v_company WHERE id = $1', [a.company.id])).rows[0].tax_regime).toBe(1);
      await expectCode(client, () => client.query('SELECT app.set_company_tax_regime($1, $2::smallint)', [a.company.id, 5]), 'FA917');
      await expectCode(client, () => client.query('SELECT app.set_company_tax_regime($1, NULL::smallint)', [a.company.id]), 'FA917');
    });
  });

  it('não altera empresa de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('SELECT app.set_company_tax_regime($1, $2::smallint)', [b.company.id, 3])).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('inscrição estadual da filial', () => {
  it('grava sem pontuação e confere os dígitos com o estado da filial', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SELECT app.set_branch_state_registration($1, $2)', [a.branch1.id, '110.042.490.114']);
      expect((await client.query('SELECT state_registration FROM v_branch WHERE id = $1', [a.branch1.id])).rows[0].state_registration).toBe('110042490114');
      await expectCode(client, () => client.query('SELECT app.set_branch_state_registration($1, $2)', [a.branch1.id, '110.042.490.115']), 'FA908');
      await expectCode(client, () => client.query('SELECT app.set_branch_state_registration($1, $2)', [a.branch1.id, '99.999.99-3']), 'FA908');
    });
  });

  it('filial sem estado não aceita inscrição', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('SELECT app.set_branch_state_registration($1, $2)', [a.branchFree.id, '110042490114'])).rejects.toSatisfy(hasCode('FA908'));
    });
  });

  it('não altera filial de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('SELECT app.set_branch_state_registration($1, $2)', [b.branch1.id, '110042490114'])).rejects.toSatisfy(hasCode('FA006'));
    });
  });
});

describe('certificado A1', () => {
  it('troca o certificado guardando o anterior como histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await setCertificate(client, a.branch1, meta(a));
      const second = await setCertificate(client, a.branch1, meta(a));
      const { rows } = await client.query('SELECT id FROM v_branch_certificate WHERE branch_id = $1', [a.branch1.id]);
      expect(rows.map((r) => r.id)).toEqual([second]);
      expect((await client.query('SELECT deleted_at FROM branch_certificate WHERE id = $1', [first])).rows[0].deleted_at).not.toBeNull();
    });
  });

  it('aceita certificado de outra filial da mesma empresa (mesma raiz de CNPJ)', async () => {
    await asUser(a.admin.id, async (client) => {
      await setCertificate(client, a.branch2, meta(a, { cnpj: branchCnpj(a.root, 1) }));
    });
  });

  it('recusa certificado de outra empresa e certificado vencido', async () => {
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => setCertificate(client, a.branch1, meta(a, { cnpj: branchCnpj(randomRoot(), 1) })), 'FA913');
      await expectCode(client, () => setCertificate(client, a.branch1, meta(a, { validTo: new Date(Date.now() - DAY) })), 'FA914');
    });
  });

  it('recusa dados de exibição inválidos', async () => {
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => setCertificate(client, a.branch1, { ...meta(a), fingerprint: 'abc' }), 'FA912');
      await expectCode(client, () => setCertificate(client, a.branch1, { ...meta(a), subjectName: ' ' }), 'FA912');
    });
  });

  it('o conteúdo da linha não muda; trocar é encerrar e incluir', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const id = await setCertificate(client, a.branch1, meta(a));
      await expect(client.query('UPDATE branch_certificate SET subject_name = $2 WHERE id = $1', [id, 'Outro'])).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('copia o certificado para outras filiais da empresa, sem repetir a origem', async () => {
    await asUser(a.admin.id, async (client) => {
      const data = meta(a);
      await setCertificate(client, a.branch1, data);
      const { rows: [{ copied }] } = await client.query(
        'SELECT app.copy_branch_certificate($1, $2) AS copied',
        [a.branch1.id, [a.branch1.id, a.branch2.id, a.branchFree.id, a.branch2.id]],
      );
      expect(copied).toBe(2);
      const { rows } = await client.query(
        'SELECT branch_id, fingerprint FROM v_branch_certificate WHERE branch_id = ANY ($1)',
        [[a.branch2.id, a.branchFree.id]],
      );
      expect(rows.map((r) => r.fingerprint)).toEqual([data.fingerprint, data.fingerprint]);
    });
  });

  it('não copia para filial de outro grupo nem de filial sem certificado', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      await setCertificate(client, a.branch1, meta(a));
      await expectCode(client, () => client.query('SELECT app.copy_branch_certificate($1, $2)', [a.branch1.id, [b.branch1.id]]), 'FA006');
      await client.query('UPDATE branch_certificate SET deleted_at = now() WHERE branch_id = $1 AND deleted_at IS NULL', [a.branchFree.id]);
      await expectCode(client, () => client.query('SELECT app.copy_branch_certificate($1, $2)', [a.branchFree.id, [a.branch1.id]]), 'FA006');
    });
  });

  it('não copia para outra empresa do mesmo grupo', async () => {
    await asOwner(async (client) => {
      const root = randomRoot();
      const { rows: [company] } = await client.query(
        'INSERT INTO company (economic_group_id, legal_name, trade_name, cnpj_root) VALUES ($1, $2, $3, $4) RETURNING id',
        [a.group.id, 'Outra Ltda', 'Outra', root],
      );
      const { rows: [other] } = await client.query(
        'INSERT INTO branch (company_id, name, cnpj) VALUES ($1, $2, $3) RETURNING id',
        [company.id, `Outra filial ${root}`, branchCnpj(root, 1)],
      );
      await setUser(client, a.admin.id);
      await setCertificate(client, a.branch1, meta(a));
      await expect(client.query('SELECT app.copy_branch_certificate($1, $2)', [a.branch1.id, [other.id]])).rejects.toSatisfy(hasCode('FA913'));
    });
  });
});

describe('CSC da NFC-e', () => {
  it('troca o CSC guardando o anterior', async () => {
    await asUser(a.admin.id, async (client) => {
      await setCsc(client, a.branch1, '1');
      await setCsc(client, a.branch1, ' 000002 ');
      const { rows } = await client.query('SELECT csc_id FROM v_branch_csc WHERE branch_id = $1', [a.branch1.id]);
      expect(rows).toEqual([{ csc_id: '000002' }]);
    });
  });

  it.each([['vazio', ''], ['com letra', '00A001'], ['longo demais', '1234567'], ['nulo', null]])('recusa identificador %s', async (_label, id) => {
    await asUser(a.admin.id, async (client) => {
      await expect(setCsc(client, a.branch1, id)).rejects.toSatisfy(hasCode('FA916'));
    });
  });
});

describe('quem lê e quem altera', () => {
  it('a API não lê o conteúdo criptografado nem escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT has_column_privilege('farmaerp_app', 'branch_certificate', 'encrypted_pfx', 'SELECT') AS pfx,
             has_column_privilege('farmaerp_app', 'branch_certificate', 'encrypted_password', 'SELECT') AS pass,
             has_column_privilege('farmaerp_app', 'branch_csc', 'encrypted_token', 'SELECT') AS token,
             has_column_privilege('farmaerp_app', 'branch_certificate', 'subject_name', 'SELECT') AS subject,
             has_table_privilege('farmaerp_app', 'branch_certificate', 'INSERT') AS ins_cert,
             has_table_privilege('farmaerp_app', 'branch_csc', 'UPDATE') AS upd_csc`);
    expect(rows[0]).toEqual({ pfx: false, pass: false, token: false, subject: true, ins_cert: false, upd_csc: false });
  });

  it('o Gerente atualiza certificado e CSC da própria loja, mas não regime nem inscrição', async () => {
    await asOwner(async (client) => {
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
      await setUser(client, manager.id);
      await setCertificate(client, a.branch1, meta(a));
      await setCsc(client, a.branch1);
      await expectCode(client, () => setCertificate(client, a.branch2, meta(a)), 'FA002');
      await expectCode(client, () => client.query('SELECT app.set_branch_state_registration($1, $2)', [a.branch1.id, '110042490114']), 'FA002');
      await expectCode(client, () => client.query('SELECT app.set_company_tax_regime($1, $2::smallint)', [a.company.id, 1]), 'FA002');
      // Copiar exige a permissão também no destino.
      await expectCode(client, () => client.query('SELECT app.copy_branch_certificate($1, $2)', [a.branch1.id, [a.branch2.id]]), 'FA002');
    });
  });

  it('fiscal.manage numa filial só não basta para o regime, que vale para a empresa toda', async () => {
    await asOwner(async (client) => {
      const local = await userWith(client, ['fiscal.manage'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, local.id);
      await client.query('SELECT app.set_branch_state_registration($1, $2)', [a.branch1.id, '110042490114']);
      await expectCode(client, () => client.query('SELECT app.set_company_tax_regime($1, $2::smallint)', [a.company.id, 1]), 'FA002');
    });
  });

  it('o resumo fiscal mostra só as filiais permitidas, com dias até o vencimento', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      await setCertificate(client, a.branch1, meta(a, { validTo: new Date(Date.now() + 30.5 * DAY) }));
      const viewer = await userWith(client, ['fiscal.view'], { branches: [a.branch1] });
      await setUser(client, viewer.id);
      const { rows } = await client.query('SELECT * FROM app.fiscal_overview()');
      expect(rows.map((r) => r.branch_id)).toEqual([a.branch1.id]);
      expect(rows[0].certificate_days_left).toBeGreaterThanOrEqual(29);
      expect(rows[0].certificate_days_left).toBeLessThanOrEqual(31);
      expect(rows[0].can_regime).toBe(false);
      expect(rows[0].can_manage).toBe(false);
      expect(rows[0].can_certificate).toBe(false);
      expect(rows[0].certificate_author).toBe(a.admin.name);
      expect(rows[0]).not.toHaveProperty('encrypted_pfx');
    });
  });

  it('sem permissão fiscal, não vê certificado nem CSC', async () => {
    await asUser(a.admin.id, async (client) => {
      await setCertificate(client, a.branch1, meta(a));
      await setCsc(client, a.branch1);
      await setUser(client, a.oneBranchUser.id);
      expect((await client.query('SELECT 1 FROM v_branch_certificate')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_branch_csc')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM app.fiscal_overview()')).rows).toEqual([]);
    });
  });

  it('outro grupo não enxerga', async () => {
    await asUser(a.admin.id, async (client) => {
      await setCertificate(client, a.branch1, meta(a));
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM v_branch_certificate WHERE branch_id = $1', [a.branch1.id])).rows).toEqual([]);
      await expect(setCertificate(client, a.branch1, meta(a))).rejects.toSatisfy(hasCode('FA006'));
    });
  });
});
