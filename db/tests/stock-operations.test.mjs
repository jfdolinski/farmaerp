import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, asUser, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const tag = () => randomBytes(4).toString('hex');

const newProduct = async (client, overrides = {}) => {
  const barcode = overrides.barcode ?? gtin();
  const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [
    JSON.stringify({ displayName: `Produto ${tag()}`, barcode, ...overrides }),
  ]);
  return { id: rows[0].id, barcode };
};
const track = (client, product, branch, tracks = true) =>
  client.query('SELECT app.set_batch_tracking($1, $2, $3)', [product.id, branch.id, tracks]);
const entry = (client, product, branch, quantity, extra = {}) =>
  client.query('SELECT app.adjust_stock($1::jsonb) AS id', [JSON.stringify({
    productLookup: product.barcode, branchId: branch.id, direction: 'in', quantity, reason: 'Carga', ...extra,
  })]);
const transfer = (client, product, from, to, quantity, extra = {}) =>
  client.query('SELECT app.transfer_stock($1::jsonb) AS id', [JSON.stringify({
    productLookup: product.barcode, fromBranchId: from.id, toBranchId: to.id, quantity, reason: 'Reposição', ...extra,
  })]).then((r) => r.rows[0].id);
const count = (client, product, branch, countedQuantity, extra = {}) =>
  client.query('SELECT app.count_stock($1::jsonb) AS id', [JSON.stringify({
    productLookup: product.barcode, branchId: branch.id, countedQuantity, reason: 'Inventário', ...extra,
  })]).then((r) => r.rows[0].id);
const byBatch = async (client, product, branch) => {
  const { rows } = await client.query('SELECT * FROM app.stock_overview(NULL, $1, $2, true)', [branch.id, product.id]);
  return Object.fromEntries(rows.map((row) => [row.batch_number ?? '-', Number(row.quantity)]));
};
const availability = async (client, product, branch) =>
  (await client.query('SELECT * FROM app.product_availability($1, $2)', [product.id, branch.id])).rows[0];
const setStatus = (client, product, branches, status) =>
  client.query('SELECT app.set_product_status($1, $2, $3, $4)', [product.id, branches.map((x) => x.id), status, 'Teste']);

/** Produto com lote nas duas filiais e três lotes na origem, fora da ordem de entrada. */
async function withBatches(client) {
  const product = await newProduct(client);
  await track(client, product, a.branch1);
  await track(client, product, a.branch2);
  await entry(client, product, a.branch1, 5, { batchNumber: 'TARDE', expiresOn: '2092-01-01', msRegistration: '1111111111111' });
  await entry(client, product, a.branch1, 3, { batchNumber: 'CEDO', expiresOn: '2090-01-01', msRegistration: '2222222222222' });
  await entry(client, product, a.branch1, 4, { batchNumber: 'MEIO', expiresOn: '2091-01-01' });
  return product;
}

async function userWith(client, codes, { branches = [], scope = null } = {}) {
  const { rows: [user] } = await client.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [a.group.id, `Usuário ${tag()}`],
  );
  const { rows: [role] } = await client.query(
    'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [a.group.id, `Perfil ${tag()}`],
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

describe('baixa pelo vencimento', () => {
  it('a ordem é a do vencimento, não a da entrada', async () => {
    // A ordem é interna: a API não executa esta função, só as que a usam.
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      const { rows } = await client.query('SELECT pb.batch_number FROM app.batches_in_fefo_order($1, $2) f JOIN v_product_batch pb ON pb.id = f.batch_id ORDER BY f.fefo_position', [product.id, a.branch1.id]);
      expect(rows.map((row) => row.batch_number)).toEqual(['CEDO', 'MEIO', 'TARDE']);
    });
  });

  it('com a mesma validade, sai o que entrou primeiro', async () => {
    // A ordem é interna: a API não executa esta função, só as que a usam.
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await track(client, product, a.branch1);
      await entry(client, product, a.branch1, 1, { batchNumber: 'PRIMEIRO', expiresOn: '2090-01-01' });
      await entry(client, product, a.branch1, 1, { batchNumber: 'SEGUNDO', expiresOn: '2090-01-01' });
      const { rows } = await client.query('SELECT pb.batch_number FROM app.batches_in_fefo_order($1, $2) f JOIN v_product_batch pb ON pb.id = f.batch_id ORDER BY f.fefo_position', [product.id, a.branch1.id]);
      expect(rows.map((row) => row.batch_number)).toEqual(['PRIMEIRO', 'SEGUNDO']);
    });
  });

  it('vencido e zerado não entram na ordem', async () => {
    // A ordem é interna: a API não executa esta função, só as que a usam.
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      await entry(client, product, a.branch1, 9, { batchNumber: 'VENCIDO', expiresOn: '2020-01-01' });
      await client.query('SELECT app.register_stock_loss($1::jsonb)', [JSON.stringify({
        productLookup: product.barcode, branchId: a.branch1.id, quantity: 3, batchNumber: 'CEDO', reason: 'Quebra',
      })]);
      const { rows } = await client.query('SELECT pb.batch_number FROM app.batches_in_fefo_order($1, $2) f JOIN v_product_batch pb ON pb.id = f.batch_id ORDER BY f.fefo_position', [product.id, a.branch1.id]);
      expect(rows.map((row) => row.batch_number)).toEqual(['MEIO', 'TARDE']);
    });
  });
});

describe('transferência', () => {
  it('sem lote informado, sai pelo vencimento, dividindo entre lotes', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await transfer(client, product, a.branch1, a.branch2, 5);
      expect(await byBatch(client, product, a.branch1)).toEqual({ CEDO: 0, MEIO: 2, TARDE: 5 });
      expect(await byBatch(client, product, a.branch2)).toEqual({ CEDO: 3, MEIO: 2 });
    });
  });

  it('no destino, o lote nasce com a validade e o MS da origem', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await transfer(client, product, a.branch1, a.branch2, 3);
      const { rows } = await client.query(
        `SELECT batch_number, expires_on::text, ms_registration FROM v_product_batch WHERE product_id = $1 AND branch_id = $2`,
        [product.id, a.branch2.id],
      );
      expect(rows).toEqual([{ batch_number: 'CEDO', expires_on: '2090-01-01', ms_registration: '2222222222222' }]);
    });
  });

  it('as duas pontas ficam ligadas e o total da rede não muda', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      const group = await transfer(client, product, a.branch1, a.branch2, 5);
      const { rows } = await client.query('SELECT branch_id, quantity FROM v_stock_movement WHERE transfer_group = $1', [group]);
      expect(rows).toHaveLength(4);
      expect(rows.reduce((sum, row) => sum + Number(row.quantity), 0)).toBe(0);
      const { rows: [total] } = await client.query('SELECT quantity FROM v_stock_network_total WHERE product_id = $1', [product.id]);
      expect(Number(total.quantity)).toBe(12);
    });
  });

  it('destino com o mesmo lote e outra validade é recusado, e nada sai da origem', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await entry(client, product, a.branch2, 1, { batchNumber: 'CEDO', expiresOn: '2099-01-01' });
      await client.query('SAVEPOINT s');
      await expect(transfer(client, product, a.branch1, a.branch2, 1)).rejects.toSatisfy(hasCode('FA804'));
      await client.query('ROLLBACK TO s');
      expect((await byBatch(client, product, a.branch1)).CEDO).toBe(3);
    });
  });

  it('origem com lote e destino sem controle: entra sem lote', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await track(client, product, a.branch2, false);
      await transfer(client, product, a.branch1, a.branch2, 2);
      expect(await byBatch(client, product, a.branch2)).toEqual({ '-': 2 });
    });
  });

  it('origem sem lote e destino que exige lote é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 5);
      await track(client, product, a.branch2);
      await expect(transfer(client, product, a.branch1, a.branch2, 1)).rejects.toSatisfy(hasCode('FA817'));
    });
  });

  it('sem controle nas duas pontas, move o saldo sem lote', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 5);
      await transfer(client, product, a.branch1, a.branch2, 1.5);
      expect(await byBatch(client, product, a.branch1)).toEqual({ '-': 3.5 });
      expect(await byBatch(client, product, a.branch2)).toEqual({ '-': 1.5 });
    });
  });

  it('não transfere mais do que há, contando só lotes que podem sair', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await entry(client, product, a.branch1, 50, { batchNumber: 'VENCIDO', expiresOn: '2020-01-01' });
      await client.query('SAVEPOINT s');
      await expect(transfer(client, product, a.branch1, a.branch2, 13)).rejects.toSatisfy(hasCode('FA801'));
      await client.query('ROLLBACK TO s');
      await transfer(client, product, a.branch1, a.branch2, 12);
      expect((await byBatch(client, product, a.branch1)).VENCIDO).toBe(50);
    });
  });

  it.each([
    ['mesma filial', (c, p) => transfer(c, p, a.branch1, a.branch1, 1), 'FA815'],
    ['destino de outro grupo', (c, p) => transfer(c, p, a.branch1, b.branch1, 1), 'FA004'],
    ['sem motivo', (c, p) => transfer(c, p, a.branch1, a.branch2, 1, { reason: '' }), 'FA302'],
    ['quantidade zero', (c, p) => transfer(c, p, a.branch1, a.branch2, 0), 'FA810'],
    ['lote em produto sem controle', (c, p) => transfer(c, p, a.branch1, a.branch2, 1, { batchNumber: 'X' }), 'FA803'],
  ])('recusa %s', async (_label, action, code) => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 5);
      await expect(action(client, product)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('transferência não é estornada pela retaguarda', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 5);
      const group = await transfer(client, product, a.branch1, a.branch2, 1);
      const { rows: [movement] } = await client.query('SELECT id FROM v_stock_movement WHERE transfer_group = $1 LIMIT 1', [group]);
      await expect(client.query('SELECT app.reverse_stock_movement($1, $2)', [movement.id, 'x'])).rejects.toSatisfy(hasCode('FA811'));
    });
  });
});

describe('lote escolhido à mão', () => {
  it('o primeiro da ordem passa sem permissão especial e sem marca', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      const user = await userWith(client, ['stock.transfer'], { branches: [a.branch1] });
      await setUser(client, user.id);
      const group = await transfer(client, product, a.branch1, a.branch2, 1, { batchNumber: 'cedo' });
      const { rows } = await client.query('SELECT fefo_override FROM stock_movement WHERE transfer_group = $1 AND quantity < 0', [group]);
      expect(rows).toEqual([{ fefo_override: false }]);
    });
  });

  it('fora da ordem exige a permissão', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      const user = await userWith(client, ['stock.transfer'], { branches: [a.branch1] });
      await setUser(client, user.id);
      await expect(transfer(client, product, a.branch1, a.branch2, 1, { batchNumber: 'TARDE' })).rejects.toSatisfy(hasCode('FA814'));
    });
  });

  it('com a permissão, passa e fica marcado na movimentação, com o autor', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      const user = await userWith(client, ['stock.transfer', 'stock.batch_override'], { branches: [a.branch1] });
      await setUser(client, user.id);
      const group = await transfer(client, product, a.branch1, a.branch2, 2, { batchNumber: 'TARDE' });
      const { rows } = await client.query(
        'SELECT branch_id, fefo_override, updated_by FROM stock_movement WHERE transfer_group = $1 ORDER BY quantity',
        [group],
      );
      expect(rows[0]).toEqual({ branch_id: a.branch1.id, fefo_override: true, updated_by: user.id });
      expect(rows[1].fefo_override).toBe(false);
    });
  });

  it('a permissão vale por filial', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      const user = await userWith(client, ['stock.transfer', 'stock.batch_override'], { branches: [a.branch1, a.branch2], scope: a.branch2 });
      await client.query(
        `INSERT INTO user_role (user_id, role_id)
         SELECT $1, id FROM role WHERE economic_group_id = $2 AND name = 'Gerente'`,
        [user.id, a.group.id],
      );
      await client.query(
        `UPDATE role_permission SET deleted_at = now()
          WHERE role_id = (SELECT id FROM role WHERE economic_group_id = $1 AND name = 'Gerente')
            AND permission_id = (SELECT id FROM permission WHERE code = 'stock.batch_override')`,
        [a.group.id],
      );
      await setUser(client, user.id);
      await expect(transfer(client, product, a.branch1, a.branch2, 1, { batchNumber: 'TARDE' })).rejects.toSatisfy(hasCode('FA814'));
    });
  });

  it('vencido nunca, nem com a permissão', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await entry(client, product, a.branch1, 5, { batchNumber: 'VENCIDO', expiresOn: '2020-01-01' });
      await expect(transfer(client, product, a.branch1, a.branch2, 1, { batchNumber: 'VENCIDO' })).rejects.toSatisfy(hasCode('FA813'));
    });
  });

  it('vencido sai como perda, sem pedir permissão de ordem', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      await entry(client, product, a.branch1, 5, { batchNumber: 'VENCIDO', expiresOn: '2020-01-01' });
      const user = await userWith(client, ['stock.loss'], { branches: [a.branch1] });
      await setUser(client, user.id);
      await client.query('SELECT app.register_stock_loss($1::jsonb)', [JSON.stringify({
        productLookup: product.barcode, branchId: a.branch1.id, quantity: 5, batchNumber: 'VENCIDO', reason: 'Vencido',
      })]);
    });
  });

  it('perda fora da ordem não pede permissão', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await withBatches(client);
      const user = await userWith(client, ['stock.loss'], { branches: [a.branch1] });
      await setUser(client, user.id);
      await client.query('SELECT app.register_stock_loss($1::jsonb)', [JSON.stringify({
        productLookup: product.barcode, branchId: a.branch1.id, quantity: 1, batchNumber: 'TARDE', reason: 'Caixa amassada',
      })]);
    });
  });
});

describe('permissões da transferência', () => {
  it('exige stock.transfer na origem, e não no destino', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 5);
      await entry(client, product, a.branch2, 5);
      const user = await userWith(client, ['stock.transfer'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, user.id);
      await transfer(client, product, a.branch1, a.branch2, 1);
      await expect(transfer(client, product, a.branch2, a.branch1, 1)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('a API não escreve direto: tudo passa pelas funções', async () => {
    const { rows } = await ownerPool.query(`SELECT has_table_privilege('farmaerp_app', 'stock_movement', 'INSERT') AS ins`);
    expect(rows[0].ins).toBe(false);
  });
});

describe('inventário simples', () => {
  it('a diferença vira movimentação, para cima e para baixo', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 10);
      await count(client, product, a.branch1, 7);
      expect(await byBatch(client, product, a.branch1)).toEqual({ '-': 7 });
      await count(client, product, a.branch1, 9.5);
      expect(await byBatch(client, product, a.branch1)).toEqual({ '-': 9.5 });
      const { rows } = await client.query(
        `SELECT movement_type, quantity FROM app.list_stock_movements($1) ORDER BY occurred_at`,
        [product.id],
      );
      expect(rows.filter((row) => row.movement_type === 'inventory').map((row) => row.quantity).sort()).toEqual(['-3.000', '2.500']);
    });
  });

  it('contagem igual ao saldo não gera nada', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 10);
      expect(await count(client, product, a.branch1, 10)).toBeNull();
      const { rows } = await client.query('SELECT 1 FROM app.list_stock_movements($1)', [product.id]);
      expect(rows).toHaveLength(1);
    });
  });

  it('produto sem saldo nenhum: a contagem cria o saldo', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await count(client, product, a.branch1, 4);
      expect(await byBatch(client, product, a.branch1)).toEqual({ '-': 4 });
    });
  });

  it('saldo negativo de venda volta ao contado', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity)
         VALUES ($1, $2, $3, 'sale', -3)`,
        [a.group.id, a.branch1.id, product.id],
      );
      await count(client, product, a.branch1, 2);
      expect(await byBatch(client, product, a.branch1)).toEqual({ '-': 2 });
    });
  });

  it('por lote: conta cada lote, e lote achado na prateleira nasce com validade', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await count(client, product, a.branch1, 1, { batchNumber: 'CEDO' });
      await count(client, product, a.branch1, 2, { batchNumber: 'NOVO', expiresOn: '2093-01-01' });
      expect(await byBatch(client, product, a.branch1)).toEqual({ CEDO: 1, MEIO: 4, NOVO: 2, TARDE: 5 });
    });
  });

  it('lote novo sem validade é recusado, e lote zerado que não existe também', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await client.query('SAVEPOINT s');
      await expect(count(client, product, a.branch1, 2, { batchNumber: 'NOVO' })).rejects.toSatisfy(hasCode('FA806'));
      await client.query('ROLLBACK TO s');
      await expect(count(client, product, a.branch1, 0, { batchNumber: 'NAOEXISTE' })).rejects.toSatisfy(hasCode('FA808'));
    });
  });

  it('produto que exige lote não aceita contagem sem lote', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await withBatches(client);
      await expect(count(client, product, a.branch1, 3)).rejects.toSatisfy(hasCode('FA802'));
    });
  });

  it.each([[-1, 'FA810'], [null, 'FA810']])('contagem %s é recusada', async (value, code) => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await expect(count(client, product, a.branch1, value)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('exige stock.adjust: o Gerente não faz inventário', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [manager.id, a.managerRole.id]);
      await setUser(client, manager.id);
      await expect(count(client, product, a.branch1, 1)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('pode ser estornado', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch1, 10);
      const id = await count(client, product, a.branch1, 6);
      await client.query('SELECT app.reverse_stock_movement($1, $2)', [id, 'Contagem errada']);
      expect(await byBatch(client, product, a.branch1)).toEqual({ '-': 10 });
    });
  });
});

describe('o que cada status permite', () => {
  const cases = [
    ['active', 0, { sellable: true, auto_purchase: true, notice: null }],
    ['active', 5, { sellable: true, auto_purchase: true, notice: null }],
    ['on_order', 0, { sellable: true, auto_purchase: false, notice: 'on_order_without_stock' }],
    ['on_order', 5, { sellable: true, auto_purchase: false, notice: null }],
    ['blocked', 5, { sellable: true, auto_purchase: false, notice: 'remaining_stock_only' }],
    ['blocked', 0, { sellable: false, auto_purchase: false, notice: 'unavailable' }],
    ['inactive', 5, { sellable: true, auto_purchase: false, notice: 'remaining_stock_only' }],
    ['inactive', 0, { sellable: false, auto_purchase: false, notice: 'unavailable' }],
  ];

  it.each(cases)('%s com saldo %d', async (status, quantity, expected) => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      if (quantity > 0) await entry(client, product, a.branch1, quantity);
      if (status !== 'active') await setStatus(client, product, [a.branch1], status);
      const row = await availability(client, product, a.branch1);
      expect(row).toMatchObject({ status, ...expected });
      expect(Number(row.sellable_quantity)).toBe(quantity);
    });
  });

  it('lote vencido não conta como saldo vendável', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await track(client, product, a.branch1);
      await entry(client, product, a.branch1, 5, { batchNumber: 'VENCIDO', expiresOn: '2020-01-01' });
      await setStatus(client, product, [a.branch1], 'blocked');
      expect(await availability(client, product, a.branch1)).toMatchObject({ sellable: false, notice: 'unavailable' });
    });
  });

  it('saldo negativo de venda não libera bloqueado', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity)
         VALUES ($1, $2, $3, 'sale', -2)`,
        [a.group.id, a.branch1.id, product.id],
      );
      await setStatus(client, product, [a.branch1], 'blocked');
      expect(await availability(client, product, a.branch1)).toMatchObject({ sellable: false, notice: 'unavailable' });
    });
  });

  it('vale por filial: saldo de outra filial não conta', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await entry(client, product, a.branch2, 5);
      await setStatus(client, product, [a.branch1], 'blocked');
      expect(await availability(client, product, a.branch1)).toMatchObject({ sellable: false });
    });
  });
});

describe('destinos da transferência', () => {
  it('quem transfere da própria loja vê todas as filiais do grupo, só pelo nome', async () => {
    await asOwner(async (client) => {
      const user = await userWith(client, ['stock.transfer'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, user.id);
      const { rows } = await client.query('SELECT * FROM app.transfer_destinations()');
      expect(rows.map((row) => row.id).sort()).toEqual([a.branch1.id, a.branch2.id, a.branchFree.id].sort());
      expect(Object.keys(rows[0]).sort()).toEqual(['id', 'name']);
    });
  });

  it('sem a permissão, não vê nenhuma', async () => {
    await asUser(a.noBranchUser.id, async (client) => {
      expect((await client.query('SELECT * FROM app.transfer_destinations()')).rows).toEqual([]);
    });
  });

  it('não mostra filial de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows } = await client.query('SELECT id FROM app.transfer_destinations()');
      expect(rows.map((row) => row.id)).not.toContain(b.branch1.id);
    });
  });
});
