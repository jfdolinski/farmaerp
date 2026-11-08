import { randomInt, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const seriesOf = (client, terminalId) =>
  client.query(
    `SELECT id, model, series, initial_number, last_used_number, deleted_at
       FROM terminal_fiscal_series WHERE terminal_id = $1 ORDER BY model DESC`,
    [terminalId],
  ).then((r) => r.rows);
const set = (client, id, series, initial = 1) =>
  client.query('SELECT app.set_terminal_series($1, $2, $3)', [id, series, initial]);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
const pendingTerminal = async (client, branch) =>
  (await client.query(
    `INSERT INTO terminal (branch_id, status, public_key) VALUES ($1, 'pending', $2) RETURNING *`,
    [branch.id, `chave-${randomUUID()}`],
  )).rows[0];
const approve = (client, id, profile = 'cashier', name = `Caixa ${randomInt(1e9)}`) =>
  client.query('SELECT app.approve_terminal($1, $2, $3)', [id, name, profile]);
const numberOf = async (client, id) => (await client.query('SELECT number FROM terminal WHERE id = $1', [id])).rows[0].number;
const newCompanyBranch = (client, fixture) => client.query(
  `INSERT INTO branch (company_id, name, cnpj) VALUES ($1, $2, $3) RETURNING *`,
  [fixture.company.id, `Nova ${randomInt(1e9)}`, cnpj()],
).then((r) => r.rows[0]);

function cnpj() {
  const base = `${randomInt(10_000_000, 100_000_000)}0001`;
  const digit = (value) => {
    let weight = 2;
    let total = 0;
    for (let i = value.length - 1; i >= 0; i -= 1) {
      total += Number(value[i]) * weight;
      weight = weight === 9 ? 2 : weight + 1;
    }
    const rest = total % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(base);
  return `${base}${first}${digit(`${base}${first}`)}`;
}

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

describe('criação na aprovação', () => {
  it('caixa recebe 65 e 55, com o número do terminal e início em 1', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const terminal = await pendingTerminal(client, a.branch1);
      expect(await seriesOf(client, terminal.id)).toEqual([]);
      await approve(client, terminal.id, 'cashier');
      const number = await numberOf(client, terminal.id);
      const rows = await seriesOf(client, terminal.id);
      expect(rows.map((r) => r.model)).toEqual(['65', '55']);
      expect(rows.every((r) => r.series === number && r.initial_number === '1' && r.last_used_number === null)).toBe(true);
    });
  });

  it('autoatendimento recebe só 65, e orçamento não recebe nenhuma', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const self = await pendingTerminal(client, a.branch1);
      await approve(client, self.id, 'self_service');
      expect((await seriesOf(client, self.id)).map((r) => r.model)).toEqual(['65']);
      const quote = await pendingTerminal(client, a.branch1);
      await approve(client, quote.id, 'quote');
      expect(await seriesOf(client, quote.id)).toEqual([]);
    });
  });

  it('terminal pendente recusado não recebe série', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const terminal = await pendingTerminal(client, a.branch1);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Teste')`, [terminal.id]);
      expect(await seriesOf(client, terminal.id)).toEqual([]);
    });
  });

  it('bloquear e desbloquear mantêm as mesmas séries', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const terminal = await pendingTerminal(client, a.branch1);
      await approve(client, terminal.id);
      const before = await seriesOf(client, terminal.id);
      await client.query(`SELECT app.set_terminal_status($1, 'blocked', 'Teste')`, [terminal.id]);
      await client.query(`SELECT app.set_terminal_status($1, 'active', 'Teste')`, [terminal.id]);
      expect(await seriesOf(client, terminal.id)).toEqual(before);
    });
  });

  it('série ocupada: usa a próxima livre, em cada modelo', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const first = await pendingTerminal(client, a.branch2);
      await approve(client, first.id);
      const number = await numberOf(client, first.id);
      const [s65] = await seriesOf(client, first.id);
      // Ocupa a série que o próximo terminal receberia, só na NFC-e.
      await set(client, s65.id, number + 1);
      const second = await pendingTerminal(client, a.branch2);
      await approve(client, second.id);
      const rows = await seriesOf(client, second.id);
      expect(rows.find((r) => r.model === '65').series).toBe(number + 2);
      expect(rows.find((r) => r.model === '55').series).toBe(number + 1);
    });
  });

  it('filial sem série livre recusa a aprovação com mensagem clara', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const branch = await newCompanyBranch(client, a);
      const { rows: [holder] } = await client.query(
        `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, 'Base', 'quote', 'active', $2) RETURNING id`,
        [branch.id, `chave-${randomUUID()}`],
      );
      await client.query(
        `INSERT INTO terminal_fiscal_series (economic_group_id, branch_id, terminal_id, model, series, deleted_at)
         SELECT $1, $2, $3, '65', g, now() FROM generate_series(1, 889) g`,
        [a.group.id, branch.id, holder.id],
      );
      const terminal = await pendingTerminal(client, branch);
      await expect(approve(client, terminal.id)).rejects.toSatisfy(hasCode('FA921'));
    });
  });

  it('terminais de filiais diferentes podem ter a mesma série', async () => {
    await asOwner(async (client) => {
      const one = await seriesOf(client, a.terminal1.id);
      const other = await newCompanyBranch(client, a);
      const { rows: [terminal] } = await client.query(
        `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, 'Caixa', 'cashier', 'active', $2) RETURNING id`,
        [other.id, `chave-${randomUUID()}`],
      );
      expect((await seriesOf(client, terminal.id)).map((r) => r.series)).toEqual(one.map((r) => r.series));
    });
  });
});

describe('aprovações simultâneas', () => {
  it('não repetem série na mesma filial', async () => {
    const owner = await ownerPool.connect();
    let terminals;
    try {
      terminals = await Promise.all(Array.from({ length: 6 }, async () =>
        (await ownerPool.query(
          `INSERT INTO terminal (branch_id, status, public_key) VALUES ($1, 'pending', $2) RETURNING id`,
          [b.branch1.id, `chave-${randomUUID()}`],
        )).rows[0].id));
    } finally {
      owner.release();
    }
    await Promise.all(terminals.map(async (id) => {
      const client = await appPool.connect();
      try {
        await client.query('BEGIN');
        await setUser(client, b.admin.id);
        await approve(client, id);
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally {
        client.release();
      }
    }));
    const { rows } = await ownerPool.query(
      'SELECT model, series FROM terminal_fiscal_series WHERE terminal_id = ANY ($1)',
      [terminals],
    );
    expect(rows).toHaveLength(12);
    for (const model of ['65', '55']) {
      const values = rows.filter((r) => r.model === model).map((r) => r.series);
      expect(new Set(values).size).toBe(6);
    }
  });
});

describe('aprovação durante um ajuste', () => {
  it('espera o ajuste terminar e escolhe outra série, sem erro para quem aprova', async () => {
    const editor = await appPool.connect();
    const approver = await appPool.connect();
    try {
      // Ajuste ainda não confirmado ocupa a série que o próximo terminal receberia.
      const { rows: [next] } = await ownerPool.query(
        'SELECT COALESCE(MAX(number), 0) + 1 AS number FROM terminal WHERE branch_id = $1',
        [b.branch2.id],
      );
      const { rows: [own] } = await ownerPool.query(
        `SELECT id FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65'`,
        [b.terminal2.id],
      );
      const { rows: [pending] } = await ownerPool.query(
        `INSERT INTO terminal (branch_id, status, public_key) VALUES ($1, 'pending', $2) RETURNING id`,
        [b.branch2.id, `chave-${randomUUID()}`],
      );
      await editor.query('BEGIN');
      await setUser(editor, b.admin.id);
      await set(editor, own.id, next.number);

      await approver.query('BEGIN');
      await setUser(approver, b.admin.id);
      const approving = approve(approver, pending.id);
      await new Promise((resolve) => { setTimeout(resolve, 300); });
      await editor.query('COMMIT');
      await approving;
      await approver.query('COMMIT');

      const { rows } = await ownerPool.query(
        `SELECT series FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = '65'`,
        [pending.id],
      );
      expect(rows[0].series).toBe(next.number + 1);
    } finally {
      await editor.query('ROLLBACK');
      await approver.query('ROLLBACK');
      editor.release();
      approver.release();
    }
  });
});

describe('ajuste de série e número inicial', () => {
  it('altera e guarda o histórico', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const [row] = await seriesOf(client, a.terminal1.id);
      await set(client, row.id, 50, 1234);
      const [after] = await seriesOf(client, a.terminal1.id);
      expect(after).toMatchObject({ series: 50, initial_number: '1234' });
      const { rows } = await client.query(
        'SELECT from_series, to_series, from_initial_number, to_initial_number, updated_by FROM terminal_fiscal_series_event WHERE series_id = $1',
        [row.id],
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ from_series: row.series, to_series: 50, from_initial_number: '1', to_initial_number: '1234' });
    });
  });

  it('salvar sem mudar nada não gera histórico', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const [row] = await seriesOf(client, a.terminal1.id);
      await set(client, row.id, row.series, 1);
      expect((await client.query('SELECT 1 FROM terminal_fiscal_series_event WHERE series_id = $1', [row.id])).rows).toEqual([]);
    });
  });

  it.each([
    ['série zero', 0, 1, 'FA919'],
    ['série reservada', 890, 1, 'FA919'],
    ['série de contingência', 900, 1, 'FA919'],
    ['número zero', 1, 0, 'FA919'],
    ['número grande demais', 1, 1000000000, 'FA919'],
    ['série nula', null, 1, 'FA919'],
    ['número nulo', 1, null, 'FA919'],
  ])('recusa %s', async (_label, series, initial, code) => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const [row] = await seriesOf(client, a.terminal1.id);
      await expect(set(client, row.id, series, initial)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('aceita os limites da faixa', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const [row] = await seriesOf(client, a.terminal1.id);
      await set(client, row.id, 889, 999999999);
      await set(client, row.id, 1, 1);
    });
  });

  it('recusa série de outro terminal da filial, mas aceita no outro modelo', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const terminal = await pendingTerminal(client, a.branch1);
      await approve(client, terminal.id);
      const rows = await seriesOf(client, terminal.id);
      const [mine] = await seriesOf(client, a.terminal1.id);
      await set(client, rows[0].id, 70);
      await expectCode(client, () => set(client, mine.id, 70), 'FA918');
      const [, nfe] = await seriesOf(client, a.terminal1.id);
      await set(client, nfe.id, 70);
    });
  });

  it('depois do primeiro número usado, nada muda, e o último número só anda para a frente', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const [row] = await seriesOf(client, a.terminal1.id);
      await client.query('UPDATE terminal_fiscal_series SET last_used_number = 10 WHERE id = $1', [row.id]);
      await expectCode(client, () => set(client, row.id, row.series + 1), 'FA920');
      await expectCode(client, () => set(client, row.id, row.series, 5), 'FA920');
      await expectCode(client, () => client.query('UPDATE terminal_fiscal_series SET last_used_number = 9 WHERE id = $1', [row.id]), 'FA920');
      await expectCode(client, () => client.query('UPDATE terminal_fiscal_series SET last_used_number = NULL WHERE id = $1', [row.id]), 'FA920');
      await client.query('UPDATE terminal_fiscal_series SET last_used_number = 11 WHERE id = $1', [row.id]);
    });
  });

  it.each([
    ['terminal_id', () => a.terminal2.id],
    ['branch_id', () => a.branch2.id],
    ['model', () => '55'],
    ['economic_group_id', () => b.group.id],
  ])('%s não muda', async (column, value) => {
    await asOwner(async (client) => {
      const [row] = await seriesOf(client, a.terminal1.id);
      await expect(client.query(`UPDATE terminal_fiscal_series SET ${column} = $2 WHERE id = $1`, [row.id, value()])).rejects.toSatisfy(hasCode('FA104'));
    });
  });
});

describe('terminal revogado', () => {
  it('encerra as séries, e elas não voltam para outro terminal', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const old = await pendingTerminal(client, a.branch1);
      await approve(client, old.id);
      const [series] = await seriesOf(client, old.id);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Aparelho trocado')`, [old.id]);
      expect((await seriesOf(client, old.id)).every((r) => r.deleted_at !== null)).toBe(true);
      expect((await client.query('SELECT 1 FROM v_terminal_fiscal_series WHERE terminal_id = $1', [old.id])).rows).toEqual([]);

      const next = await pendingTerminal(client, a.branch1);
      await approve(client, next.id);
      const rows = await seriesOf(client, next.id);
      expect(rows.map((r) => r.series)).not.toContain(series.series);
      await expectCode(client, () => set(client, rows[0].id, series.series), 'FA918');
    });
  });

  it('série encerrada não pode ser ajustada', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const old = await pendingTerminal(client, a.branch1);
      await approve(client, old.id);
      const [series] = await seriesOf(client, old.id);
      await client.query(`SELECT app.set_terminal_status($1, 'revoked', 'Teste')`, [old.id]);
      await expect(set(client, series.id, 200)).rejects.toSatisfy(hasCode('FA006'));
    });
  });
});

describe('quem lê e quem altera', () => {
  it('a API não escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT bool_or(has_table_privilege('farmaerp_app', t, 'INSERT')) AS ins,
             bool_or(has_table_privilege('farmaerp_app', t, 'UPDATE')) AS upd
        FROM unnest(ARRAY['terminal_fiscal_series', 'terminal_fiscal_series_event']) AS t`);
    expect(rows[0]).toEqual({ ins: false, upd: false });
  });

  it('o administrador altera pela API', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query('SELECT * FROM app.list_terminal_series() WHERE terminal_id = $1', [a.terminal1.id]);
      expect(rows.map((r) => r.model)).toEqual(['65', '55']);
      expect(rows[0].can_manage).toBe(true);
      await set(client, rows[0].id, 300);
    });
  });

  it('o Gerente consulta, mas não altera', async () => {
    await asOwner(async (client) => {
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
      await setUser(client, manager.id);
      const { rows } = await client.query('SELECT * FROM app.list_terminal_series() WHERE terminal_id = $1', [a.terminal1.id]);
      expect(rows).toHaveLength(2);
      expect(rows[0].can_manage).toBe(false);
      await expect(set(client, rows[0].id, 301)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('fiscal.manage vale só na filial dele', async () => {
    await asOwner(async (client) => {
      const local = await userWith(client, ['fiscal.manage'], { branches: [a.branch1], scope: a.branch1 });
      const [mine] = await seriesOf(client, a.terminal1.id);
      const [other] = await seriesOf(client, a.terminal2.id);
      await setUser(client, local.id);
      await set(client, mine.id, 302);
      await expect(set(client, other.id, 303)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('quem aprova terminal não precisa de permissão fiscal', async () => {
    await asOwner(async (client) => {
      const approver = await userWith(client, ['terminals.approve'], { branches: [a.branch1] });
      const terminal = await pendingTerminal(client, a.branch1);
      await setUser(client, approver.id);
      await approve(client, terminal.id);
      expect(await seriesOf(client, terminal.id)).toHaveLength(2);
    });
  });

  it('sem permissão, não enxerga; outro grupo também não', async () => {
    await asUser(a.noBranchUser.id, async (client) => {
      expect((await client.query('SELECT 1 FROM v_terminal_fiscal_series')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM app.list_terminal_series()')).rows).toEqual([]);
    });
    const { rows: [row] } = await ownerPool.query('SELECT id FROM terminal_fiscal_series WHERE terminal_id = $1 LIMIT 1', [a.terminal1.id]);
    await asUser(b.admin.id, async (client) => {
      expect((await client.query('SELECT 1 FROM v_terminal_fiscal_series WHERE id = $1', [row.id])).rows).toEqual([]);
      await expect(set(client, row.id, 304)).rejects.toSatisfy(hasCode('FA006'));
    });
  });
});
