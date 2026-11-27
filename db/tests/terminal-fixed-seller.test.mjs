import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, asUser, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

// Vendedor padrão do terminal: a venda começa com ele e o PDV não bloqueia pedindo o vendedor.

let a;
let b;
let seller;
let manager;

const newUser = async (group, name, { role = null, branch = null, active = true } = {}) => {
  const { rows: [user] } = await ownerPool.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [group, name],
  );
  if (branch) await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch]);
  if (role) await ownerPool.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [user.id, role]);
  // Desativado depois de ganhar perfil e filial (usuário inativo não recebe perfil novo).
  if (!active) await ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [user.id]);
  return user;
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows: [sellerRole] } = await ownerPool.query(
    `INSERT INTO role (economic_group_id, name) VALUES ($1, 'Só orçamento (teste)') RETURNING *`, [a.group.id],
  );
  await ownerPool.query(`INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'sales.quote'`, [sellerRole.id]);
  seller = await newUser(a.group.id, 'Balconista Fictícia', { role: sellerRole.id, branch: a.branch1.id });
  // Gerente vende, mas não aprova terminais.
  manager = await newUser(a.group.id, 'Gerente Fictício', { role: a.managerRole.id, branch: a.branch1.id });
});
afterAll(closePools);

const set = (client, terminal, user) => client.query('SELECT app.set_terminal_fixed_seller($1, $2)', [terminal, user]);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
const fixedOf = (client, terminal) =>
  client.query('SELECT fixed_seller_id, fixed_seller_name FROM v_terminal_monitor WHERE id = $1', [terminal]).then((r) => r.rows[0]);

describe('vendedor padrão do terminal', () => {
  it('quem aprova terminais escolhe quem orça ou vende na filial; o monitor mostra; tirar volta a pedir', async () => {
    await asUser(a.admin.id, async (client) => {
      await set(client, a.terminal1.id, seller.id);
      expect(await fixedOf(client, a.terminal1.id)).toEqual({
        fixed_seller_id: seller.id, fixed_seller_name: `${seller.code} · Balconista Fictícia`,
      });
      await set(client, a.terminal1.id, manager.id);
      expect((await fixedOf(client, a.terminal1.id)).fixed_seller_id).toBe(manager.id);
      await set(client, a.terminal1.id, null);
      expect(await fixedOf(client, a.terminal1.id)).toEqual({ fixed_seller_id: null, fixed_seller_name: null });
    });
  });

  it('a mudança desce ao PDV junto com os dados fiscais da filial', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      await set(client, a.terminal1.id, seller.id);
      const { rows } = await client.query('SELECT txid_current()::text AS xid');
      await client.query('COMMIT');
      const { rows: changes } = await ownerPool.query(
        "SELECT xid::text FROM sync_change WHERE entity = 'fiscal' AND entity_id = $1 AND branch_id = $1 AND deleted_at IS NULL",
        [a.branch1.id],
      );
      expect(changes.map((row) => row.xid)).toContain(rows[0].xid);
    } finally {
      await ownerPool.query('UPDATE terminal SET fixed_seller_id = NULL WHERE id = $1', [a.terminal1.id]);
      client.release();
    }
  });

  it('recusa quem não vende nem orça, quem está inativo, sem acesso à filial ou de outro grupo', async () => {
    const inactive = await newUser(a.group.id, 'Inativo Fictício', { role: a.managerRole.id, branch: a.branch1.id, active: false });
    const otherBranch = await newUser(a.group.id, 'Outra Filial Fictícia', { role: a.managerRole.id, branch: a.branch2.id });
    const stranger = await newUser(b.group.id, 'De Fora Fictício', { role: b.managerRole.id, branch: b.branch1.id });
    await asUser(a.admin.id, async (client) => {
      for (const user of [a.oneBranchUser, inactive, otherBranch, stranger]) {
        await expectCode(client, () => set(client, a.terminal1.id, user.id), 'FA762');
      }
      await expectCode(client, () => set(client, a.terminal1.id, '0190a000-0000-7000-8000-000000000000'), 'FA762');
      // Quem tem acesso à outra filial serve lá.
      await set(client, a.terminal2.id, otherBranch.id);
      expect((await fixedOf(client, a.terminal2.id)).fixed_seller_id).toBe(otherBranch.id);
    });
  });

  it('sem aprovar terminais, ou de outro grupo, não muda; terminal pendente ou revogado também não', async () => {
    await asUser(manager.id, async (client) => {
      await expectCode(client, () => set(client, a.terminal1.id, seller.id), 'FA002');
    });
    await asUser(b.admin.id, async (client) => {
      await expectCode(client, () => set(client, a.terminal1.id, null), 'FA002');
    });
    await asUser(a.admin.id, async (client) => {
      for (const status of ['pending', 'revoked']) {
        const { rows: [terminal] } = await ownerPool.query(
          `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, 'Novo ' || $2, 'cashier', $2, $3) RETURNING id`,
          [a.branch1.id, status, `chave-${status}-${Date.now()}`],
        );
        await expectCode(client, () => set(client, terminal.id, seller.id), 'FA303');
      }
      // Bloqueado pode.
      const { rows: [blocked] } = await ownerPool.query(
        `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, 'Bloqueado', 'cashier', 'blocked', $2) RETURNING id`,
        [a.branch1.id, `chave-bloqueado-${Date.now()}`],
      );
      await set(client, blocked.id, seller.id);
    });
  });

  it('as opções: por filial, só onde quem pergunta aprova terminais, só quem vende ou orça', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [{ o }] } = await client.query('SELECT app.terminal_seller_options() AS o');
      const at = (branch) => o.filter((row) => row.branch_id === branch).map((row) => row.user_id);
      expect(at(a.branch1.id)).toEqual(expect.arrayContaining([seller.id, manager.id, a.admin.id]));
      expect(at(a.branch1.id)).not.toContain(a.oneBranchUser.id);
      expect(at(a.branch2.id)).not.toContain(seller.id);
      expect(o.find((row) => row.user_id === seller.id)).toEqual({
        branch_id: a.branch1.id, user_id: seller.id, code: Number(seller.code), name: 'Balconista Fictícia',
      });
      expect(o.some((row) => row.branch_id === b.branch1.id)).toBe(false);
    });
    await asUser(manager.id, async (client) => {
      const { rows: [{ o }] } = await client.query('SELECT app.terminal_seller_options() AS o');
      expect(o).toEqual([]);
    });
  });

  it('a API não muda o terminal direto', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT d');
      await expect(client.query('UPDATE terminal SET fixed_seller_id = $2 WHERE id = $1', [a.terminal1.id, seller.id]))
        .rejects.toThrow(/permission denied/);
      await client.query('ROLLBACK TO d');
      await client.query('SAVEPOINT e');
      await expect(client.query('SELECT app.can_be_terminal_seller($1, $2)', [seller.id, a.branch1.id])).rejects.toThrow(/permission denied/);
      await client.query('ROLLBACK TO e');
    });
  });
});
