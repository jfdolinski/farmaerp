import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot,
} from './helpers.mjs';

let a;
let b;
let manager;
let buyer;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const newUser = async (name) => (await ownerPool.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, name],
  )).rows[0];
  manager = await newUser('Gerente lançamento');
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [manager.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
  // Comprador: confere a nota, mas não lança nem vê custo de outra filial.
  const { rows: [role] } = await ownerPool.query(
    `INSERT INTO role (economic_group_id, name) VALUES ($1, 'Comprador') RETURNING *`, [a.group.id],
  );
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code IN ('purchases.view', 'purchases.manage')`,
    [role.id],
  );
  buyer = await newUser('Comprador lançamento');
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [buyer.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [buyer.id, role.id, a.branch1.id]);
});
afterAll(closePools);

const cnpj = () => branchCnpj(randomRoot(), 1);
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
function accessKey(emitter, number) {
  const base = `352611${emitter}55001${String(number).padStart(9, '0')}1${String(randomInt(10_000_000, 99_999_999))}`;
  let total = 0;
  let weight = 2;
  for (let i = base.length - 1; i >= 0; i -= 1) {
    total += (base.charCodeAt(i) - 48) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const remainder = total % 11;
  return `${base}${remainder < 2 ? 0 : 11 - remainder}`;
}
const item = (overrides = {}) => ({
  number: 1, supplierCode: `C-${randomBytes(3).toString('hex')}`, barcode: null, description: 'ITEM DE TESTE', ncm: '30049099',
  cfop: '6102', unit: 'CX', quantity: '2.0000', unitPrice: '10.5', productsValue: '21.00', batches: [], ...overrides,
});
function invoice(overrides = {}) {
  const emitterCnpj = overrides.emitterCnpj ?? cnpj();
  const number = randomInt(1, 999_999_999);
  return {
    accessKey: accessKey(emitterCnpj, number), series: 1, number, issuedAt: '2026-11-20T10:00:00-03:00', operationType: 1,
    purpose: 1, environment: 2, protocolNumber: '135260000000001', authorizedAt: '2026-11-20T10:00:05-03:00',
    destCnpj: a.branch1.cnpj,
    emitter: { cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA DO LANCAMENTO LTDA', state: 'SP' },
    totals: { products: '21.00', invoice: '21.00' },
    items: [item()],
    ...overrides,
  };
}
const XML = '<nfeProc>conteúdo de teste</nfeProc>';
const importInvoice = (client, data) =>
  client.query('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, true) AS id', [
    JSON.stringify(data), XML, createHash('sha256').update(XML).digest('hex'),
  ]).then((r) => r.rows[0].id);
const createProduct = (client, data = {}) =>
  client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto ${randomBytes(4).toString('hex')}`, barcode: gtin(), ...data })])
    .then((r) => r.rows[0].id);
/** Produto com código de barras próprio: a nota com esse cEAN liga sozinha. */
async function product(client, data = {}) {
  const code = gtin();
  const id = await createProduct(client, { barcode: code, ...data });
  return { id, code };
}
/** Nota de um item do produto, com os valores informados. */
const invoiceFor = (client, prod, itemData = {}, invoiceData = {}) =>
  importInvoice(client, invoice({ items: [item({ barcode: prod.code, ...itemData })], ...invoiceData }));
const itemsOf = (client, invoiceId) =>
  client.query('SELECT * FROM purchase_invoice_item WHERE invoice_id = $1 ORDER BY item_number', [invoiceId]).then((r) => r.rows);
const post = (client, id) => client.query('SELECT app.post_purchase_invoice($1)', [id]);
const reverse = (client, id, reason = 'Produto ligado errado') => client.query('SELECT app.reverse_purchase_invoice($1, $2)', [id, reason]);
const release = (client, itemId, reason = 'Reajuste do fornecedor') => client.query('SELECT app.release_purchase_item_cost($1, $2)', [itemId, reason]);
const setBatches = (client, itemId, batches) => client.query('SELECT app.set_purchase_item_batches($1, $2::jsonb)', [itemId, JSON.stringify(batches)]);
const posting = (client, id) => client.query('SELECT * FROM app.purchase_invoice_posting($1)', [id]).then((r) => r.rows);
const averageCost = (client, productId, branchId = a.branch1.id) =>
  client.query(
    'SELECT average_cost FROM v_product_cost WHERE product_id = $1 AND branch_id = $2 ORDER BY created_at DESC, id DESC LIMIT 1',
    [productId, branchId],
  ).then((r) => r.rows[0]?.average_cost ?? null);
const stockOf = (client, productId, branchId = a.branch1.id) =>
  client.query('SELECT COALESCE(sum(quantity), 0)::text AS q FROM v_stock_balance WHERE product_id = $1 AND branch_id = $2', [productId, branchId])
    .then((r) => r.rows[0].q);
const statusOf = (client, id) => client.query('SELECT status FROM purchase_invoice WHERE id = $1', [id]).then((r) => r.rows[0].status);
const toleranceRule = (client, prod, value) =>
  client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({ typeCode: 'cost_tolerance', level: 'product', productLookup: prod.code, value })]);
const loss = (client, prod, quantity, batchNumber = null) =>
  client.query('SELECT app.register_stock_loss($1::jsonb)', [JSON.stringify({
    branchId: a.branch1.id, productLookup: prod.code, quantity, reason: 'Quebra', ...(batchNumber ? { batchNumber } : {}),
  })]);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
const cancel = (client, id, reason = 'Mercadoria não chegou') => client.query('SELECT app.cancel_purchase_invoice($1, $2)', [id, reason]);
const changeFraction = (client, itemId, fraction, reason = 'Caixa com 5 unidades') =>
  client.query('SELECT app.change_purchase_item_fraction($1, $2, $3)', [itemId, fraction, reason]);
const discard = (client, id) => client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'Nota repetida']);
const as = (client, user) => client.query(`SELECT set_config('app.user_id', $1, true)`, [user.id]);
const audit = (client, id) => client.query('SELECT app.purchase_invoice_extra($1) AS x', [id]).then((r) => r.rows[0].x.audit);
const costRows = (client, itemId) =>
  client.query(
    `SELECT average_cost, previous_cost, stock_before, entry_quantity, entry_cost, reversal_of
       FROM v_product_cost WHERE purchase_invoice_item_id = $1 ORDER BY created_at, id`, [itemId],
  ).then((r) => r.rows);
const balances = (client, productId) =>
  client.query(
    `SELECT pb.batch_number, sb.quantity FROM v_stock_balance sb JOIN v_product_batch pb ON pb.id = sb.batch_id
      WHERE sb.product_id = $1 ORDER BY pb.batch_number`, [productId],
  ).then((r) => r.rows);

describe('cancelar nota', () => {
  it('lançada: tira do estoque, refaz o custo e fica cancelada, sem voltar para a conferência', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const first = await invoiceFor(client, prod, { quantity: '20', productsValue: '40.00' });
      await post(client, first);
      const id = await invoiceFor(client, prod, { quantity: '20', productsValue: '30.00' });
      await post(client, id);
      expect(await averageCost(client, prod.id)).toBe('1.750000');

      await expectCode(client, () => cancel(client, id, ' '), 'FA302');
      await cancel(client, id);
      expect(await stockOf(client, prod.id)).toBe('20.000');
      expect(await averageCost(client, prod.id)).toBe('2.000000');
      const { rows: [row] } = await client.query(
        'SELECT status, cancelled_by, cancel_reason, cancelled_at FROM purchase_invoice WHERE id = $1', [id],
      );
      expect(row).toEqual({ status: 'cancelled', cancelled_by: a.admin.id, cancel_reason: 'Mercadoria não chegou', cancelled_at: null });
      const { rows: events } = await client.query(
        'SELECT kind, reason FROM v_purchase_invoice_event WHERE invoice_id = $1 ORDER BY created_at, id', [id],
      );
      expect(events).toEqual([{ kind: 'posted', reason: null }, { kind: 'cancelled', reason: 'Mercadoria não chegou' }]);
      expect((await audit(client, id))[0]).toMatchObject({ kind: 'cancelled', detail: { reason: 'Mercadoria não chegou' } });
      const [it] = await itemsOf(client, id);
      const { rows: movements } = await client.query(
        'SELECT quantity, reason FROM v_stock_movement WHERE purchase_invoice_item_id = $1 ORDER BY id', [it.id],
      );
      expect(movements.map((m) => m.quantity)).toEqual(['20.000', '-20.000']);
      expect(movements[1].reason).toMatch(/^Nota \d+ cancelada: Mercadoria não chegou$/);

      // Cancelada não se cancela, não se lança, não se estorna, não se descarta, não se altera e não entra de novo.
      await expectCode(client, () => cancel(client, id), 'FA764');
      await expectCode(client, () => post(client, id), 'FA938');
      await expectCode(client, () => reverse(client, id), 'FA939');
      await expectCode(client, () => discard(client, id), 'FA764');
      await expectCode(client, () => changeFraction(client, it.id, 2), 'FA939');
      const { rows: [{ access_key: key, number }] } = await client.query('SELECT access_key, number FROM purchase_invoice WHERE id = $1', [id]);
      await expectCode(client, () => importInvoice(client, invoice({ accessKey: key, number })), 'FA929');
    });
  });

  it('em conferência: só deixa de poder ser lançada', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      await cancel(client, id, 'Pedido errado');
      expect(await statusOf(client, id)).toBe('cancelled');
      expect(await stockOf(client, prod.id)).toBe('0');
      await expectCode(client, () => post(client, id), 'FA938');
    });
  });

  it('o que entrou já saiu: o Gerente não deixa negativo; quem tem a permissão cancela e fica registrado', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' });
      await post(client, id);
      await loss(client, prod, 4);
      await as(client, manager);
      await expectCode(client, () => cancel(client, id), 'FA763');
      expect(await statusOf(client, id)).toBe('posted');
      await as(client, a.admin);
      await cancel(client, id);
      expect(await stockOf(client, prod.id)).toBe('-4.000');
      const { rows } = await client.query(
        'SELECT quantity, negative_allowed_by FROM v_stock_movement WHERE product_id = $1 AND reversal_of IS NOT NULL', [prod.id],
      );
      expect(rows).toEqual([{ quantity: '-10.000', negative_allowed_by: a.admin.id }]);
    });
  });

  it('com saldo, o Gerente cancela sem precisar da permissão de negativo', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' });
      await post(client, id);
      await as(client, manager);
      await cancel(client, id);
      expect(await statusOf(client, id)).toBe('cancelled');
      const { rows } = await client.query(
        'SELECT negative_allowed_by FROM v_stock_movement WHERE product_id = $1 AND reversal_of IS NOT NULL', [prod.id],
      );
      expect(rows).toEqual([{ negative_allowed_by: null }]);
    });
  });

  it('quem só confere não cancela; outro grupo não enxerga', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      await as(client, buyer);
      await expectCode(client, () => cancel(client, id), 'FA002');
      await as(client, b.admin);
      await expectCode(client, () => cancel(client, id), 'FA006');
    });
  });

  it('o Gerente padrão cancela; deixar negativo fica com o Administrador', async () => {
    const { rows } = await ownerPool.query(
      `SELECT p.code FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
        WHERE rp.role_id = $1 AND p.code IN ('purchases.cancel', 'purchases.negative_stock') AND rp.deleted_at IS NULL`,
      [a.managerRole.id],
    );
    expect(rows.map((r) => r.code)).toEqual(['purchases.cancel']);
  });

  it('a API não escreve direto nas colunas novas', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      await client.query('SAVEPOINT s');
      await expect(client.query(
        `UPDATE purchase_invoice SET status = 'cancelled', cancelled_by = $2, cancel_reason = 'x' WHERE id = $1`, [id, a.admin.id],
      )).rejects.toThrow();
      await client.query('ROLLBACK TO s');
    });
  });
});

describe('alterar fracionamento da nota lançada', () => {
  it('acerta o estoque, o custo da entrada, o custo médio e o vínculo com o fornecedor', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const first = await invoiceFor(client, prod, { quantity: '20', productsValue: '40.00' });
      await post(client, first);
      const supplierCode = `C-${randomBytes(3).toString('hex')}`;
      const emitterCnpj = cnpj();
      const id = await invoiceFor(client, prod, { quantity: '2', productsValue: '30.00', supplierCode }, { emitterCnpj });
      const [it] = await itemsOf(client, id);
      await client.query('SELECT app.update_product_supplier($1, 10)', [it.product_supplier_id]);
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('40.000');
      expect(await averageCost(client, prod.id)).toBe('1.750000');

      await changeFraction(client, it.id, 5);
      expect(await stockOf(client, prod.id)).toBe('30.000');
      // Sai a entrada antiga (20 a 1,50): sobram 20 a 2,00. Entra a nova (10 a 3,00): 70 ÷ 30.
      expect(await averageCost(client, prod.id)).toBe('2.333333');
      const rows = await costRows(client, it.id);
      expect(rows.map(({ reversal_of: r, ...rest }) => ({ ...rest, reversal: r !== null }))).toEqual([
        { average_cost: '1.750000', previous_cost: '2.000000', stock_before: '20.000', entry_quantity: '20.000', entry_cost: '1.500000', reversal: false },
        { average_cost: '2.000000', previous_cost: '1.750000', stock_before: '40.000', entry_quantity: '-20.000', entry_cost: '1.500000', reversal: true },
        { average_cost: '2.333333', previous_cost: '2.000000', stock_before: '20.000', entry_quantity: '10.000', entry_cost: '3.000000', reversal: false },
      ]);
      const { rows: [relation] } = await client.query('SELECT fraction_quantity FROM product_supplier WHERE id = $1', [it.product_supplier_id]);
      expect(relation.fraction_quantity).toBe('5.000');
      const { rows: [saved] } = await client.query('SELECT posted_fraction FROM purchase_invoice_item WHERE id = $1', [it.id]);
      expect(saved.posted_fraction).toBe('5.000');
      expect((await posting(client, id))[0]).toMatchObject({
        fraction: '5.000', stock_quantity: '10.000', unit_cost: '3.000000', average_cost: '2.000000', new_average_cost: '2.333333',
      });
      const { rows: [shown] } = await client.query('SELECT fraction, stock_quantity FROM app.purchase_invoice_items($1)', [id]);
      expect(shown).toEqual({ fraction: '5.000', stock_quantity: '10.000' });
      const { rows: movements } = await client.query(
        'SELECT quantity, reason FROM v_stock_movement WHERE purchase_invoice_item_id = $1 ORDER BY id', [it.id],
      );
      expect(movements.map((m) => m.quantity)).toEqual(['20.000', '-10.000']);
      expect(movements[1].reason).toMatch(/fracionamento de 10\.000 para 5 \(Caixa com 5 unidades\)$/);
      expect((await audit(client, id))[0]).toMatchObject({
        kind: 'fraction_changed',
        detail: { item_number: 1, from: 10, to: 5, stock_from: 20, stock_to: 10, cost_from: 1.5, cost_to: 3, reason: 'Caixa com 5 unidades' },
      });

      // A próxima nota do mesmo código do fornecedor já vem com o novo fracionamento.
      const next = await importInvoice(client, invoice({ emitterCnpj, items: [item({ supplierCode, quantity: '1', productsValue: '15.00' })] }));
      expect((await posting(client, next))[0]).toMatchObject({ fraction: '5.000', stock_quantity: '5.000' });

      // Estornar depois da alteração devolve tudo.
      await reverse(client, id);
      expect(await stockOf(client, prod.id)).toBe('20.000');
      expect(await averageCost(client, prod.id)).toBe('2.000000');
      const { rows: [cleared] } = await client.query('SELECT posted_fraction FROM purchase_invoice_item WHERE id = $1', [it.id]);
      expect(cleared.posted_fraction).toBeNull();
    });
  });

  it('a nota lançada guarda o fracionamento com que entrou, mesmo se o vínculo mudar depois', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const id = await invoiceFor(client, prod);
      await post(client, id);
      const [it] = await itemsOf(client, id);
      expect(it.posted_fraction).toBe('10.000');
      await client.query('SELECT app.update_product_supplier($1, 3)', [it.product_supplier_id]);
      expect((await posting(client, id))[0]).toMatchObject({ fraction: '10.000', stock_quantity: '20.000' });
      const { rows: [shown] } = await client.query('SELECT fraction FROM app.purchase_invoice_items($1)', [id]);
      expect(shown.fraction).toBe('10.000');
    });
  });

  it('aumentar põe a diferença no estoque', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const id = await invoiceFor(client, prod);
      await post(client, id);
      const [it] = await itemsOf(client, id);
      await changeFraction(client, it.id, 12);
      expect(await stockOf(client, prod.id)).toBe('24.000');
      expect(await averageCost(client, prod.id)).toBe('0.875000');
    });
  });

  it('nos lotes: a diferença vai na proporção de cada um; o último fica com a sobra', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 3 });
      await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
      const id = await invoiceFor(client, prod, {
        quantity: '3', productsValue: '30.00',
        batches: [
          { number: 'b2', quantity: '1', expiresOn: '2029-06-01' },
          { number: 'a1', quantity: '2', expiresOn: '2028-01-01' },
        ],
      });
      await post(client, id);
      const [it] = await itemsOf(client, id);
      await changeFraction(client, it.id, 2.5);
      expect(await balances(client, prod.id)).toEqual([{ batch_number: 'A1', quantity: '5.000' }, { batch_number: 'B2', quantity: '2.500' }]);

      // De 2,5 para 1,333: 7,5 vira 3,999; A1 fica com 2,666 e B2 com a sobra, 1,333.
      await changeFraction(client, it.id, 1.333);
      expect(await balances(client, prod.id)).toEqual([{ batch_number: 'A1', quantity: '2.666' }, { batch_number: 'B2', quantity: '1.333' }]);
      expect(await stockOf(client, prod.id)).toBe('3.999');
    });
  });

  it('com três lotes, o arredondamento não perde estoque: o último fica com a sobra', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 1.5 });
      await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
      const id = await invoiceFor(client, prod, {
        quantity: '1', productsValue: '10.00',
        batches: [
          { number: 'X1', quantity: '0.333', expiresOn: '2028-01-01' },
          { number: 'X2', quantity: '0.333', expiresOn: '2029-01-01' },
          { number: 'X3', quantity: '0.334', expiresOn: '2030-01-01' },
        ],
      });
      await post(client, id);
      const [it] = await itemsOf(client, id);
      // 0,5 de cada lote vira 0,333; o último fecha a conta em 1.
      await changeFraction(client, it.id, 1);
      expect(await balances(client, prod.id)).toEqual([
        { batch_number: 'X1', quantity: '0.333' }, { batch_number: 'X2', quantity: '0.333' }, { batch_number: 'X3', quantity: '0.334' },
      ]);
      expect(await stockOf(client, prod.id)).toBe('1.000');
    });
  });

  it('diminuir com parte já baixada: o Gerente não deixa negativo; quem tem a permissão deixa', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const id = await invoiceFor(client, prod);
      await post(client, id);
      await loss(client, prod, 15);
      const [it] = await itemsOf(client, id);
      await as(client, manager);
      await expectCode(client, () => changeFraction(client, it.id, 5), 'FA763');
      await changeFraction(client, it.id, 8);
      expect(await stockOf(client, prod.id)).toBe('1.000');
      await as(client, a.admin);
      await changeFraction(client, it.id, 5);
      expect(await stockOf(client, prod.id)).toBe('-5.000');
    });
  });

  it('recusa o mesmo fracionamento, valor inválido, nota não lançada e quem não lança', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const id = await invoiceFor(client, prod);
      const [it] = await itemsOf(client, id);
      await expectCode(client, () => changeFraction(client, it.id, 5), 'FA939');
      await post(client, id);
      await expectCode(client, () => changeFraction(client, it.id, 10), 'FA765');
      for (const bad of [0, -1, 1.2345, 10000000, null]) {
        await expectCode(client, () => changeFraction(client, it.id, bad), 'FA931');
      }
      await expectCode(client, () => changeFraction(client, it.id, 5, ''), 'FA302');
      await as(client, buyer);
      await expectCode(client, () => changeFraction(client, it.id, 5), 'FA002');
      await as(client, b.admin);
      await expectCode(client, () => changeFraction(client, it.id, 5), 'FA006');
    });
  });
});
