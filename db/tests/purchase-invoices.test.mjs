import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;
let manager;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows } = await ownerPool.query(
    `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Gerente notas') RETURNING *`, [a.group.id],
  );
  manager = rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [manager.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
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
    emitter: {
      cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA DA NOTA LTDA', tradeName: 'DISTRIBUIDORA DA NOTA', stateRegistration: '110042490114',
      phone: '1133334444', postalCode: '01001000', street: 'RUA DE TESTE', streetNumber: '100', district: 'CENTRO', city: 'SAO PAULO',
      cityCode: '3550308', state: 'SP',
    },
    totals: { products: '21.00', invoice: '21.00' },
    items: [item()],
    ...overrides,
  };
}
const XML = '<nfeProc>conteúdo de teste</nfeProc>';
const importInvoice = (client, data, acceptsTest = true) =>
  client.query('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, $4) AS id', [
    JSON.stringify(data), XML, createHash('sha256').update(XML).digest('hex'), acceptsTest,
  ]).then((r) => r.rows[0].id);
const itemsOf = (client, invoiceId) =>
  client.query('SELECT * FROM purchase_invoice_item WHERE invoice_id = $1 ORDER BY item_number', [invoiceId]).then((r) => r.rows);
const createProduct = (client, data = {}) =>
  client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto ${randomBytes(4).toString('hex')}`, barcode: gtin(), ...data })])
    .then((r) => r.rows[0].id);
const createSupplier = (client, supplierCnpj) =>
  client.query('SELECT app.create_supplier($1::jsonb) AS id', [JSON.stringify({ cnpj: supplierCnpj, legalName: 'Fornecedor cadastrado' })]).then((r) => r.rows[0].id);
const link = (client, itemId, productId) =>
  client.query('SELECT app.link_purchase_item($1, $2) AS r', [itemId, productId]).then((r) => r.rows[0].r);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('importação', () => {
  it('grava a nota na filial do destinatário, com itens, lotes e o XML', async () => {
    await asUser(a.admin.id, async (client) => {
      const data = invoice({
        items: [
          item({ number: 1, batches: [{ number: 'l1', quantity: '2', manufacturedOn: '2026-01-01', expiresOn: '2028-01-01' }], anvisaCode: '1234567890123', pmc: '25.90' }),
          item({ number: 2, barcode: 'SEMGTIN', st: '1.50', fcpSt: '0.20', ipi: '0.30' }),
        ],
      });
      const id = await importInvoice(client, data);
      const { rows: [row] } = await client.query('SELECT * FROM v_purchase_invoice WHERE id = $1', [id]);
      expect(row).toMatchObject({ branch_id: a.branch1.id, status: 'review', not_postable_reason: null, access_key: data.accessKey, environment: 2 });
      const items = await itemsOf(client, id);
      expect(items.map((it) => it.item_number)).toEqual([1, 2]);
      expect(items[1]).toMatchObject({ st_value: '1.50', fcp_st_value: '0.20', ipi_value: '0.30', product_id: null });
      const { rows: batches } = await client.query('SELECT batch_number, expires_on::text FROM v_purchase_invoice_item_batch WHERE item_id = $1', [items[0].id]);
      expect(batches).toEqual([{ batch_number: 'L1', expires_on: '2028-01-01' }]);
      const { rows: [doc] } = await client.query('SELECT xml, sha256 FROM purchase_invoice_document WHERE invoice_id = $1', [id]);
      expect(doc.xml).toBe(XML);
      expect(doc.sha256).toHaveLength(64);
    });
  });

  it('cria o fornecedor pelo emitente e reaproveita o que já existe', async () => {
    await asUser(a.admin.id, async (client) => {
      const fresh = invoice();
      const id = await importInvoice(client, fresh);
      const { rows: [supplier] } = await client.query(
        'SELECT s.* FROM v_supplier s JOIN v_purchase_invoice i ON i.supplier_id = s.id WHERE i.id = $1', [id],
      );
      expect(supplier).toMatchObject({ cnpj: fresh.emitter.cnpj, legal_name: 'DISTRIBUIDORA DA NOTA LTDA', state: 'SP', state_registration: '110042490114', city_code: '3550308' });

      const existing = cnpj();
      const supplierId = await createSupplier(client, existing);
      const second = await importInvoice(client, invoice({ emitterCnpj: existing }));
      const { rows: [row] } = await client.query('SELECT supplier_id FROM v_purchase_invoice WHERE id = $1', [second]);
      expect(row.supplier_id).toBe(supplierId);
    });
  });

  it('inscrição do emitente que não confere fica de fora, sem travar a nota', async () => {
    await asUser(a.admin.id, async (client) => {
      const data = invoice();
      data.emitter.stateRegistration = '110042490115';
      const id = await importInvoice(client, data);
      const { rows: [supplier] } = await client.query(
        'SELECT s.state_registration FROM v_supplier s JOIN v_purchase_invoice i ON i.supplier_id = s.id WHERE i.id = $1', [id],
      );
      expect(supplier.state_registration).toBeNull();
    });
  });

  it('recusa destinatário fora da rede, inclusive filial de outro grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => importInvoice(client, invoice({ destCnpj: cnpj() })), 'FA927');
      await expectCode(client, () => importInvoice(client, invoice({ destCnpj: b.branch1.cnpj })), 'FA927');
    });
  });

  it('nota de teste só entra onde o ambiente aceita', async () => {
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => importInvoice(client, invoice({ environment: 2 }), false), 'FA928');
      await expect(importInvoice(client, invoice({ environment: 1 }), false)).resolves.toBeTruthy();
    });
  });

  it('a mesma chave não entra duas vezes, e volta a entrar depois de descartada', async () => {
    await asUser(a.admin.id, async (client) => {
      const data = invoice();
      const id = await importInvoice(client, data);
      await expectCode(client, () => importInvoice(client, data), 'FA929');
      await expectCode(client, () => client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, ' ']), 'FA302');
      await client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'Importada na filial errada']);
      expect((await client.query('SELECT 1 FROM v_purchase_invoice WHERE id = $1', [id])).rows).toEqual([]);
      expect((await client.query('SELECT discard_reason FROM purchase_invoice WHERE id = $1', [id])).rows[0].discard_reason).toBe('Importada na filial errada');
      await expect(importInvoice(client, data)).resolves.not.toBe(id);
      await expectCode(client, () => client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'de novo']), 'FA006');
    });
  });

  it.each([
    ['emitida por filial da rede', () => invoice({ emitterCnpj: a.branch2.cnpj }), 'own_branch'],
    ['nota de entrada', () => invoice({ operationType: 0 }), 'entry'],
    ['devolução', () => invoice({ purpose: 4 }), 'purpose'],
    ['complementar', () => invoice({ purpose: 2 }), 'purpose'],
  ])('%s fica registrada, fora do estoque e sem ligar itens', async (_label, build, reason) => {
    await asUser(a.admin.id, async (client) => {
      const productId = await createProduct(client);
      const { rows: [barcode] } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1', [productId]);
      const data = build();
      data.items = [item({ barcode: barcode.code })];
      const id = await importInvoice(client, data);
      const { rows: [row] } = await client.query('SELECT status, not_postable_reason FROM v_purchase_invoice WHERE id = $1', [id]);
      expect(row).toEqual({ status: 'not_postable', not_postable_reason: reason });
      expect((await itemsOf(client, id))[0].product_id).toBeNull();
      const [pending] = await itemsOf(client, id);
      await expectCode(client, () => link(client, pending.id, productId), 'FA932');
    });
  });

  it.each([
    ['chave com dígito errado', (d) => ({ ...d, accessKey: d.accessKey.slice(0, 43) + String((Number(d.accessKey[43]) + 1) % 10) })],
    ['nota sem itens', (d) => ({ ...d, items: [] })],
    ['quantidade zero', (d) => ({ ...d, items: [item({ quantity: '0' })] })],
    ['CFOP fora do formato', (d) => ({ ...d, items: [item({ cfop: '9999' })] })],
    ['lote vencendo antes de fabricar', (d) => ({ ...d, items: [item({ batches: [{ number: 'X', quantity: '1', manufacturedOn: '2028-01-02', expiresOn: '2028-01-01' }] })] })],
    ['registro Anvisa fora do formato', (d) => ({ ...d, items: [item({ anvisaCode: '123' })] })],
  ])('recusa %s com FA931', async (_label, change) => {
    await asUser(a.admin.id, async (client) => {
      await expect(importInvoice(client, change(invoice()))).rejects.toSatisfy(hasCode('FA931'));
    });
  });

  it('item repetido na nota é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(importInvoice(client, invoice({ items: [item({ number: 1 }), item({ number: 1 })] }))).rejects.toSatisfy(hasCode('FA929'));
    });
  });
});

describe('permissões e visibilidade', () => {
  it('o Gerente importa e vê só a filial dele', async () => {
    await asUser(a.admin.id, async (client) => {
      const other = await importInvoice(client, invoice({ destCnpj: a.branch2.cnpj }));
      await setUser(client, manager.id);
      const own = await importInvoice(client, invoice());
      await expectCode(client, () => importInvoice(client, invoice({ destCnpj: a.branch2.cnpj })), 'FA002');
      const visible = (await client.query('SELECT id FROM v_purchase_invoice')).rows.map((r) => r.id);
      expect(visible).toContain(own);
      expect(visible).not.toContain(other);
      expect((await client.query('SELECT id FROM app.list_purchase_invoices()')).rows.map((r) => r.id)).not.toContain(other);
      await expectCode(client, () => client.query('SELECT app.discard_purchase_invoice($1, $2)', [other, 'x']), 'FA002');
    });
  });

  it('sem purchases.manage não importa, e sem purchases.view não vê', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await setUser(client, a.oneBranchUser.id);
      await expectCode(client, () => importInvoice(client, invoice()), 'FA002');
      expect((await client.query('SELECT 1 FROM v_purchase_invoice WHERE id = $1', [id])).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_purchase_invoice_item WHERE invoice_id = $1', [id])).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM purchase_invoice_document WHERE invoice_id = $1', [id])).rows).toEqual([]);
    });
  });

  it('outro grupo não vê nem descarta', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM v_purchase_invoice WHERE id = $1', [id])).rows).toEqual([]);
      await expectCode(client, () => client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'x']), 'FA006');
    });
  });

  it('a API não escreve direto, e o que veio do XML não muda', async () => {
    const { id, itemId } = await committed(async (client) => {
      const created = await importInvoice(client, invoice());
      return { id: created, itemId: (await itemsOf(client, created))[0].id };
    });
    await asUser(a.admin.id, async (client) => {
      await expect(client.query('UPDATE purchase_invoice SET status = $1 WHERE id = $2', ['review', id])).rejects.toMatchObject({ code: '42501' });
    });
    for (const change of ['invoice_total = 1', "access_key = 'x'", `branch_id = '${a.branch2.id}'::uuid`]) {
      await expect(ownerPool.query(`UPDATE purchase_invoice SET ${change} WHERE id = $1`, [id]), change).rejects.toSatisfy(hasCode('FA104'));
    }
    await expect(ownerPool.query('UPDATE purchase_invoice_item SET quantity = 99 WHERE id = $1', [itemId])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query("UPDATE purchase_invoice_document SET xml = 'x' WHERE invoice_id = $1", [id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('DELETE FROM purchase_invoice_item WHERE id = $1', [itemId])).rejects.toSatisfy(hasCode('FA103'));
    // Descartar direto na tabela também exige o motivo.
    await expect(ownerPool.query('UPDATE purchase_invoice SET deleted_at = now() WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA931'));
  });
});

async function committed(fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, a.admin.id);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

describe('ligação automática', () => {
  it('o código é do fornecedor: o mesmo código de outro fornecedor não liga', async () => {
    await asUser(a.admin.id, async (client) => {
      const other = await createSupplier(client, cnpj());
      const productId = await createProduct(client);
      await client.query('SELECT app.add_product_supplier($1, $2::jsonb)', [productId, JSON.stringify({ supplierId: other, supplierCode: 'MESMO-COD' })]);
      const id = await importInvoice(client, invoice({ items: [item({ supplierCode: 'MESMO-COD' })] }));
      expect((await itemsOf(client, id))[0].product_id).toBeNull();
    });
  });

  it('relação que aponta produto encerrado não liga, nem pelo código de barras', async () => {
    const data = invoice();
    const fixture = await committed(async (client) => {
      const supplierId = await createSupplier(client, data.emitter.cnpj);
      const ended = await createProduct(client);
      await client.query('SELECT app.add_product_supplier($1, $2::jsonb)', [ended, JSON.stringify({ supplierId, supplierCode: data.items[0].supplierCode })]);
      const alive = await createProduct(client);
      const { rows: [barcode] } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1', [alive]);
      return { ended, code: barcode.code };
    });
    await ownerPool.query('UPDATE product SET deleted_at = now() WHERE id = $1', [fixture.ended]);
    await asUser(a.admin.id, async (client) => {
      data.items[0].barcode = fixture.code;
      const id = await importInvoice(client, data);
      expect((await itemsOf(client, id))[0].product_id).toBeNull();
    });
  });

  it('código interno da loja e código de barras de outro grupo não ligam', async () => {
    await asUser(a.admin.id, async (client) => {
      const internal = `INT${randomInt(1e8)}`;
      await createProduct(client, { barcode: internal, barcodeIsInternal: true });
      await setUser(client, b.admin.id);
      const foreign = await createProduct(client);
      const { rows: [barcode] } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1', [foreign]);
      await setUser(client, a.admin.id);
      const id = await importInvoice(client, invoice({ items: [item({ number: 1, barcode: internal }), item({ number: 2, barcode: barcode.code })] }));
      expect((await itemsOf(client, id)).map((it) => it.product_id)).toEqual([null, null]);
    });
  });

  it('pelo código do fornecedor, com o fracionamento da relação', async () => {
    await asUser(a.admin.id, async (client) => {
      const data = invoice();
      const supplierId = await createSupplier(client, data.emitter.cnpj);
      const productId = await createProduct(client);
      await client.query('SELECT app.add_product_supplier($1, $2::jsonb)', [productId, JSON.stringify({ supplierId, supplierCode: data.items[0].supplierCode, fractionQuantity: 12 })]);
      const id = await importInvoice(client, data);
      const [row] = (await client.query('SELECT * FROM app.purchase_invoice_items($1)', [id])).rows;
      expect(row).toMatchObject({ product_id: productId, match_source: 'supplier_code', fraction: '12.000', stock_quantity: '24.000' });
    });
  });

  it('pelo código de barras, criando a relação com o fornecedor', async () => {
    await asUser(a.admin.id, async (client) => {
      const productId = await createProduct(client);
      const { rows: [barcode] } = await client.query('SELECT id, code FROM v_product_barcode WHERE product_id = $1', [productId]);
      await client.query('SELECT app.update_barcode($1, $2::jsonb)', [barcode.id, JSON.stringify({ fractionQuantity: 6, scanEnabled: true, sendsToSupplier: true, channels: [] })]);
      const data = invoice({ items: [item({ barcode: barcode.code })] });
      const id = await importInvoice(client, data);
      const [row] = await itemsOf(client, id);
      expect(row).toMatchObject({ product_id: productId, barcode_id: barcode.id, match_source: 'barcode' });
      const { rows: [relation] } = await client.query('SELECT product_id, supplier_code FROM v_product_supplier WHERE id = $1', [row.product_supplier_id]);
      expect(relation).toEqual({ product_id: productId, supplier_code: data.items[0].supplierCode });
      const [view] = (await client.query('SELECT fraction, stock_quantity FROM app.purchase_invoice_items($1)', [id])).rows;
      expect(view).toEqual({ fraction: '6.000', stock_quantity: '12.000' });

      // A próxima nota do mesmo fornecedor já se liga pelo código.
      const next = await importInvoice(client, invoice({ emitterCnpj: data.emitter.cnpj, items: [item({ supplierCode: data.items[0].supplierCode })] }));
      expect((await itemsOf(client, next))[0]).toMatchObject({ product_id: productId, match_source: 'supplier_code' });
    });
  });

  it('não liga por código de barras inválido, desconhecido ou de produto encerrado', async () => {
    const ended = await committed(async (client) => {
      const productId = await createProduct(client);
      const { rows: [barcode] } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1', [productId]);
      return { productId, code: barcode.code };
    });
    await ownerPool.query('UPDATE product SET deleted_at = now() WHERE id = $1', [ended.productId]);
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice({
        items: [item({ number: 1, barcode: '7891234567890' }), item({ number: 2, barcode: gtin() }), item({ number: 3, barcode: ended.code })],
      }));
      expect((await itemsOf(client, id)).map((it) => it.product_id)).toEqual([null, null, null]);
    });
  });
});

describe('conferência', () => {
  it('ligar à mão cria a relação, acrescenta o código de barras e liga os iguais de outras notas', async () => {
    await asUser(a.admin.id, async (client) => {
      const ean = gtin();
      const emitter = cnpj();
      const code = 'MANUAL-1';
      const first = await importInvoice(client, invoice({ emitterCnpj: emitter, items: [item({ supplierCode: code, barcode: ean })] }));
      const second = await importInvoice(client, invoice({ emitterCnpj: emitter, items: [item({ supplierCode: code })] }));
      const productId = await createProduct(client);
      const [pending] = await itemsOf(client, first);
      expect(await link(client, pending.id, productId)).toEqual({ barcodeAdded: true, barcodeConflict: false });
      expect((await itemsOf(client, first))[0]).toMatchObject({ product_id: productId, match_source: 'manual' });
      expect((await itemsOf(client, second))[0]).toMatchObject({ product_id: productId, match_source: 'supplier_code' });
      const { rows: codes } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1 ORDER BY is_primary DESC', [productId]);
      expect(codes.map((r) => r.code)).toContain(ean);
    });
  });

  it('código de barras de outro produto só avisa, e trocar o produto move a relação', async () => {
    await asUser(a.admin.id, async (client) => {
      const owner = await createProduct(client);
      const { rows: [barcode] } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1', [owner]);
      const id = await importInvoice(client, invoice({ items: [item({ barcode: barcode.code })] }));
      const [auto] = await itemsOf(client, id);
      expect(auto.product_id).toBe(owner);
      const chosen = await createProduct(client);
      expect(await link(client, auto.id, chosen)).toEqual({ barcodeAdded: false, barcodeConflict: true });
      const [after] = await itemsOf(client, id);
      expect(after).toMatchObject({ product_id: chosen, barcode_id: null, match_source: 'manual' });
      const { rows: relations } = await client.query(
        'SELECT product_id FROM v_product_supplier WHERE supplier_code = $1 AND supplier_id = (SELECT supplier_id FROM purchase_invoice WHERE id = $2)',
        [auto.supplier_code, id],
      );
      expect(relations).toEqual([{ product_id: chosen }]);
      expect((await client.query('SELECT count(*)::int AS n FROM v_product_barcode WHERE code = $1', [barcode.code])).rows[0].n).toBe(1);
    });
  });

  it('ligar de novo ao mesmo produto não cria relação repetida', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      const productId = await createProduct(client);
      const [pending] = await itemsOf(client, id);
      await link(client, pending.id, productId);
      await link(client, pending.id, productId);
      const { rows } = await client.query('SELECT count(*)::int AS n FROM v_product_supplier WHERE product_id = $1', [productId]);
      expect(rows[0].n).toBe(1);
    });
  });

  it('produto de outro grupo, item inexistente e quem não pode', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      const [pending] = await itemsOf(client, id);
      await setUser(client, b.admin.id);
      const foreign = await createProduct(client);
      await expectCode(client, () => link(client, pending.id, foreign), 'FA006');
      await setUser(client, a.admin.id);
      await expectCode(client, () => link(client, pending.id, foreign), 'FA004');
      await setUser(client, a.oneBranchUser.id);
      const own = await (async () => { await setUser(client, a.admin.id); const p = await createProduct(client); await setUser(client, a.oneBranchUser.id); return p; })();
      await expectCode(client, () => link(client, pending.id, own), 'FA002');
    });
  });

  it('duplicar cadastro copia a estrutura e liga o item', async () => {
    await asUser(a.admin.id, async (client) => {
      const { rows: [category] } = await client.query(
        `SELECT app.create_product_category(NULL, $1) AS id`, [`Depto ${randomBytes(3).toString('hex')}`],
      );
      const { rows: [cat2] } = await client.query('SELECT app.create_product_category($1, $2) AS id', [category.id, 'Categoria']);
      const { rows: [sub] } = await client.query('SELECT app.create_product_category($1, $2) AS id', [cat2.id, 'Sub']);
      const source = await createProduct(client, { categoryId: sub.id, usesPmc: true });
      const ean = gtin();
      const id = await importInvoice(client, invoice({ items: [item({ barcode: ean, description: 'NOVO ITEM 10MG' })] }));
      const [pending] = await itemsOf(client, id);
      const { rows: [{ id: created }] } = await client.query('SELECT app.duplicate_product_for_item($1, $2, $3::jsonb) AS id', [pending.id, source, '{}']);
      const { rows: [product] } = await client.query('SELECT display_name, category_id, uses_pmc FROM v_product WHERE id = $1', [created]);
      expect(product).toEqual({ display_name: 'NOVO ITEM 10MG', category_id: sub.id, uses_pmc: true });
      expect((await itemsOf(client, id))[0]).toMatchObject({ product_id: created, match_source: 'duplicate' });
      const { rows: [primary] } = await client.query('SELECT code FROM v_product_barcode WHERE product_id = $1 AND is_primary', [created]);
      expect(primary.code).toBe(ean);
    });
  });

  it('item sem código de barras precisa de um para duplicar, e aceita código interno', async () => {
    await asUser(a.admin.id, async (client) => {
      const source = await createProduct(client);
      const id = await importInvoice(client, invoice());
      const [pending] = await itemsOf(client, id);
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.duplicate_product_for_item($1, $2, $3::jsonb)', [pending.id, source, '{}'])).rejects.toBeTruthy();
      await client.query('ROLLBACK TO s');
      const { rows: [{ id: created }] } = await client.query('SELECT app.duplicate_product_for_item($1, $2, $3::jsonb) AS id', [
        pending.id, source, JSON.stringify({ barcode: `INT${randomInt(1e6)}`, barcodeIsInternal: true }),
      ]);
      expect(created).toBeTruthy();
    });
  });

  it('cadastrar pelo Catálogo liga o item ao produto novo, vinculado ao Catálogo', async () => {
    const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [
      JSON.stringify({ sourceKey: `nota-${randomBytes(4).toString('hex')}`, name: 'Item do Catálogo' }),
    ])).rows[0].id;
    await asUser(a.admin.id, async (client) => {
      const ean = gtin();
      const id = await importInvoice(client, invoice({ items: [item({ barcode: ean })] }));
      const [pending] = await itemsOf(client, id);
      const { rows: [{ id: created }] } = await client.query('SELECT app.create_product_for_item($1, $2::jsonb) AS id', [
        pending.id, JSON.stringify({ catalogProductId: catalogId, displayName: 'Item do Catálogo' }),
      ]);
      expect((await client.query('SELECT catalog_product_id FROM v_product WHERE id = $1', [created])).rows[0].catalog_product_id).toBe(catalogId);
      expect((await itemsOf(client, id))[0]).toMatchObject({ product_id: created, match_source: 'catalog' });
    });
  });

  it('cadastrar exige também a permissão de produtos', async () => {
    await asUser(a.admin.id, async (client) => {
      const source = await createProduct(client);
      const id = await importInvoice(client, invoice({ items: [item({ barcode: gtin() })] }));
      const [pending] = await itemsOf(client, id);
      await setUser(client, manager.id);
      await expectCode(client, () => client.query('SELECT app.duplicate_product_for_item($1, $2, $3::jsonb)', [pending.id, source, '{}']), 'FA002');
    });
  });

  it('avisa MS diferente do Catálogo e PMC abaixo do preço de venda', async () => {
    const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [
      JSON.stringify({ sourceKey: `ms-${randomBytes(4).toString('hex')}`, name: 'Com MS', msRegistration: '1000000000001' }),
    ])).rows[0].id;
    await asUser(a.admin.id, async (client) => {
      const productId = await createProduct(client, { catalogProductId: catalogId });
      await client.query('SELECT app.set_product_price($1, NULL, 30, NULL)', [productId]);
      const id = await importInvoice(client, invoice({ items: [item({ anvisaCode: '1000000000002', pmc: '20.00' })] }));
      const [pending] = await itemsOf(client, id);
      await link(client, pending.id, productId);
      const [row] = (await client.query('SELECT * FROM app.purchase_invoice_items($1)', [id])).rows;
      expect(row).toMatchObject({ ms_differs: true, catalog_ms: '1000000000001', pmc_below_price: true, sale_price: '30.00' });
    });
  });

  it('MS igual ao do Catálogo não gera aviso', async () => {
    const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [
      JSON.stringify({ sourceKey: `ms-igual-${randomBytes(4).toString('hex')}`, name: 'MS igual', msRegistration: '1000000000003' }),
    ])).rows[0].id;
    await asUser(a.admin.id, async (client) => {
      const productId = await createProduct(client, { catalogProductId: catalogId });
      const id = await importInvoice(client, invoice({ items: [item({ anvisaCode: '1000000000003' })] }));
      const [pending] = await itemsOf(client, id);
      await link(client, pending.id, productId);
      const [row] = (await client.query('SELECT ms_differs FROM app.purchase_invoice_items($1)', [id])).rows;
      expect(row.ms_differs).toBe(false);
    });
  });

  it('item de nota descartada não se liga mais', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      const [pending] = await itemsOf(client, id);
      const productId = await createProduct(client);
      await client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'Errada']);
      await expectCode(client, () => link(client, pending.id, productId), 'FA006');
    });
  });

  it('a lista conta os itens que faltam conferir', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice({ items: [item({ number: 1 }), item({ number: 2 })] }));
      const productId = await createProduct(client);
      const [first] = await itemsOf(client, id);
      await link(client, first.id, productId);
      const { rows: [row] } = await client.query('SELECT item_count, pending_count FROM app.list_purchase_invoices($1, $2) WHERE id = $3', [a.branch1.id, 'review', id]);
      expect(row).toEqual({ item_count: '2', pending_count: '1' });
    });
  });
});
