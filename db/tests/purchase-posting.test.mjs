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

describe('lançamento', () => {
  it('põe no estoque pela quantidade vezes o fracionamento, com custo de todos os valores do item', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const id = await invoiceFor(client, prod, {
        discount: '1.00', freight: '1.00', insurance: '0.50', other: '0.50', ipi: '0.30', st: '1.50', fcpSt: '0.20',
      });
      const [it] = await itemsOf(client, id);
      expect(it.match_source).toBe('barcode');
      const [before] = await posting(client, id);
      expect(before).toMatchObject({ stock_quantity: '20.000', unit_cost: '1.200000', average_cost: null, cost_status: 'first_entry', batch_status: 'not_required' });

      await post(client, id);
      expect(await statusOf(client, id)).toBe('posted');
      expect(await stockOf(client, prod.id)).toBe('20.000');
      expect(await averageCost(client, prod.id)).toBe('1.200000');
      const { rows: movements } = await client.query('SELECT * FROM v_stock_movement WHERE purchase_invoice_item_id = $1', [it.id]);
      expect(movements).toHaveLength(1);
      expect(movements[0]).toMatchObject({ movement_type: 'invoice', quantity: '20.000', batch_id: null });
      expect(movements[0].reason).toMatch(/^Nota \d+ série 1 de DISTRIBUIDORA DO LANCAMENTO LTDA$/);
      const { rows: events } = await client.query('SELECT kind, user_id, reason FROM v_purchase_invoice_event WHERE invoice_id = $1', [id]);
      expect(events).toEqual([{ kind: 'posted', user_id: a.admin.id, reason: null }]);

      const [after] = await posting(client, id);
      expect(after).toMatchObject({ cost_status: 'posted', unit_cost: '1.200000', average_cost: null, new_average_cost: '1.200000', stock_quantity: '20.000' });
    });
  });

  it('fracionamento da relação com o fornecedor vale sobre o do produto', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const supplierCode = `R-${randomBytes(3).toString('hex')}`;
      const emitterCnpj = cnpj();
      const supplierId = (await client.query('SELECT app.create_supplier($1::jsonb) AS id', [JSON.stringify({ cnpj: emitterCnpj, legalName: 'Fornecedor fração' })])).rows[0].id;
      await client.query('SELECT app.add_product_supplier($1, $2::jsonb)', [prod.id, JSON.stringify({ supplierId, supplierCode, fractionQuantity: 5 })]);
      const id = await importInvoice(client, invoice({ emitterCnpj, items: [item({ supplierCode, barcode: prod.code })] }));
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('10.000');
      expect(await averageCost(client, prod.id)).toBe('2.100000');
    });
  });

  it('média móvel sobre o saldo da filial; sem saldo, vale o custo da entrada', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      await post(client, await invoiceFor(client, prod, { quantity: '30', productsValue: '600.00' }));
      // (10 × 10 + 30 × 20) ÷ 40
      expect(await averageCost(client, prod.id)).toBe('17.500000');
      const { rows: [last] } = await client.query(
        'SELECT previous_cost, stock_before, entry_quantity, entry_cost FROM v_product_cost WHERE product_id = $1 ORDER BY id DESC LIMIT 1', [prod.id],
      );
      expect(last).toEqual({ previous_cost: '10.000000', stock_before: '10.000', entry_quantity: '30.000', entry_cost: '20.000000' });

      await loss(client, prod, 40);
      await post(client, await invoiceFor(client, prod, { quantity: '5', productsValue: '150.00' }));
      expect(await averageCost(client, prod.id)).toBe('30.000000');
    });
  });

  it('o saldo de outra filial não entra na média', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '500.00' }, { destCnpj: a.branch2.cnpj }));
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '300.00' }));
      // (10 × 10 + 10 × 30) ÷ 20: o custo e o saldo da outra filial ficam de fora.
      expect(await averageCost(client, prod.id)).toBe('20.000000');
      expect(await averageCost(client, prod.id, a.branch2.id)).toBe('50.000000');
    });
  });

  it('bonificação entra pelo valor líquido e baixa a média', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      await post(client, await invoiceFor(client, prod, { cfop: '6910', quantity: '10', productsValue: '100.00', discount: '100.00' }));
      expect(await averageCost(client, prod.id)).toBe('5.000000');
      // Desconto maior que o valor não vira custo negativo.
      const id = await invoiceFor(client, prod, { quantity: '20', productsValue: '10.00', discount: '15.00' });
      expect((await posting(client, id))[0].unit_cost).toBe('0.000000');
      await post(client, id);
      expect(await averageCost(client, prod.id)).toBe('2.500000');
    });
  });

  it('mesmo produto em dois itens da nota soma na ordem dos itens', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await importInvoice(client, invoice({ items: [
        item({ number: 1, barcode: prod.code, quantity: '10', productsValue: '100.00' }),
        item({ number: 2, barcode: prod.code, quantity: '10', productsValue: '300.00' }),
      ] }));
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('20.000');
      expect(await averageCost(client, prod.id)).toBe('20.000000');
    });
  });

  it('item sem produto barra a nota inteira', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await importInvoice(client, invoice({ items: [item({ number: 1, barcode: prod.code }), item({ number: 2 })] }));
      await expectCode(client, () => post(client, id), 'FA934');
      expect(await statusOf(client, id)).toBe('review');
      expect(await stockOf(client, prod.id)).toBe('0');
      expect((await client.query('SELECT 1 FROM product_cost WHERE product_id = $1', [prod.id])).rows).toEqual([]);
    });
  });

  it('nota lançada não se lança de novo, não se confere e não se descarta', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const other = await product(client);
      const id = await invoiceFor(client, prod);
      await post(client, id);
      const [it] = await itemsOf(client, id);
      await expectCode(client, () => post(client, id), 'FA938');
      await expectCode(client, () => client.query('SELECT app.link_purchase_item($1, $2)', [it.id, other.id]), 'FA932');
      await expectCode(client, () => setBatches(client, it.id, []), 'FA932');
      await expectCode(client, () => client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'errada']), 'FA940');
    });
  });

  it('nota fora do estoque não se lança', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, {}, { purpose: 4 });
      await expectCode(client, () => post(client, id), 'FA938');
    });
  });
});

describe('trava de custo', () => {
  it('sem regra de tolerância, só avisa', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' }));
      const id = await invoiceFor(client, prod, { quantity: '1', productsValue: '50.00' });
      const [row] = await posting(client, id);
      expect(row).toMatchObject({ cost_status: 'no_rule', average_cost: '10.000000', unit_cost: '50.000000', difference_percent: '400.00', tolerance: null });
      await post(client, id);
    });
  });

  it('acima da tolerância trava; no limite passa', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await toleranceRule(client, prod, 10);
      await post(client, await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' }));
      const limit = await invoiceFor(client, prod, { quantity: '1', productsValue: '11.00' });
      expect((await posting(client, limit))[0]).toMatchObject({ cost_status: 'ok', tolerance: '10.0000' });
      const above = await invoiceFor(client, prod, { quantity: '1', productsValue: '11.01' });
      expect((await posting(client, above))[0]).toMatchObject({ cost_status: 'locked', difference_percent: '10.10' });
      await expectCode(client, () => post(client, above), 'FA935');
      await post(client, limit);
    });
  });

  it('a primeira entrada não trava, mesmo com regra', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await toleranceRule(client, prod, 0);
      const id = await invoiceFor(client, prod);
      expect((await posting(client, id))[0].cost_status).toBe('first_entry');
      await post(client, id);
    });
  });

  it('liberação exige a permissão, o motivo e a trava; vale para o produto e o custo daquela hora', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const other = await product(client);
      await toleranceRule(client, prod, 5);
      await post(client, await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' }));
      const fine = await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' });
      const [fineItem] = await itemsOf(client, fine);
      await expectCode(client, () => release(client, fineItem.id), 'FA941');

      const id = await invoiceFor(client, prod, { quantity: '1', productsValue: '20.00' });
      const [it] = await itemsOf(client, id);
      await expectCode(client, () => release(client, it.id, ' '), 'FA302');
      await release(client, it.id);
      const [row] = await posting(client, id);
      expect(row.cost_status).toBe('released');
      expect(row.release).toMatchObject({ reason: 'Reajuste do fornecedor', releasedBy: a.admin.name, entryCost: 20, averageCost: 10, tolerance: 5 });
      await expectCode(client, () => release(client, it.id), 'FA941');

      // Trocar o produto e voltar: a liberação era do produto, mas a do outro produto não serve.
      await client.query('SELECT app.link_purchase_item($1, $2)', [it.id, other.id]);
      expect((await posting(client, id))[0].cost_status).toBe('first_entry');
      // O outro produto, com o mesmo custo médio e a mesma tolerância, continua travado: a liberação era do primeiro.
      await toleranceRule(client, other, 5);
      await post(client, await invoiceFor(client, other, { quantity: '1', productsValue: '10.00' }));
      expect((await posting(client, id))[0].cost_status).toBe('locked');
      await client.query('SELECT app.link_purchase_item($1, $2)', [it.id, prod.id]);
      expect((await posting(client, id))[0].cost_status).toBe('released');
      await post(client, id);
      expect(await averageCost(client, prod.id)).toBe('15.000000');
      // Nota lançada não recebe liberação, mesmo com o custo ainda acima do médio novo.
      await expectCode(client, () => release(client, it.id), 'FA932');
    });
  });

  it('custo diferente do liberado trava de novo', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await toleranceRule(client, prod, 5);
      await post(client, await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' }));
      const id = await invoiceFor(client, prod, { quantity: '1', productsValue: '30.00' });
      const [it] = await itemsOf(client, id);
      await release(client, it.id);
      // O fracionamento da relação muda o custo da linha: a liberação antiga não serve mais.
      await client.query('SELECT app.update_product_supplier($1, 2)', [it.product_supplier_id]);
      const [row] = await posting(client, id);
      expect(row).toMatchObject({ unit_cost: '15.000000', cost_status: 'locked' });
      await expectCode(client, () => post(client, id), 'FA935');
      await release(client, it.id);
      expect((await client.query('SELECT count(*)::int AS n FROM purchase_invoice_item_cost_release WHERE item_id = $1', [it.id])).rows[0].n).toBe(2);
      await post(client, id);
    });
  });

  it('o Gerente lança, mas não libera custo', async () => {
    const prod = { id: null, code: null };
    await asUser(a.admin.id, async (client) => {
      Object.assign(prod, await product(client));
      await toleranceRule(client, prod, 5);
      await post(client, await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' }));
      const locked = await invoiceFor(client, prod, { quantity: '1', productsValue: '20.00' });
      const fine = await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00' });
      const [it] = await itemsOf(client, locked);
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [manager.id]);
      await expectCode(client, () => release(client, it.id), 'FA002');
      await post(client, fine);
      expect(await statusOf(client, fine)).toBe('posted');
    });
  });
});

describe('lotes', () => {
  async function tracked(client, data = {}) {
    const prod = await product(client, data);
    await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
    return prod;
  }

  it('lotes do XML entram um a um, com o fracionamento e o MS da nota', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client, { fractionQuantity: 3 });
      const id = await invoiceFor(client, prod, {
        quantity: '3', productsValue: '30.00', anvisaCode: '1234567890123',
        batches: [
          { number: 'b2', quantity: '1', expiresOn: '2029-06-01' },
          { number: 'a1', quantity: '2', expiresOn: '2028-01-01' },
        ],
      });
      expect((await posting(client, id))[0]).toMatchObject({ batch_required: true, batch_status: 'ok' });
      await post(client, id);
      const { rows } = await client.query(
        `SELECT pb.batch_number, pb.expires_on::text, pb.ms_registration, m.quantity
           FROM v_stock_movement m JOIN v_product_batch pb ON pb.id = m.batch_id
          WHERE m.product_id = $1 ORDER BY pb.expires_on`, [prod.id],
      );
      expect(rows).toEqual([
        { batch_number: 'A1', expires_on: '2028-01-01', ms_registration: '1234567890123', quantity: '6.000' },
        { batch_number: 'B2', expires_on: '2029-06-01', ms_registration: '1234567890123', quantity: '3.000' },
      ]);
      expect(await averageCost(client, prod.id)).toBe('3.333333');
    });
  });

  it('o último lote fica com a sobra do arredondamento', async () => {
    await asUser(a.admin.id, async (client) => {
      // 0,333 × 1,5 arredonda para 0,500 em cada lote: o último fica com 0,500, e não 0,501.
      const prod = await tracked(client, { fractionQuantity: 1.5 });
      const id = await invoiceFor(client, prod, {
        quantity: '1', productsValue: '10.00',
        batches: [
          { number: 'X1', quantity: '0.333', expiresOn: '2028-01-01' },
          { number: 'X2', quantity: '0.333', expiresOn: '2029-01-01' },
          { number: 'X3', quantity: '0.334', expiresOn: '2030-01-01' },
        ],
      });
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('1.500');
      const { rows } = await client.query(
        'SELECT m.quantity FROM v_stock_movement m JOIN v_product_batch pb ON pb.id = m.batch_id WHERE m.product_id = $1 ORDER BY pb.batch_number', [prod.id],
      );
      expect(rows.map((r) => r.quantity)).toEqual(['0.500', '0.500', '0.500']);
    });
  });

  it('lote que já existe fica com o MS que tem e precisa ter a mesma validade', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client);
      await post(client, await invoiceFor(client, prod, { anvisaCode: '1111111111111', batches: [{ number: 'L1', quantity: '2', expiresOn: '2028-01-01' }] }));
      await post(client, await invoiceFor(client, prod, { anvisaCode: '2222222222222', batches: [{ number: 'L1', quantity: '2', expiresOn: '2028-01-01' }] }));
      const { rows } = await client.query('SELECT ms_registration FROM v_product_batch WHERE product_id = $1', [prod.id]);
      expect(rows).toEqual([{ ms_registration: '1111111111111' }]);
      expect(await stockOf(client, prod.id)).toBe('4.000');
      const id = await invoiceFor(client, prod, { batches: [{ number: 'L1', quantity: '2', expiresOn: '2030-01-01' }] });
      await expectCode(client, () => post(client, id), 'FA804');
    });
  });

  it('sem lote, com soma diferente ou vencido, não lança', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client);
      const missing = await invoiceFor(client, prod);
      expect((await posting(client, missing))[0].batch_status).toBe('missing');
      await expectCode(client, () => post(client, missing), 'FA936');

      const mismatch = await invoiceFor(client, prod, { batches: [{ number: 'L1', quantity: '1', expiresOn: '2028-01-01' }] });
      expect((await posting(client, mismatch))[0].batch_status).toBe('mismatch');
      await expectCode(client, () => post(client, mismatch), 'FA936');

      const expired = await invoiceFor(client, prod, { batches: [{ number: 'L1', quantity: '2', expiresOn: '2020-01-01' }] });
      expect((await posting(client, expired))[0].batch_status).toBe('expired');
      await expectCode(client, () => post(client, expired), 'FA937');
    });
  });

  it('lotes digitados trocam os do XML, que ficam guardados', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client);
      const id = await invoiceFor(client, prod, { batches: [{ number: 'ERRADO', quantity: '2', expiresOn: '2020-01-01' }] });
      const [it] = await itemsOf(client, id);
      await setBatches(client, it.id, [
        { number: ' n1 ', quantity: '1.5', expiresOn: '2028-01-01', manufacturedOn: '2026-01-01' },
        { number: 'N2', quantity: '0.5', expiresOn: '2029-01-01' },
      ]);
      const { rows } = await client.query(
        'SELECT batch_number, source, deleted_at IS NOT NULL AS gone FROM purchase_invoice_item_batch WHERE item_id = $1 ORDER BY batch_number', [it.id],
      );
      expect(rows).toEqual([
        { batch_number: 'ERRADO', source: 'xml', gone: true },
        { batch_number: 'N1', source: 'manual', gone: false },
        { batch_number: 'N2', source: 'manual', gone: false },
      ]);
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('2.000');
    });
  });

  it.each([
    ['sem número', [{ number: ' ', quantity: '1', expiresOn: '2028-01-01' }]],
    ['número longo', [{ number: 'X'.repeat(21), quantity: '1', expiresOn: '2028-01-01' }]],
    ['repetido', [{ number: 'a', quantity: '1', expiresOn: '2028-01-01' }, { number: 'A', quantity: '1', expiresOn: '2028-01-01' }]],
    ['quantidade zero', [{ number: 'A', quantity: '0', expiresOn: '2028-01-01' }]],
    ['quantidade inválida', [{ number: 'A', quantity: 'muito', expiresOn: '2028-01-01' }]],
    ['sem validade', [{ number: 'A', quantity: '1' }]],
    ['data inválida', [{ number: 'A', quantity: '1', expiresOn: '2028-02-31' }]],
    ['fabricação depois da validade', [{ number: 'A', quantity: '1', expiresOn: '2028-01-01', manufacturedOn: '2028-02-01' }]],
    ['não é lista', { number: 'A' }],
  ])('lote digitado inválido: %s', async (_label, batches) => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client);
      const [it] = await itemsOf(client, await invoiceFor(client, prod));
      await expectCode(client, () => setBatches(client, it.id, batches), 'FA936');
    });
  });

  it('mais de 50 lotes é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client);
      const [it] = await itemsOf(client, await invoiceFor(client, prod));
      const many = Array.from({ length: 51 }, (_, i) => ({ number: `L${i}`, quantity: '1', expiresOn: '2028-01-01' }));
      await expectCode(client, () => setBatches(client, it.id, many), 'FA936');
      await setBatches(client, it.id, many.slice(0, 50));
    });
  });

  it('produto que não controla lote ignora os lotes da nota', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, { batches: [{ number: 'L1', quantity: '2', expiresOn: '2020-01-01' }] });
      expect((await posting(client, id))[0].batch_status).toBe('not_required');
      await post(client, id);
      const { rows } = await client.query('SELECT batch_id FROM v_stock_movement WHERE product_id = $1', [prod.id]);
      expect(rows).toEqual([{ batch_id: null }]);
    });
  });
});

describe('PMC', () => {
  it('grava o PMC da nota para o estado e a região da filial, sem repetir o vigente', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SELECT app.set_branch_location($1, $2, $3)', [a.branch1.id, 'AM', 'manaus_free_zone']);
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { pmc: '25.90' }));
      await post(client, await invoiceFor(client, prod, { pmc: '25.90' }));
      await post(client, await invoiceFor(client, prod, { pmc: '0' }));
      const { rows } = await client.query('SELECT state, pmc_region, value, source FROM v_product_pmc WHERE product_id = $1', [prod.id]);
      expect(rows).toEqual([{ state: 'AM', pmc_region: 'manaus_free_zone', value: '25.90', source: 'invoice' }]);
    });
  });

  it('filial sem estado não grava PMC', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SELECT app.set_branch_location($1, NULL, NULL)', [a.branch1.id]);
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { pmc: '25.90' }));
      expect((await client.query('SELECT 1 FROM v_product_pmc WHERE product_id = $1', [prod.id])).rows).toEqual([]);
    });
  });
});

describe('estorno', () => {
  it('desfaz o estoque e o custo pela conta inversa e volta a nota para a conferência', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await toleranceRule(client, prod, 5);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      const id = await invoiceFor(client, prod, { quantity: '30', productsValue: '600.00' });
      const [it] = await itemsOf(client, id);
      await release(client, it.id);
      await post(client, id);
      expect(await averageCost(client, prod.id)).toBe('17.500000');

      await expectCode(client, () => reverse(client, id, ' '), 'FA302');
      await reverse(client, id);
      expect(await statusOf(client, id)).toBe('review');
      expect(await stockOf(client, prod.id)).toBe('10.000');
      expect(await averageCost(client, prod.id)).toBe('10.000000');
      const { rows: movements } = await client.query(
        'SELECT quantity, reason, reversal_of IS NOT NULL AS reversal FROM v_stock_movement WHERE purchase_invoice_item_id = $1 ORDER BY id', [it.id],
      );
      expect(movements).toEqual([
        { quantity: '30.000', reason: expect.stringMatching(/^Nota /), reversal: false },
        { quantity: '-30.000', reason: 'Produto ligado errado', reversal: true },
      ]);
      const { rows: events } = await client.query('SELECT kind, reason FROM v_purchase_invoice_event WHERE invoice_id = $1 ORDER BY id', [id]);
      expect(events).toEqual([{ kind: 'posted', reason: null }, { kind: 'reversed', reason: 'Produto ligado errado' }]);
      // A liberação cai junto: o lançamento de novo pede outra.
      expect((await posting(client, id))[0].cost_status).toBe('locked');
      await expectCode(client, () => reverse(client, id), 'FA939');

      await release(client, it.id);
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('40.000');
      expect(await averageCost(client, prod.id)).toBe('17.500000');
      await reverse(client, id);
      expect(await averageCost(client, prod.id)).toBe('10.000000');
    });
  });

  it('com venda no meio, a conta inversa usa o saldo de agora', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      const id = await invoiceFor(client, prod, { quantity: '10', productsValue: '300.00' });
      await post(client, id);
      await loss(client, prod, 5);
      // Saldo 15 a 20,00; tirar 10 a 30,00 deixa 5 a 0,00.
      await reverse(client, id);
      expect(await stockOf(client, prod.id)).toBe('5.000');
      expect(await averageCost(client, prod.id)).toBe('0.000000');
    });
  });

  it('conta inversa negativa volta o custo de antes da entrada', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      const id = await invoiceFor(client, prod, { quantity: '10', productsValue: '500.00' });
      await post(client, id);
      await loss(client, prod, 5);
      await reverse(client, id);
      expect(await averageCost(client, prod.id)).toBe('10.000000');
    });
  });

  it('estorno da primeira entrada deixa o produto sem custo', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      await post(client, id);
      await reverse(client, id);
      expect(await averageCost(client, prod.id)).toBeNull();
      expect((await posting(client, id))[0].cost_status).toBe('first_entry');
    });
  });

  it('se parte do que entrou já saiu, só quem pode deixar negativo estorna', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' });
      await post(client, id);
      await loss(client, prod, 1);
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [manager.id]);
      await expectCode(client, () => reverse(client, id), 'FA763');
      expect(await statusOf(client, id)).toBe('posted');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      await reverse(client, id);
      expect(await stockOf(client, prod.id)).toBe('-1.000');
      const { rows } = await client.query(
        'SELECT negative_allowed_by FROM v_stock_movement WHERE product_id = $1 AND reversal_of IS NOT NULL', [prod.id],
      );
      expect(rows).toEqual([{ negative_allowed_by: a.admin.id }]);
    });
  });

  it('estorna também os lotes', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
      const id = await invoiceFor(client, prod, { batches: [{ number: 'L1', quantity: '1', expiresOn: '2028-01-01' }, { number: 'L2', quantity: '1', expiresOn: '2029-01-01' }] });
      await post(client, id);
      await reverse(client, id);
      const { rows } = await client.query(
        `SELECT pb.batch_number, sb.quantity FROM v_stock_balance sb JOIN v_product_batch pb ON pb.id = sb.batch_id
          WHERE sb.product_id = $1 ORDER BY pb.batch_number`, [prod.id],
      );
      expect(rows).toEqual([{ batch_number: 'L1', quantity: '0.000' }, { batch_number: 'L2', quantity: '0.000' }]);
    });
  });
});

describe('permissões', () => {
  it('quem só confere não lança nem estorna; o Gerente lança e estorna', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [buyer.id]);
      await expectCode(client, () => post(client, id), 'FA002');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [manager.id]);
      await post(client, id);
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [buyer.id]);
      await expectCode(client, () => reverse(client, id), 'FA002');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [manager.id]);
      await reverse(client, id);
    });
  });

  it('o Gerente não lança em filial que não é dele', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, {}, { destCnpj: a.branch2.cnpj });
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [manager.id]);
      await expectCode(client, () => post(client, id), 'FA002');
      await expectCode(client, () => client.query('SELECT * FROM app.purchase_invoice_posting($1)', [id]), 'FA006');
    });
  });

  it('outro grupo não enxerga nem lança', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      const [it] = await itemsOf(client, id);
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [b.admin.id]);
      await expectCode(client, () => post(client, id), 'FA006');
      await expectCode(client, () => reverse(client, id), 'FA006');
      await expectCode(client, () => release(client, it.id), 'FA006');
      await expectCode(client, () => setBatches(client, it.id, []), 'FA006');
      await expectCode(client, () => client.query('SELECT * FROM app.purchase_invoice_posting($1)', [id]), 'FA006');
    });
  });

  it('custo médio só aparece para quem vê compras na filial', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod));
      await post(client, await invoiceFor(client, prod, {}, { destCnpj: a.branch2.cnpj }));
      const costs = await client.query('SELECT branch_id, average_cost, stock_quantity FROM app.product_average_costs($1)', [prod.id]);
      expect(costs.rows).toHaveLength(2);
      expect(costs.rows[0]).toMatchObject({ average_cost: '10.500000', stock_quantity: '2.000' });

      await client.query(`SELECT set_config('app.user_id', $1, true)`, [manager.id]);
      expect((await client.query('SELECT branch_id FROM app.product_average_costs($1)', [prod.id])).rows).toEqual([{ branch_id: a.branch1.id }]);
      expect((await client.query('SELECT DISTINCT branch_id FROM v_product_cost WHERE product_id = $1', [prod.id])).rows).toEqual([{ branch_id: a.branch1.id }]);
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.oneBranchUser.id]);
      expect((await client.query('SELECT 1 FROM app.product_average_costs($1)', [prod.id])).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_product_cost WHERE product_id = $1', [prod.id])).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_purchase_invoice_event')).rows).toEqual([]);
    });
  });

  it('a API não escreve direto nas tabelas novas', async () => {
    const client = await appPool.connect();
    try {
      for (const table of ['product_cost', 'purchase_invoice_item_cost_release', 'purchase_invoice_event']) {
        await expect(client.query(`DELETE FROM ${table}`)).rejects.toThrow(/permission denied/);
      }
      await expect(client.query('SELECT app.purchase_item_check(gen_random_uuid())')).rejects.toThrow(/permission denied/);
    } finally {
      client.release();
    }
  });
});

describe('integridade', () => {
  it('custo, liberação e histórico não mudam depois de gravados', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      const { rows: [{ id: productId }] } = await client.query(
        'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: 'Produto integridade', barcode: gtin() })],
      );
      const { rows: [{ code }] } = await client.query('SELECT code FROM product_barcode WHERE product_id = $1', [productId]);
      const id = await importInvoice(client, invoice({ items: [item({ barcode: code })] }));
      await post(client, id);
      for (const sql of [
        'UPDATE product_cost SET average_cost = 1 WHERE product_id = $1',
        'UPDATE product_cost SET deleted_at = now() WHERE product_id = $1',
        'UPDATE purchase_invoice_event SET reason = $1::text WHERE kind = \'posted\'',
        'UPDATE stock_movement SET quantity = 1 WHERE product_id = $1',
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql, [productId])).rejects.toSatisfy(hasCode('FA104'));
        await client.query('ROLLBACK TO s');
      }
      await client.query('SAVEPOINT s');
      await expect(client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, purchase_invoice_item_id)
         SELECT economic_group_id, branch_id, product_id, 'adjustment', 1, id FROM purchase_invoice_item WHERE invoice_id = $1`, [id],
      )).rejects.toSatisfy(hasCode('FA931'));
      await client.query('ROLLBACK TO s');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});

describe('saldo negativo e travas da tabela', () => {
  /** Como dono, com o usuário da API: permite gravar a venda offline que deixa o saldo negativo. */
  async function asOwnerUser(fn) {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      await fn(client);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  }
  const ownerExpect = async (client, sql, params, code) => {
    await client.query('SAVEPOINT s');
    await expect(client.query(sql, params)).rejects.toSatisfy(hasCode(code));
    await client.query('ROLLBACK TO s');
  };

  it('com saldo negativo pela venda offline, vale o custo da entrada', async () => {
    await asOwnerUser(async (client) => {
      const prod = await product(client);
      await post(client, await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' }));
      await client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, reason)
         VALUES ($1, $2, $3, 'sale', -12, 'Venda offline')`, [a.group.id, a.branch1.id, prod.id],
      );
      await post(client, await invoiceFor(client, prod, { quantity: '5', productsValue: '150.00' }));
      expect(await averageCost(client, prod.id)).toBe('30.000000');
    });
  });

  it('situação, origem do lote, estorno e liberação têm trava na tabela', async () => {
    await asOwnerUser(async (client) => {
      const prod = await product(client);
      await toleranceRule(client, prod, 5);
      await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
      const id = await invoiceFor(client, prod, { quantity: '1', productsValue: '10.00', batches: [{ number: 'L1', quantity: '1', expiresOn: '2028-01-01' }] });
      await post(client, id);
      await ownerExpect(client, "UPDATE purchase_invoice SET status = 'reversed' WHERE id = $1", [id], 'FA931');
      const [it] = await itemsOf(client, id);
      await ownerExpect(client, "UPDATE purchase_invoice_item_batch SET source = 'manual' WHERE item_id = $1", [it.id], 'FA104');

      await reverse(client, id);
      const { rows: [cost] } = await client.query('SELECT id FROM product_cost WHERE purchase_invoice_item_id = $1 AND reversal_of IS NOT NULL', [it.id]);
      await ownerExpect(
        client,
        `INSERT INTO product_cost (economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost, purchase_invoice_item_id, reversal_of)
         SELECT economic_group_id, branch_id, product_id, average_cost, previous_cost, stock_before, entry_quantity, entry_cost, purchase_invoice_item_id, reversal_of
           FROM product_cost WHERE id = $1`,
        [cost.id], 'FA939',
      );

      await post(client, id);
      const locked = await invoiceFor(client, prod, { quantity: '1', productsValue: '30.00', batches: [{ number: 'L1', quantity: '1', expiresOn: '2028-01-01' }] });
      const [lockedItem] = await itemsOf(client, locked);
      await release(client, lockedItem.id);
      await ownerExpect(
        client,
        `INSERT INTO purchase_invoice_item_cost_release (economic_group_id, branch_id, item_id, product_id, entry_cost, average_cost, tolerance, reason, released_by)
         SELECT economic_group_id, branch_id, item_id, product_id, entry_cost, average_cost, tolerance, 'de novo', released_by
           FROM purchase_invoice_item_cost_release WHERE item_id = $1`,
        [lockedItem.id], 'FA941',
      );
    });
  });
});
