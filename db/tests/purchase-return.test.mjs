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
  // O cancelar não vem no Gerente padrão: a rede dá no perfil (aqui, um perfil a mais do gerente).
  const { rows: [canceller] } = await ownerPool.query(
    `INSERT INTO role (economic_group_id, name) VALUES ($1, 'Cancela nota') RETURNING *`, [a.group.id],
  );
  await ownerPool.query(
    `INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code IN ('purchases.cancel', 'purchases.return')`, [canceller.id],
  );
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, canceller.id, a.branch1.id]);
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
const devolve = (client, id, items, reason = 'Embalagem avariada') =>
  client.query('SELECT app.return_purchase_items($1, $2::jsonb, $3) AS id', [id, JSON.stringify(items), reason]).then((r) => r.rows[0].id);
const as = (client, user) => client.query(`SELECT set_config('app.user_id', $1, true)`, [user.id]);
const returnsOf = (client, id) => client.query('SELECT app.purchase_invoice_returns($1) AS x', [id]).then((r) => r.rows[0].x);
const audit = (client, id) => client.query('SELECT app.purchase_invoice_extra($1) AS x', [id]).then((r) => r.rows[0].x.audit);
const tracked = async (client, data = {}) => {
  const prod = await product(client, data);
  await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod.id, a.branch1.id]);
  return prod;
};
const batchId = (client, prod, number) =>
  client.query('SELECT id FROM v_product_batch WHERE product_id = $1 AND batch_number = $2', [prod.id, number]).then((r) => r.rows[0].id);
const balances = (client, productId) =>
  client.query(
    `SELECT pb.batch_number, sb.quantity FROM v_stock_balance sb JOIN v_product_batch pb ON pb.id = sb.batch_id
      WHERE sb.product_id = $1 ORDER BY pb.batch_number`, [productId],
  ).then((r) => r.rows);

describe('devolução ao fornecedor', () => {
  it('espelho da nota: mesmo preço e valores na proporção; sai do estoque pelo custo da entrada', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const before = await invoiceFor(client, prod, { quantity: '2', productsValue: '40.00' });
      await post(client, before);
      const id = await invoiceFor(client, prod, {
        quantity: '4', unitPrice: '10', productsValue: '40.00', discount: '4.00', freight: '2.00', ipi: '1.20', st: '0.80',
      });
      await post(client, id);
      expect(await stockOf(client, prod.id)).toBe('60.000');
      // 20 a 2,00 e 40 a 1,00: média 1,333333.
      expect(await averageCost(client, prod.id)).toBe('1.333333');
      const [it] = await itemsOf(client, id);

      const returnId = await devolve(client, id, [{ itemId: it.id, quantity: 10 }]);
      expect(await stockOf(client, prod.id)).toBe('50.000');
      // Sai 10 a 1,00 (custo da entrada): (60 × 1,333333 − 10) ÷ 50.
      expect(await averageCost(client, prod.id)).toBe('1.400000');
      const { rows: [ret] } = await client.query('SELECT * FROM purchase_return WHERE id = $1', [returnId]);
      expect(ret).toMatchObject({
        number: 1, reason: 'Embalagem avariada', user_id: a.admin.id, products_value: '10.00', discount_value: '1.00',
        freight_value: '0.50', ipi_value: '0.30', st_value: '0.20', total_value: '10.00',
      });
      const { rows: [line] } = await client.query('SELECT * FROM purchase_return_item WHERE return_id = $1', [returnId]);
      expect(line).toMatchObject({
        quantity: '10.000', invoice_quantity: '1.0000', unit_price: '10.0000000000', products_value: '10.00', total_value: '10.00',
        unit_cost: '1.000000', batch_id: null,
      });
      const { rows: [movement] } = await client.query('SELECT * FROM v_stock_movement WHERE purchase_return_item_id = $1', [line.id]);
      expect(movement).toMatchObject({ movement_type: 'supplier_return', quantity: '-10.000', negative_allowed_by: null });
      expect(movement.reason).toMatch(/^Devolução 1 ao fornecedor da nota \d+: Embalagem avariada$/);
      expect((await audit(client, id))[0]).toMatchObject({ kind: 'returned', detail: { number: 1, items: 1, total: 10, reason: 'Embalagem avariada' } });
      // A situação do item continua mostrando a entrada (não a linha de custo da devolução).
      expect((await posting(client, id))[0]).toMatchObject({ unit_cost: '1.000000', stock_quantity: '40.000' });
    });
  });

  it('a devolução que fecha o item leva o que sobrou, para os centavos baterem com a nota', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, { quantity: '3', productsValue: '10.00' });
      await post(client, id);
      const [it] = await itemsOf(client, id);
      for (let n = 0; n < 3; n += 1) await devolve(client, id, [{ itemId: it.id, quantity: 1 }]);
      const { rows } = await client.query('SELECT number, products_value FROM purchase_return WHERE invoice_id = $1 ORDER BY number', [id]);
      expect(rows).toEqual([
        { number: 1, products_value: '3.33' }, { number: 2, products_value: '3.33' }, { number: 3, products_value: '3.34' },
      ]);
      expect(await stockOf(client, prod.id)).toBe('0.000');
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 1 }]), 'FA768');
      const view = await returnsOf(client, id);
      expect(view.items[0]).toMatchObject({ entered: 3, returned: 3, available: 0, unit: 'UN', fractional: false, invoice_unit: 'CX' });
      expect(view.returns.map((r) => r.number)).toEqual([1, 2, 3]);
    });
  });

  it('com lote: escolhe o lote do item, até o que entrou nele', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await tracked(client, { fractionQuantity: 3 });
      const id = await invoiceFor(client, prod, {
        quantity: '3', productsValue: '30.00',
        batches: [{ number: 'b2', quantity: '1', expiresOn: '2029-06-01' }, { number: 'a1', quantity: '2', expiresOn: '2028-01-01' }],
      });
      await post(client, id);
      const [it] = await itemsOf(client, id);
      const a1 = await batchId(client, prod, 'A1');
      const b2 = await batchId(client, prod, 'B2');
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 1 }]), 'FA770');
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 4, batchId: b2 }]), 'FA768');
      await devolve(client, id, [{ itemId: it.id, quantity: 2, batchId: a1 }, { itemId: it.id, quantity: 3, batchId: b2 }]);
      expect(await balances(client, prod.id)).toEqual([{ batch_number: 'A1', quantity: '4.000' }, { batch_number: 'B2', quantity: '0.000' }]);
      const view = await returnsOf(client, id);
      expect(view.items[0]).toMatchObject({ entered: 9, returned: 5, available: 4 });
      expect(view.items[0].batches).toEqual([
        expect.objectContaining({ batch_number: 'A1', entered: 6, returned: 2, available: 4 }),
        expect.objectContaining({ batch_number: 'B2', entered: 3, returned: 3, available: 0 }),
      ]);
      expect(view.returns[0].items.map((x) => x.batch_number)).toEqual(['A1', 'B2']);
    });
  });

  it('unidade inteira só aceita inteiro (menos para fechar o lote); KG aceita fração', async () => {
    await asUser(a.admin.id, async (client) => {
      const whole = await product(client);
      const id = await invoiceFor(client, whole, { quantity: '2', productsValue: '20.00' });
      await post(client, id);
      const [it] = await itemsOf(client, id);
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 0.5 }]), 'FA769');
      for (const bad of [0, -1, 1.2345, 'x']) {
        await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: bad }]), 'FA931');
      }

      const kg = await product(client, { unit: 'KG' });
      const kgNote = await invoiceFor(client, kg, { quantity: '2', productsValue: '20.00' });
      await post(client, kgNote);
      const [kgItem] = await itemsOf(client, kgNote);
      await devolve(client, kgNote, [{ itemId: kgItem.id, quantity: 0.35 }]);
      expect(await stockOf(client, kg.id)).toBe('1.650');

      // Fracionamento 1,5: entraram 1,5; o meio que sobra fecha o item mesmo sendo UN.
      const half = await product(client, { fractionQuantity: 1.5 });
      const halfNote = await invoiceFor(client, half, { quantity: '1', productsValue: '15.00' });
      await post(client, halfNote);
      const [halfItem] = await itemsOf(client, halfNote);
      await devolve(client, halfNote, [{ itemId: halfItem.id, quantity: 1 }]);
      await devolve(client, halfNote, [{ itemId: halfItem.id, quantity: 0.5 }]);
      expect(await stockOf(client, half.id)).toBe('0.000');
    });
  });

  it('o que entrou já saiu: sem a permissão de negativo, recusa; com ela, devolve e registra quem liberou', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod, { quantity: '10', productsValue: '100.00' });
      await post(client, id);
      await loss(client, prod, 8);
      const [it] = await itemsOf(client, id);
      await as(client, manager);
      await devolve(client, id, [{ itemId: it.id, quantity: 2 }]);
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 3 }]), 'FA763');
      await as(client, a.admin);
      await devolve(client, id, [{ itemId: it.id, quantity: 3 }]);
      expect(await stockOf(client, prod.id)).toBe('-3.000');
      const { rows } = await client.query(
        `SELECT negative_allowed_by FROM v_stock_movement WHERE product_id = $1 AND movement_type = 'supplier_return' ORDER BY id`, [prod.id],
      );
      expect(rows).toEqual([{ negative_allowed_by: null }, { negative_allowed_by: a.admin.id }]);
    });
  });

  it('nota com devolução não se estorna, não se cancela e não muda o fracionamento', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client, { fractionQuantity: 10 });
      const id = await invoiceFor(client, prod);
      await post(client, id);
      const [it] = await itemsOf(client, id);
      await devolve(client, id, [{ itemId: it.id, quantity: 5 }]);
      await expectCode(client, () => reverse(client, id), 'FA767');
      await expectCode(client, () => client.query('SELECT app.cancel_purchase_invoice($1, $2)', [id, 'Errada']), 'FA767');
      await expectCode(client, () => client.query('SELECT app.change_purchase_item_fraction($1, 5, $2)', [it.id, 'Caixa com 5']), 'FA767');
      expect(await statusOf(client, id)).toBe('posted');
      expect(await stockOf(client, prod.id)).toBe('15.000');
    });
  });

  it('recusa sem permissão, de outro grupo, nota não lançada, sem motivo, sem itens e item de outra nota', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await product(client);
      const id = await invoiceFor(client, prod);
      const [it] = await itemsOf(client, id);
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 1 }]), 'FA939');
      await post(client, id);
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 1 }], ' '), 'FA302');
      await expectCode(client, () => devolve(client, id, []), 'FA931');
      const other = await invoiceFor(client, await product(client));
      const [otherItem] = await itemsOf(client, other);
      await expectCode(client, () => devolve(client, id, [{ itemId: otherItem.id, quantity: 1 }]), 'FA004');
      await as(client, buyer);
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 1 }]), 'FA002');
      expect((await returnsOf(client, id)).can_return).toBe(false);
      await as(client, b.admin);
      await expectCode(client, () => devolve(client, id, [{ itemId: it.id, quantity: 1 }]), 'FA006');
      await as(client, a.admin);
      expect((await returnsOf(client, id)).can_return).toBe(true);
    });
  });

  it('devolver não vem dado a nenhum perfil padrão; a API não escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(
      `SELECT r.name FROM role_permission rp JOIN role r ON r.id = rp.role_id JOIN permission p ON p.id = rp.permission_id
        WHERE p.code = 'purchases.return' AND r.economic_group_id = $1 AND r.system_key IS NULL AND r.name <> 'Cancela nota'
          AND rp.deleted_at IS NULL`,
      [a.group.id],
    );
    expect(rows).toEqual([]);
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT s');
      await expect(client.query(`UPDATE purchase_return SET reason = 'x'`)).rejects.toThrow();
      await client.query('ROLLBACK TO s');
    });
  });

  it('controlado devolvido vai ao SNGPC como perda', async () => {
    const { rows: [row] } = await ownerPool.query(`SELECT app.sngpc_kind_for('supplier_return', -1) AS kind`);
    expect(row.kind).toBe('loss');
  });
});
