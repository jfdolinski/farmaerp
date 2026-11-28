import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { asOwner, asUser, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

// PBM, parte 1: programas, ativação por filial, regras do programa de teste e as autorizações do
// caixa em duas fases (autoriza, confirma depois do pagamento ou desfaz).

let a;
let b;
let manager;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  manager = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, 'Gerente PBM'])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [manager.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
});
afterAll(closePools);

const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
const asWho = (client, user) => client.query("SELECT set_config('app.user_id', $1, true), set_config('app.terminal_id', '', true)", [user.id]);
const asTerminal = (client, terminal) => client.query("SELECT set_config('app.user_id', '', true), set_config('app.terminal_id', $1, true)", [terminal.id]);
const one = async (client, sql, params = []) => Object.values((await client.query(sql, params)).rows[0])[0];
const gtin = () => {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
};
const newProduct = (client) => one(client, 'SELECT app.create_product($1::jsonb)', [JSON.stringify({ displayName: `Produto PBM ${randomInt(1e6)}`, barcode: gtin() })]);
const saveProgram = (client, data) => one(client, 'SELECT app.save_pbm_program($1::jsonb)', [JSON.stringify(data)]);
const programs = (client) => one(client, 'SELECT app.pbm_programs()');

/** Programa de teste ativo na filial 1, com um produto a 40%. */
async function setup(client) {
  await asWho(client, a.admin);
  const program = await saveProgram(client, { name: `Programa ${randomInt(1e9)}` });
  await client.query('SELECT app.set_pbm_program_branch($1, $2, true)', [program, a.branch1.id]);
  const product = await newProduct(client);
  const other = await newProduct(client);
  await client.query('SELECT app.set_pbm_test_rule($1, $2, 40)', [program, product]);
  return { program, product, other };
}
const register = (client, program, items, external = `AUT${randomInt(1e9)}`, beneficiary = '52998224725') =>
  one(client, 'SELECT app.terminal_pbm_register($1, $2::jsonb)', [program, JSON.stringify({ beneficiary, external_id: external, items })]);

describe('programas na retaguarda', () => {
  it('cria, recusa nome repetido, liga por filial, guarda os dados de acesso sem mostrar e mantém as regras de teste', async () => {
    await asUser(a.admin.id, async (client) => {
      const name = `Programa ${randomInt(1e9)}`;
      const id = await saveProgram(client, { name });
      await expectCode(client, () => saveProgram(client, { name: ` ${name.toUpperCase()} ` }), 'FA799');
      await expectCode(client, () => saveProgram(client, { name: 'X' }), 'FA798');
      await expectCode(client, () => saveProgram(client, { name: 'Outro conector', connector: 'funcional' }), 'FA798');
      await client.query('SELECT app.set_pbm_program_branch($1, $2, true)', [id, a.branch1.id]);
      await client.query('SELECT app.set_pbm_branch_credentials($1, $2, $3)', [id, a.branch2.id, Buffer.alloc(40, 7)]);
      const product = await newProduct(client);
      await client.query('SELECT app.set_pbm_test_rule($1, $2, 25)', [id, product]);
      await client.query('SELECT app.set_pbm_test_rule($1, $2, 30)', [id, product]);
      await expectCode(client, () => client.query('SELECT app.set_pbm_test_rule($1, $2, 0)', [id, product]), 'FA798');
      await expectCode(client, () => client.query('SELECT app.set_pbm_test_rule($1, $2, 101)', [id, product]), 'FA798');
      const listed = (await programs(client)).find((p) => p.id === id);
      expect(listed).toMatchObject({ name, connector: 'test', active: true, can_edit: true, rules: [{ product_id: product, discount_percent: 30 }] });
      const byBranch = Object.fromEntries(listed.branches.map((row) => [row.branch_id, row]));
      expect(byBranch[a.branch1.id]).toMatchObject({ active: true, credentials_set_at: null });
      // Dados de acesso gravados deixam a filial desligada até alguém ligar.
      expect(byBranch[a.branch2.id]).toMatchObject({ active: false, credentials_set_at: expect.any(String) });
      // A view não tem os dados de acesso.
      const columns = (await client.query('SELECT * FROM v_pbm_program_branch WHERE program_id = $1', [id])).fields.map((f) => f.name);
      expect(columns).not.toContain('encrypted_credentials');
      // Sem percentual, o produto sai do programa; desligar a filial e o programa.
      await client.query('SELECT app.set_pbm_test_rule($1, $2, NULL)', [id, product]);
      await client.query('SELECT app.set_pbm_program_branch($1, $2, false)', [id, a.branch1.id]);
      await saveProgram(client, { id, active: false });
      expect((await programs(client)).find((p) => p.id === id)).toMatchObject({ active: false, rules: [] });
      // Produto e programa de outro grupo não entram.
      const foreign = await asOwnerProduct(b);
      await expectCode(client, () => client.query('SELECT app.set_pbm_test_rule($1, $2, 10)', [id, foreign]), 'FA006');
      await expectCode(client, () => client.query('SELECT app.set_pbm_program_branch($1, $2, true)', [id, b.branch1.id]), 'FA006');
    });
  });

  it('só quem tem pbm.manage configura; a permissão nova não vem em perfil nenhum além do Administrador; outro grupo não vê', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await saveProgram(client, { name: `Programa ${randomInt(1e9)}` });
      await asWho(client, manager);
      await expectCode(client, () => programs(client), 'FA002');
      await expectCode(client, () => saveProgram(client, { name: 'Do gerente' }), 'FA002');
      await expectCode(client, () => client.query('SELECT app.set_pbm_program_branch($1, $2, true)', [id, a.branch1.id]), 'FA002');
      await asWho(client, a.admin);
      const ruleProduct = await newProduct(client);
      await asWho(client, manager);
      await expectCode(client, () => client.query('SELECT app.set_pbm_test_rule($1, $2, 10)', [id, ruleProduct]), 'FA002');
      await asWho(client, b.admin);
      // Programa de outro grupo não se liga nem na filial de quem pede.
      await expectCode(client, () => client.query('SELECT app.set_pbm_program_branch($1, $2, true)', [id, b.branch1.id]), 'FA006');
      await expectCode(client, () => client.query('SELECT app.set_pbm_branch_credentials($1, $2, $3)', [id, b.branch1.id, Buffer.alloc(40, 1)]), 'FA006');
      expect((await programs(client)).map((p) => p.id)).not.toContain(id);
      await expectCode(client, () => saveProgram(client, { id, name: 'Invasor' }), 'FA006');
    });
    const { rows } = await ownerPool.query(
      `SELECT r.name FROM role_permission rp JOIN role r ON r.id = rp.role_id JOIN permission p ON p.id = rp.permission_id
        WHERE p.code = 'pbm.manage' AND rp.deleted_at IS NULL`,
    );
    expect(rows).toEqual([]);
  });
});

/** Produto de outro grupo, gravado de verdade (fora da transação do teste). */
async function asOwnerProduct(group) {
  const client = await ownerPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [group.admin.id]);
    const id = await newProduct(client);
    await client.query('COMMIT');
    return id;
  } finally {
    client.release();
  }
}

describe('autorização no caixa', () => {
  it('lista só o ativo na filial; o contexto recusa programa desligado; as regras de teste vêm só dos produtos pedidos', async () => {
    await asUser(a.admin.id, async (client) => {
      const { program, product, other } = await setup(client);
      const off = await saveProgram(client, { name: `Desligado ${randomInt(1e9)}` });
      await client.query('SELECT app.set_pbm_program_branch($1, $2, false)', [off, a.branch1.id]);
      await asTerminal(client, a.terminal1);
      const listed = (await one(client, 'SELECT app.terminal_pbm_programs()')).map((p) => p.id);
      expect(listed).toContain(program);
      expect(listed).not.toContain(off);
      expect((await client.query('SELECT * FROM app.terminal_pbm_context($1)', [program])).rows[0])
        .toMatchObject({ program_id: program, branch_id: a.branch1.id, terminal_id: a.terminal1.id, connector: 'test', encrypted_credentials: null });
      await expectCode(client, () => client.query('SELECT * FROM app.terminal_pbm_context($1)', [off]), 'FA793');
      expect((await client.query('SELECT * FROM app.terminal_pbm_test_rules($1, $2)', [program, [product, other]])).rows)
        .toEqual([{ product_id: product, discount_percent: '40.00' }]);
      expect((await client.query('SELECT * FROM app.terminal_pbm_test_rules($1, $2)', [program, [other]])).rows).toEqual([]);
      // Outra filial não tem o programa ligado.
      await asTerminal(client, a.terminal2);
      await expectCode(client, () => client.query('SELECT * FROM app.terminal_pbm_context($1)', [program]), 'FA793');
      // Programa desligado no grupo some do caixa.
      await asWho(client, a.admin);
      await saveProgram(client, { id: program, active: false });
      await asTerminal(client, a.terminal1);
      expect((await one(client, 'SELECT app.terminal_pbm_programs()')).map((p) => p.id)).not.toContain(program);
    });
  });

  it('registra com os totais dos itens; confirma uma vez com a venda; desfaz a não confirmada; o resto é FA795', async () => {
    await asUser(a.admin.id, async (client) => {
      const { program, product, other } = await setup(client);
      await asTerminal(client, a.terminal1);
      await expectCode(client, () => register(client, program, []), 'FA796');
      const foreign = await asOwnerProduct(b);
      await expectCode(client, () => register(client, program, [{ product_id: foreign, quantity: 1, list_price: 10, pbm_price: 6 }]), 'FA006');
      await expectCode(client, () => register(client, program, [{ product_id: product, quantity: 1, list_price: 10, pbm_price: 12 }]), 'FA798');
      // Item acima do preço do caixa, mesmo com o total da autorização certo.
      await expectCode(client, () => register(client, program, [
        { product_id: product, quantity: 1, list_price: 10, pbm_price: 12 }, { product_id: other, quantity: 1, list_price: 10, pbm_price: 2 },
      ]), 'FA798');
      await expectCode(client, () => register(client, program, [{ product_id: product, quantity: 1, list_price: 10, pbm_price: 6 }], 'AUT 1'), 'FA798');
      const done = await register(client, program, [
        { product_id: product, quantity: 2, list_price: 25.9, pbm_price: 15.54 },
        { product_id: other, quantity: 1, list_price: 10, pbm_price: 10 },
      ], 'AUT-1');
      expect(done).toMatchObject({ id: expect.any(String), list_total: 61.8, pbm_total: 41.08, benefit: 20.72 });
      expect(new Date(done.expires_at).getTime() - Date.now()).toBeGreaterThan(29 * 60_000);
      // O mesmo código de autorização no mesmo programa não entra duas vezes.
      await expectCode(client, () => register(client, program, [{ product_id: product, quantity: 1, list_price: 10, pbm_price: 6 }], 'AUT-1'), 'FA798');
      // Outro terminal não mexe na autorização.
      await asTerminal(client, a.terminal2);
      await expectCode(client, () => client.query('SELECT app.terminal_pbm_confirm($1, gen_random_uuid())', [done.id]), 'FA006');
      await asTerminal(client, a.terminal1);
      expect((await client.query('SELECT * FROM app.terminal_pbm_action_context($1)', [done.id])).rows[0])
        .toMatchObject({ status: 'authorized', external_id: 'AUT-1', connector: 'test', sale_id: null });
      const sale = (await client.query('SELECT gen_random_uuid() AS id')).rows[0].id;
      expect(await one(client, 'SELECT app.terminal_pbm_confirm($1, $2)', [done.id, sale])).toBe('confirmed');
      expect(await one(client, 'SELECT app.terminal_pbm_confirm($1, $2)', [done.id, sale])).toBe('confirmed');
      await expectCode(client, () => client.query('SELECT app.terminal_pbm_confirm($1, gen_random_uuid())', [done.id]), 'FA795');
      // Confirmada não se desfaz aqui (o estorno vem na parte 3).
      await expectCode(client, () => client.query("SELECT app.terminal_pbm_undo($1, 'Desistiu')", [done.id]), 'FA795');

      const dropped = await register(client, program, [{ product_id: product, quantity: 1, list_price: 10, pbm_price: 6 }]);
      expect(await one(client, "SELECT app.terminal_pbm_undo($1, 'Cliente desistiu')", [dropped.id])).toBe('undone');
      expect(await one(client, "SELECT app.terminal_pbm_undo($1, 'Cliente desistiu')", [dropped.id])).toBe('undone');
      await expectCode(client, () => client.query('SELECT app.terminal_pbm_confirm($1, gen_random_uuid())', [dropped.id]), 'FA795');
      const row = (await client.query("SELECT status, undo_reason, sale_id FROM v_pbm_authorization WHERE id = $1", [dropped.id])).rows;
      // O terminal não lê a tabela (só pelas funções); a retaguarda vê.
      expect(row).toEqual([]);
    });
  });

  it('vencida não confirma', async () => {
    await asOwner(async (client) => {
      await asWho(client, a.admin);
      const { program, product } = await setup(client);
      const { rows: [old] } = await client.query(
        `INSERT INTO pbm_authorization (economic_group_id, branch_id, terminal_id, program_id, beneficiary_document, external_id,
                                        list_total, pbm_total, authorized_at, expires_at)
         VALUES ($1, $2, $3, $4, '52998224725', $5, 10, 6, now() - interval '2 hours', now() - interval '90 minutes') RETURNING id`,
        [a.group.id, a.branch1.id, a.terminal1.id, program, `OLD${randomInt(1e9)}`],
      );
      expect(product).toBeTruthy();
      await asTerminal(client, a.terminal1);
      await expectCode(client, () => client.query('SELECT app.terminal_pbm_confirm($1, gen_random_uuid())', [old.id]), 'FA795');
    });
  });

  it('a situação só anda para a frente e os dados da autorização não mudam', async () => {
    await asOwner(async (client) => {
      await asWho(client, a.admin);
      const { program, product } = await setup(client);
      await asTerminal(client, a.terminal1);
      const done = await register(client, program, [{ product_id: product, quantity: 1, list_price: 10, pbm_price: 6 }]);
      const update = (sql) => client.query(`UPDATE pbm_authorization SET ${sql} WHERE id = $1`, [done.id]);
      // Confirmada precisa da venda; venda sem confirmar não entra.
      await expectCode(client, () => update("status = 'confirmed'"), 'FA798');
      await expectCode(client, () => update('sale_id = gen_random_uuid(), confirmed_at = now()'), 'FA795');
      await update("status = 'confirmed', sale_id = gen_random_uuid(), confirmed_at = now()");
      await expectCode(client, () => update("status = 'authorized'"), 'FA795');
      await expectCode(client, () => update("status = 'expired'"), 'FA795');
      await expectCode(client, () => update('sale_id = gen_random_uuid()'), 'FA795');
      await expectCode(client, () => update("undo_reason = 'Sem mudar a situação'"), 'FA795');
      for (const sql of ["external_id = 'OUTRO'", 'pbm_total = 1', "beneficiary_document = '11144477735'", 'expires_at = now() + interval \'1 day\'']) {
        await client.query('SAVEPOINT s');
        await expect(update(sql)).rejects.toThrow();
        await client.query('ROLLBACK TO s');
      }
      await update("status = 'undone', undone_at = now(), undo_reason = 'Estorno'");
      await expectCode(client, () => update("status = 'confirmed'"), 'FA795');
      const item = (await client.query('SELECT id FROM pbm_authorization_item WHERE authorization_id = $1', [done.id])).rows[0].id;
      await client.query('SAVEPOINT s');
      await expect(client.query('UPDATE pbm_authorization_item SET pbm_price = 1 WHERE id = $1', [item])).rejects.toThrow();
      await client.query('ROLLBACK TO s');
    });
  });
});

describe('conferência na retaguarda', () => {
  it('mostra o beneficiário mascarado, o benefício e a confirmada sem venda na central; outro grupo e outra filial não', async () => {
    await asUser(a.admin.id, async (client) => {
      const { program, product } = await setup(client);
      await asTerminal(client, a.terminal1);
      const done = await register(client, program, [{ product_id: product, quantity: 2, list_price: 10, pbm_price: 6 }], `REL${randomInt(1e9)}`);
      await client.query('SELECT app.terminal_pbm_confirm($1, gen_random_uuid())', [done.id]);
      await asWho(client, a.admin);
      const today = (await client.query("SELECT (now() AT TIME ZONE 'America/Sao_Paulo')::date::text AS d")).rows[0].d;
      const list = await one(client, 'SELECT app.pbm_authorizations($1, $1, NULL)', [today]);
      expect(list.find((row) => row.id === done.id)).toMatchObject({
        beneficiary: '********725', status: 'confirmed', list_total: 20, pbm_total: 12, benefit: 8, missing_sale: true,
        items: [{ quantity: 2, list_price: 10, pbm_price: 6 }],
      });
      expect(JSON.stringify(list)).not.toContain('52998224725');
      expect((await one(client, 'SELECT app.pbm_authorizations(NULL, NULL, $1)', [a.branch2.id])).map((row) => row.id)).not.toContain(done.id);
      await asWho(client, b.admin);
      expect((await one(client, 'SELECT app.pbm_authorizations(NULL, NULL, NULL)')).map((row) => row.id)).not.toContain(done.id);
    });
  });
});
