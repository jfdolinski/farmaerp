import { randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, asUser, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const ALL = [
  'agreements.manage', 'audit.view', 'branches.view_all', 'controlled.dispense', 'controlled.view', 'customers.manage', 'customers.view', 'fiscal.certificate', 'fiscal.manage', 'fiscal.view', 'products.manage', 'products.price', 'products.reactivate',
  'products.status', 'products.view', 'purchases.cost_override', 'purchases.manage', 'purchases.post', 'purchases.view', 'releases.view', 'roles.assign', 'roles.manage', 'rules.manage', 'rules.view', 'sales.discount_override', 'sales.sell', 'sales.view', 'sales.zero_stock_release',
  'stock.adjust', 'stock.batch', 'stock.batch_override', 'stock.loss', 'stock.transfer', 'stock.view', 'structure.manage', 'sync.resolve', 'sync.view',
  'terminals.approve', 'terminals.block', 'terminals.request', 'terminals.revoke', 'terminals.view',
  'users.manage', 'users.reset_password', 'users.view',
];
const MANAGER = ['controlled.view', 'customers.manage', 'customers.view', 'fiscal.certificate', 'products.view', 'purchases.manage', 'purchases.post', 'purchases.view', 'releases.view', 'sales.sell', 'sales.view', 'sales.zero_stock_release', 'stock.batch_override', 'stock.loss', 'stock.transfer', 'stock.view', 'sync.resolve', 'sync.view', 'terminals.block', 'terminals.request', 'terminals.view', 'users.reset_password', 'users.view'];

const has = async (client, code, branchId = null) =>
  (await client.query('SELECT app.has_permission($1, $2) AS ok', [code, branchId])).rows[0].ok;
const roleNamed = async (client, group, name) =>
  (await client.query('SELECT * FROM role WHERE economic_group_id = $1 AND name = $2', [group.id, name])).rows[0];

/** Dá um perfil direto, como o dono das tabelas. */
const give = (client, user, role, branch = null) =>
  client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3) RETURNING id', [user.id, role.id, branch?.id ?? null]);
const link = (client, user, branch) =>
  client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
const roleWith = async (client, group, codes, name = `Perfil ${randomBytes(4).toString('hex')}`) => {
  const { rows: [role] } = await client.query(
    'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [group.id, name],
  );
  await client.query(
    'INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)',
    [role.id, codes],
  );
  return role;
};

describe('catálogo e perfis iniciais', () => {
  it('o catálogo tem as permissões combinadas', async () => {
    const { rows } = await ownerPool.query('SELECT code FROM permission ORDER BY code');
    expect(rows.map((row) => row.code)).toEqual(ALL);
  });

  it('todo grupo novo já nasce com os quatro perfis', async () => {
    await asOwner(async (client) => {
      const { rows: [group] } = await client.query(`INSERT INTO economic_group (name) VALUES ('Novo') RETURNING id`);
      const { rows } = await client.query(
        'SELECT name, system_key FROM role WHERE economic_group_id = $1 ORDER BY name',
        [group.id],
      );
      expect(rows).toEqual([
        { name: 'Administrador', system_key: 'administrator' },
        { name: 'Farmacêutico', system_key: null },
        { name: 'Gerente', system_key: null },
        { name: 'Operador de caixa', system_key: null },
      ]);
    });
  });

  it.each([
    ['Administrador', ALL],
    ['Gerente', MANAGER],
    ['Farmacêutico', ['controlled.dispense', 'controlled.view', 'sales.sell']],
    ['Operador de caixa', ['sales.sell']],
  ])('%s tem as permissões da tabela', async (name, expected) => {
    await asOwner(async (client) => {
      const role = await roleNamed(client, a.group, name);
      await give(client, a.noBranchUser, role);
      const { rows } = await client.query('SELECT app.user_permission_codes($1) AS codes', [a.noBranchUser.id]);
      expect([...rows[0].codes].sort()).toEqual(expected);
    });
  });

  it('a API não escreve direto em perfis nem permissões', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['permission', 'role', 'role_permission', 'user_role']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });
});

describe('permissão por perfil', () => {
  it('sem usuário ninguém tem permissão', async () => {
    await asUser(null, async (client) => {
      expect(await has(client, 'users.view')).toBe(false);
    });
  });

  it('sem perfil, nada', async () => {
    await asUser(a.noBranchUser.id, async (client) => {
      for (const code of ALL) expect(await has(client, code), code).toBe(false);
    });
  });

  it('o administrador tem tudo, inclusive permissões futuras', async () => {
    await asUser(a.admin.id, async (client) => {
      for (const code of ALL) expect(await has(client, code), code).toBe(true);
      expect(await has(client, 'modulo_futuro.acao')).toBe(true);
    });
  });

  it('as permissões de vários perfis se somam', async () => {
    await asOwner(async (client) => {
      await give(client, a.noBranchUser, await roleWith(client, a.group, ['users.view']));
      await give(client, a.noBranchUser, await roleWith(client, a.group, ['terminals.view']));
      await setUser(client, a.noBranchUser.id);
      expect(await has(client, 'users.view')).toBe(true);
      expect(await has(client, 'terminals.view')).toBe(true);
      expect(await has(client, 'users.manage')).toBe(false);
    });
  });

  it('retirar o perfil vale na hora', async () => {
    await asOwner(async (client) => {
      await give(client, a.noBranchUser, await roleWith(client, a.group, ['users.view']));
      await setUser(client, a.noBranchUser.id);
      expect(await has(client, 'users.view')).toBe(true);
      await client.query('UPDATE user_role SET deleted_at = now() WHERE user_id = $1', [a.noBranchUser.id]);
      expect(await has(client, 'users.view')).toBe(false);
    });
  });

  it('tirar a permissão do perfil vale na hora', async () => {
    await asOwner(async (client) => {
      const role = await roleWith(client, a.group, ['users.view']);
      await give(client, a.noBranchUser, role);
      await setUser(client, a.noBranchUser.id);
      expect(await has(client, 'users.view')).toBe(true);
      await client.query('UPDATE role_permission SET deleted_at = now() WHERE role_id = $1', [role.id]);
      expect(await has(client, 'users.view')).toBe(false);
    });
  });

  it('usuário desativado não tem nada', async () => {
    await asOwner(async (client) => {
      await client.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.secondAdmin.id]);
      await setUser(client, a.secondAdmin.id);
      expect(await has(client, 'users.view')).toBe(false);
    });
  });
});

describe('perfil por filial', () => {
  it('vale só na filial escolhida', async () => {
    await asOwner(async (client) => {
      await link(client, a.noBranchUser, a.branch1);
      await link(client, a.noBranchUser, a.branch2);
      await give(client, a.noBranchUser, a.managerRole, a.branch1);
      await setUser(client, a.noBranchUser.id);
      expect(await has(client, 'terminals.block', a.branch1.id)).toBe(true);
      expect(await has(client, 'terminals.block', a.branch2.id)).toBe(false);
      expect(await has(client, 'terminals.block')).toBe(false);
    });
  });

  it('gerente em uma filial e operador em outra', async () => {
    const { a: g } = await createFixtures();
    await link(ownerPool, g.noBranchUser, g.branch1);
    await link(ownerPool, g.noBranchUser, g.branch2);
    await give(ownerPool, g.noBranchUser, g.managerRole, g.branch1);
    await give(ownerPool, g.noBranchUser, await roleNamed(ownerPool, g.group, 'Operador de caixa'), g.branch2);
    await asUser(g.noBranchUser.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM v_terminal_monitor');
      expect(rows.map((row) => row.id)).toEqual([g.terminal1.id]);
    });
  });

  it('sem filial, vale em todas as filiais do usuário, e só nelas', async () => {
    await asOwner(async (client) => {
      await link(client, a.noBranchUser, a.branch1);
      await give(client, a.noBranchUser, a.managerRole);
      await setUser(client, a.noBranchUser.id);
      expect(await has(client, 'terminals.block', a.branch1.id)).toBe(true);
      expect(await has(client, 'terminals.block', a.branch2.id)).toBe(false);
    });
  });

  it('perder o vínculo com a filial encerra o perfil nela', async () => {
    await asOwner(async (client) => {
      await link(client, a.noBranchUser, a.branch1);
      await give(client, a.noBranchUser, a.managerRole, a.branch1);
      await client.query('UPDATE user_branch SET deleted_at = now() WHERE user_id = $1', [a.noBranchUser.id]);
      await setUser(client, a.noBranchUser.id);
      expect(await has(client, 'terminals.block', a.branch1.id)).toBe(false);
    });
  });

  it('exige vínculo com a filial', async () => {
    await asOwner(async (client) => {
      await expect(give(client, a.noBranchUser, a.managerRole, a.branch1)).rejects.toSatisfy(hasCode('FA505'));
    });
  });

  it('administrador não é por filial', async () => {
    await asOwner(async (client) => {
      await link(client, a.noBranchUser, a.branch1);
      await expect(give(client, a.noBranchUser, a.adminRole, a.branch1)).rejects.toSatisfy(hasCode('FA506'));
    });
  });

  it('o mesmo perfil pode valer em filiais diferentes, mas não repetir', async () => {
    await asOwner(async (client) => {
      await link(client, a.noBranchUser, a.branch1);
      await link(client, a.noBranchUser, a.branch2);
      await give(client, a.noBranchUser, a.managerRole, a.branch1);
      await give(client, a.noBranchUser, a.managerRole, a.branch2);
      await give(client, a.noBranchUser, a.managerRole);
      await expect(give(client, a.noBranchUser, a.managerRole)).rejects.toSatisfy(hasCode('FA507'));
    });
  });
});

describe('isolamento entre grupos', () => {
  it('perfil de outro grupo não pode ser atribuído', async () => {
    await asOwner(async (client) => {
      await expect(give(client, a.noBranchUser, b.managerRole)).rejects.toSatisfy(hasCode('FA509'));
    });
  });

  it('admin não atribui perfil em outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query('SELECT app.assign_role($1, $2, NULL)', [b.noBranchUser.id, b.managerRole.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('admin não altera perfil de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(
        client.query(`SELECT app.update_role($1, 'Invadido', NULL, '{}')`, [b.managerRole.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('só vê os perfis do próprio grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query('SELECT DISTINCT economic_group_id FROM role');
      expect(rows.map((row) => row.economic_group_id)).toEqual([a.group.id]);
    });
  });
});

describe('sem escalada de privilégio', () => {
  const managerUser = async (client) => {
    const role = await roleWith(client, a.group, ['roles.manage', 'roles.assign', 'users.view']);
    await give(client, a.noBranchUser, role);
    return role;
  };

  it('não cria perfil com permissão que não tem', async () => {
    await asOwner(async (client) => {
      await managerUser(client);
      await setUser(client, a.noBranchUser.id);
      await expect(
        client.query(`SELECT app.create_role('Poderoso', NULL, ARRAY['users.manage'])`),
      ).rejects.toSatisfy(hasCode('FA504'));
    });
  });

  it('cria perfil com o que tem', async () => {
    await asOwner(async (client) => {
      await managerUser(client);
      await setUser(client, a.noBranchUser.id);
      const { rows } = await client.query(`SELECT app.create_role('Consulta de usuários', NULL, ARRAY['users.view']) AS id`);
      expect(rows[0].id).toBeTruthy();
    });
  });

  it('não acrescenta permissão que não tem, mas retira', async () => {
    await asOwner(async (client) => {
      await managerUser(client);
      const role = await roleWith(client, a.group, ['users.manage', 'users.view']);
      await setUser(client, a.noBranchUser.id);

      await client.query('SAVEPOINT s');
      await expect(
        client.query(`SELECT app.update_role($1, 'X', NULL, ARRAY['users.view', 'audit.view'])`, [role.id]),
      ).rejects.toSatisfy(hasCode('FA504'));
      await client.query('ROLLBACK TO SAVEPOINT s');

      await client.query(`SELECT app.update_role($1, 'X', NULL, ARRAY['users.view'])`, [role.id]);
      const { rows } = await client.query(
        `SELECT p.code FROM v_role_permission rp JOIN permission p ON p.id = rp.permission_id WHERE rp.role_id = $1`,
        [role.id],
      );
      expect(rows.map((row) => row.code)).toEqual(['users.view']);
    });
  });

  it('não dá a si mesmo um perfil com mais poder', async () => {
    await asOwner(async (client) => {
      await managerUser(client);
      await setUser(client, a.noBranchUser.id);
      await expect(
        client.query('SELECT app.assign_role($1, $2, NULL)', [a.noBranchUser.id, a.managerRole.id]),
      ).rejects.toSatisfy(hasCode('FA504'));
    });
  });

  it('não atribui o perfil de administrador sem ser administrador', async () => {
    await asOwner(async (client) => {
      const all = await roleWith(client, a.group, ALL);
      await give(client, a.noBranchUser, all);
      await setUser(client, a.noBranchUser.id);
      await expect(
        client.query('SELECT app.assign_role($1, $2, NULL)', [a.oneBranchUser.id, a.adminRole.id]),
      ).rejects.toSatisfy(hasCode('FA504'));
    });
  });

  it('não retira perfil com mais poder que o seu', async () => {
    await asOwner(async (client) => {
      await managerUser(client);
      const { rows: [assigned] } = await client.query('SELECT id FROM user_role WHERE user_id = $1', [a.admin.id]);
      await setUser(client, a.noBranchUser.id);
      await expect(
        client.query('SELECT app.unassign_role($1)', [assigned.id]),
      ).rejects.toSatisfy(hasCode('FA504'));
    });
  });

  it('gerente não gera senha de quem tem mais poder', async () => {
    await asOwner(async (client) => {
      await give(client, a.noBranchUser, a.managerRole);
      await client.query(`UPDATE user_account SET email = 'alvo@exemplo.com.br' WHERE id = $1`, [a.admin.id]);
      await setUser(client, a.noBranchUser.id);
      await expect(
        client.query(`SELECT app.set_temporary_password($1, 'hash', '')`, [a.admin.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('gerente gera senha de quem está no seu alcance', async () => {
    await asOwner(async (client) => {
      await give(client, a.noBranchUser, a.managerRole);
      await link(client, a.noBranchUser, a.branch1);
      await client.query(`UPDATE user_account SET email = 'alvo@exemplo.com.br' WHERE id = $1`, [a.oneBranchUser.id]);
      await setUser(client, a.noBranchUser.id);
      const { rowCount } = await client.query(`SELECT app.set_temporary_password($1, 'hash', '')`, [a.oneBranchUser.id]);
      expect(rowCount).toBe(1);
    });
  });

  it('gerente de uma filial não gera senha de usuário de outra', async () => {
    await asOwner(async (client) => {
      await link(client, a.noBranchUser, a.branch2);
      await give(client, a.noBranchUser, a.managerRole, a.branch2);
      await client.query(`UPDATE user_account SET email = 'alvo@exemplo.com.br' WHERE id = $1`, [a.oneBranchUser.id]);
      await setUser(client, a.noBranchUser.id);
      await expect(
        client.query(`SELECT app.set_temporary_password($1, 'hash', '')`, [a.oneBranchUser.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('quem gerencia usuários não edita quem tem permissões que ele não tem', async () => {
    const { a: g } = await createFixtures();
    await give(ownerPool, g.noBranchUser, await roleWith(ownerPool, g.group, ['users.manage', 'users.view']));
    await asUser(g.noBranchUser.id, async (client) => {
      const update = (id) => client.query(`UPDATE user_account SET name = 'Novo nome' WHERE id = $1`, [id]);
      expect((await update(g.admin.id)).rowCount).toBe(0);
      expect((await update(g.oneBranchUser.id)).rowCount).toBe(0);
    });
  });

  it('quem gerencia usuários edita quem não tem mais poder', async () => {
    const { a: g } = await createFixtures();
    const role = await roleWith(ownerPool, g.group, ['users.manage', 'users.view']);
    await give(ownerPool, g.noBranchUser, role);
    const { rows: [target] } = await ownerPool.query(
      `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Sem perfil') RETURNING id`,
      [g.group.id],
    );
    await asUser(g.noBranchUser.id, async (client) => {
      const { rowCount } = await client.query(`UPDATE user_account SET name = 'Novo nome' WHERE id = $1`, [target.id]);
      expect(rowCount).toBe(1);
    });
  });

  it('quem gerencia usuários não vincula a filial que não alcança', async () => {
    const { a: g } = await createFixtures();
    await give(ownerPool, g.noBranchUser, await roleWith(ownerPool, g.group, ['users.manage', 'users.view']));
    await link(ownerPool, g.noBranchUser, g.branch1);
    await asUser(g.noBranchUser.id, async (client) => {
      await expect(
        client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [g.noBranchUser.id, g.branch2.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('perfil de sistema', () => {
  it.each([
    ['editar', (id) => [`SELECT app.update_role($1, 'Outro', NULL, '{}')`, [id]]],
    ['excluir', (id) => ['SELECT app.delete_role($1)', [id]]],
  ])('o administrador não consegue %s pela função', async (_label, call) => {
    await asUser(a.admin.id, async (client) => {
      const [sql, params] = call(a.adminRole.id);
      await expect(client.query(sql, params)).rejects.toSatisfy(hasCode('FA502'));
    });
  });

  it('o trigger barra mesmo o dono das tabelas', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(`UPDATE role SET name = 'Outro' WHERE id = $1`, [a.adminRole.id]),
      ).rejects.toSatisfy(hasCode('FA502'));
    });
  });

  it('não dá para virar perfil de sistema', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(`UPDATE role SET system_key = 'administrator' WHERE id = $1`, [a.viewer.id]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });
});

describe('gestão de perfis', () => {
  it('cria, edita e exclui, com histórico', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [created] } = await client.query(`SELECT app.create_role('Caixa sênior', ' Turno ', ARRAY['terminals.view']) AS id`);
      await client.query(`SELECT app.update_role($1, 'Caixa líder', NULL, ARRAY['terminals.block'])`, [created.id]);

      const { rows: role } = await client.query('SELECT name, description FROM role WHERE id = $1', [created.id]);
      expect(role[0]).toEqual({ name: 'Caixa líder', description: null });

      const { rows: history } = await client.query(
        `SELECT p.code, rp.deleted_at IS NOT NULL AS removed, rp.updated_by
           FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
          WHERE rp.role_id = $1 ORDER BY rp.deleted_at IS NOT NULL DESC, p.code`,
        [created.id],
      );
      expect(history).toEqual([
        { code: 'terminals.view', removed: true, updated_by: a.admin.id },
        { code: 'terminals.block', removed: false, updated_by: a.admin.id },
      ]);

      await client.query('SELECT app.delete_role($1)', [created.id]);
      const { rows: active } = await client.query('SELECT 1 FROM v_role WHERE id = $1', [created.id]);
      expect(active).toEqual([]);
    });
  });

  it('não exclui perfil em uso', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('SELECT app.delete_role($1)', [a.viewer.id])).rejects.toSatisfy(hasCode('FA503'));
    });
  });

  it('nome repetido e permissão desconhecida dão erros claros', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT s');
      await expect(client.query(`SELECT app.create_role('Gerente', NULL, '{}')`)).rejects.toSatisfy(hasCode('FA501'));
      await client.query('ROLLBACK TO SAVEPOINT s');
      await expect(client.query(`SELECT app.create_role('Novo', NULL, ARRAY['nao.existe'])`)).rejects.toSatisfy(hasCode('FA508'));
    });
  });

  it('o vínculo não é editado: só incluído ou excluído', async () => {
    await asOwner(async (client) => {
      const { rows: [row] } = await give(client, a.noBranchUser, a.viewer);
      await expect(
        client.query('UPDATE user_role SET role_id = $2 WHERE id = $1', [row.id, a.managerRole.id]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('atribuir e retirar registra quem fez', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [assigned] } = await client.query('SELECT app.assign_role($1, $2, NULL) AS id', [a.noBranchUser.id, a.managerRole.id]);
      await client.query('SELECT app.unassign_role($1)', [assigned.id]);
      const { rows } = await client.query('SELECT updated_by, deleted_at IS NOT NULL AS removed FROM user_role WHERE id = $1', [assigned.id]);
      expect(rows[0]).toEqual({ updated_by: a.admin.id, removed: true });
    });
  });
});

describe('matriz do gerente nos terminais', () => {
  const asManager = async (client) => {
    await link(client, a.noBranchUser, a.branch1);
    await give(client, a.noBranchUser, a.managerRole);
    await setUser(client, a.noBranchUser.id);
  };

  it('bloqueia e desbloqueia', async () => {
    await asOwner(async (client) => {
      await asManager(client);
      await client.query(`SELECT app.set_terminal_status($1, 'blocked', 'Motivo')`, [a.terminal1.id]);
      await client.query(`SELECT app.set_terminal_status($1, 'active', NULL)`, [a.terminal1.id]);
    });
  });

  it('não revoga', async () => {
    await asOwner(async (client) => {
      await asManager(client);
      await expect(
        client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Motivo')`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('não aprova', async () => {
    await asOwner(async (client) => {
      await asManager(client);
      await expect(
        client.query(`SELECT app.approve_terminal($1, 'Caixa', 'cashier')`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('não age em filial fora do alcance', async () => {
    await asOwner(async (client) => {
      await asManager(client);
      await expect(
        client.query(`SELECT app.set_terminal_status($1, 'blocked', 'Motivo')`, [a.terminal2.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('aceita código em filial do alcance, mas não em outra', async () => {
    await asOwner(async (client) => {
      const key = randomBytes(32).toString('base64url');
      const { rows } = await client.query(
        `SELECT app.create_pairing_request($1, 'windows', 'CAIXA', '0.1.0', 'system') AS r`,
        [key],
      );
      await asManager(client);
      await client.query('SELECT app.find_pairing_request($1)', [rows[0].r.code]);
      await client.query('SAVEPOINT s');
      await expect(
        client.query('SELECT app.claim_pairing_request($1, $2)', [rows[0].r.code, a.branch2.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
      await client.query('ROLLBACK TO SAVEPOINT s');
      const { rows: claimed } = await client.query('SELECT app.claim_pairing_request($1, $2) AS id', [rows[0].r.code, a.branch1.id]);
      expect(claimed[0].id).toBeTruthy();
    });
  });

  it('perfil por filial também acha o código', async () => {
    await asOwner(async (client) => {
      const key = randomBytes(32).toString('base64url');
      const { rows } = await client.query(
        `SELECT app.create_pairing_request($1, 'windows', 'CAIXA', '0.1.0', 'system') AS r`,
        [key],
      );
      await link(client, a.noBranchUser, a.branch1);
      await give(client, a.noBranchUser, a.managerRole, a.branch1);
      await setUser(client, a.noBranchUser.id);
      const { rowCount } = await client.query('SELECT app.find_pairing_request($1)', [rows[0].r.code]);
      expect(rowCount).toBe(1);
    });
  });

  it('quem aprova também pode recusar um pendente, mas revogar um ativo é outra permissão', async () => {
    await asOwner(async (client) => {
      const key = randomBytes(32).toString('base64url');
      const { rows: [pending] } = await client.query(
        'INSERT INTO terminal (branch_id, public_key) VALUES ($1, $2) RETURNING id',
        [a.branch1.id, key],
      );
      await link(client, a.noBranchUser, a.branch1);
      await give(client, a.noBranchUser, await roleWith(client, a.group, ['terminals.approve', 'terminals.view']));
      await setUser(client, a.noBranchUser.id);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Recusado')`, [pending.id]);
      await expect(
        client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Motivo')`, [a.terminal1.id]),
      ).rejects.toSatisfy(hasCode('FA002'));
    });
  });
});

describe('visibilidade', () => {
  it('quem não tem permissão de ver terminais não os vê, mesmo na própria filial', async () => {
    const { a: g } = await createFixtures();
    await link(ownerPool, g.noBranchUser, g.branch1);
    await asUser(g.noBranchUser.id, async (client) => {
      expect((await client.query('SELECT 1 FROM terminal')).rows).toEqual([]);
      expect((await client.query('SELECT id FROM branch')).rows.map((row) => row.id)).toEqual([g.branch1.id]);
    });
  });

  it('gerente vê usuários da própria filial, e não os de outras', async () => {
    const { a: g } = await createFixtures();
    await link(ownerPool, g.noBranchUser, g.branch2);
    await give(ownerPool, g.noBranchUser, g.managerRole, g.branch2);
    await asUser(g.noBranchUser.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM user_account');
      const ids = rows.map((row) => row.id);
      expect(ids).toContain(g.noBranchUser.id);
      expect(ids).toContain(g.twoBranchesUser.id);
      expect(ids).not.toContain(g.oneBranchUser.id);
      expect(ids).not.toContain(g.admin.id);
    });
  });

  it('o histórico de acesso exige a permissão', async () => {
    const { a: g } = await createFixtures();
    await ownerPool.query(`INSERT INTO auth_event (user_id, event_type) VALUES ($1, 'logout')`, [g.oneBranchUser.id]);
    const count = async (client) =>
      (await client.query('SELECT 1 FROM auth_event WHERE user_id = $1', [g.oneBranchUser.id])).rows.length;
    await asUser(g.twoBranchesUser.id, async (client) => {
      expect(await count(client)).toBe(0);
    });
    await asUser(g.admin.id, async (client) => {
      expect(await count(client)).toBe(1);
    });
  });

  it('a sessão informa as permissões do usuário', async () => {
    await asOwner(async (client) => {
      const { rows } = await client.query('SELECT app.user_permission_codes($1) AS codes', [a.admin.id]);
      expect([...rows[0].codes].sort()).toEqual(ALL);
    });
  });
});
