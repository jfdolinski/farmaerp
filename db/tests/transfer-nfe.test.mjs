import { createHash, randomBytes, randomInt, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot } from './helpers.mjs';

// NF-e de transferência entre filiais, emitida pela central na origem. A transferência de estoque
// continua imediata; a nota só acompanha a mercadoria, pelo custo médio da origem.

let a;
let b;

const fiscal = {
  state: 'SP', street: 'Rua das Flores', street_number: '100', district: 'Centro', city: 'São Paulo', city_code: '3550308',
  postal_code: '01001000',
};
const setFiscal = (branchId, data = {}) => {
  const values = { ...fiscal, state_registration: '110042490114', ...data };
  const columns = Object.keys(values);
  return ownerPool.query(
    `UPDATE branch SET ${columns.map((c, i) => `${c} = $${i + 2}`).join(', ')} WHERE id = $1`,
    [branchId, ...Object.values(values)],
  );
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  await setFiscal(a.branch1.id);
  await setFiscal(a.branch2.id, { street: 'Rua Dois' });
  await setFiscal(a.branchFree.id, { state: 'RJ', state_registration: '12345674', city: 'Rio de Janeiro', city_code: '3304557', postal_code: '20010000' });
  await ownerPool.query('UPDATE company SET tax_regime = 1 WHERE id = $1', [a.company.id]);
});
afterAll(closePools);

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
const XML = '<nfeProc>conteúdo de teste</nfeProc>';
/** Produto pelo Catálogo (que traz o NCM); sem NCM, um produto sem Catálogo. */
async function newProduct(client, code, ncm = '30049099') {
  let catalogProductId = null;
  if (ncm) {
    catalogProductId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
      sourceKey: `transf-${randomBytes(6).toString('hex')}`, name: 'Item Transferência Teste', ncm,
      manufacturer: `Fabricante ${randomBytes(3).toString('hex')}`, barcodes: [code],
    })])).rows[0].id;
  }
  return (await client.query('SELECT app.create_product($1::jsonb) AS id', [
    JSON.stringify({ displayName: `Produto ${randomBytes(4).toString('hex')}`, barcode: code, catalogProductId }),
  ])).rows[0].id;
}
/** Produto com custo médio e saldo na filial 1 (nota de compra lançada: 4 unidades a R$ 10). */
async function stocked(client, { ncm = '30049099', quantity = '4', unitPrice = '10' } = {}) {
  const code = gtin();
  const id = await newProduct(client, code, ncm);
  const emitterCnpj = branchCnpj(randomRoot(), 1);
  const number = randomInt(1, 999_999_999);
  const value = (Number(quantity) * Number(unitPrice)).toFixed(2);
  const invoiceId = (await client.query('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, true) AS id', [
    JSON.stringify({
      accessKey: accessKey(emitterCnpj, number), series: 1, number, issuedAt: '2026-11-20T10:00:00-03:00', operationType: 1,
      purpose: 1, environment: 2, protocolNumber: '135260000000001', authorizedAt: '2026-11-20T10:00:05-03:00',
      destCnpj: a.branch1.cnpj, emitter: { cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA DA TRANSFERENCIA LTDA', state: 'SP' },
      totals: { products: value, invoice: value },
      items: [{
        number: 1, supplierCode: `C-${randomBytes(3).toString('hex')}`, barcode: code, description: 'ITEM DE TESTE', ncm: '30049099',
        cfop: '5102', unit: 'UN', quantity, unitPrice, productsValue: value, batches: [],
      }],
    }), XML, createHash('sha256').update(XML).digest('hex'),
  ])).rows[0].id;
  await client.query('SELECT app.post_purchase_invoice($1)', [invoiceId]);
  return { id, code };
}
const transfer = (client, prod, { to = a.branch2.id, quantity = 2, reason = 'Reposição da loja' } = {}) =>
  client.query('SELECT app.transfer_stock($1::jsonb) AS id', [JSON.stringify({
    fromBranchId: a.branch1.id, toBranchId: to, productLookup: prod.code, quantity, reason,
  })]).then((r) => r.rows[0].id);
const prepare = (client, id) => client.query('SELECT app.transfer_nfe_prepare($1) AS x', [id]).then((r) => r.rows[0].x);
const store = (client, prepared) => client.query(
  'SELECT app.transfer_nfe_store($1, $2, $3, $4, $5, $6, $7, $8) AS id',
  [prepared.transferId, prepared.series, prepared.number,
    // Chave única no banco inteiro: o código numérico sorteado evita colidir com outros testes em paralelo.
    `3526119988776600011155${String(prepared.series).padStart(3, '0')}${String(prepared.number).padStart(9, '0')}1${String(randomInt(1e8)).padStart(8, '0')}0`,
    2, '<NFe>' + 'x'.repeat(200) + '</NFe>', '2026-11-27T16:00:00Z', prepared.totalValue],
).then((r) => r.rows[0].id);
const result = (client, id, value) => client.query('SELECT app.central_nfe_result($1, $2::jsonb) AS s', [id, JSON.stringify(value)]).then((r) => r.rows[0].s);
async function asOwnerUser(userId, fn) {
  const client = await ownerPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [userId]);
    return await fn(client);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('NF-e de transferência entre filiais', () => {
  it('prepara a nota da origem para o destino, pelo custo médio, com o CFOP de transferência', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await stocked(client);
      const id = await transfer(client, prod, { quantity: 3 });
      const prepared = await prepare(client, id);
      expect(prepared).toMatchObject({ transferId: id, branchId: a.branch1.id, state: 'SP', totalValue: 30 });
      expect(prepared.input).toMatchObject({
        issuer: { cnpj: a.branch1.cnpj, uf: 'SP', taxRegime: 1 },
        recipient: { cnpj: a.branch2.cnpj, ieIndicator: 1, stateRegistration: '110042490114', uf: 'SP' },
        operation: 'TRANSFERENCIA DE MERCADORIA', purpose: 1, finalConsumer: false, references: [],
      });
      expect(prepared.input.items).toEqual([expect.objectContaining({
        gtin: prod.code, ncm: '30049099', unit: 'UN', quantityMilli: 3000, unitPriceCents: 1000, grossCents: 3000,
        tax: expect.objectContaining({ cfop: '5152', icms_csosn: '102', pis_cst: '49', cofins_cst: '49' }),
      })]);
      expect(prepared.input.additionalInfo).toContain('Reposição da loja');
    });
  });

  it('com ST na venda usa o CFOP 5409; fora do estado, 6152; a regra da filial muda o CFOP', async () => {
    // Como dono, numa transação só: a regra de tributação própria do produto entra direto na tabela.
    await asOwnerUser(a.admin.id, async (client) => {
      const prod = await stocked(client);
      await client.query(
        `INSERT INTO product_tax_rule (economic_group_id, product_id, tax_regime, state, cfop, origin, icms_csosn, pis_cst, cofins_cst, source_emitted_at)
         VALUES ($1, $2, 1, 'SP', '5405', 0, '500', '04', '04', now())`, [a.group.id, prod.id],
      );
      const st = await prepare(client, await transfer(client, prod, { quantity: 1 }));
      expect(st.input.items[0].tax).toMatchObject({ cfop: '5409', icms_csosn: '500' });
      const other = await stocked(client);
      const away = await prepare(client, await transfer(client, other, { to: a.branchFree.id, quantity: 1 }));
      expect(away.input.items[0].tax.cfop).toBe('6152');
      expect(away.input.recipient).toMatchObject({ uf: 'RJ', cnpj: a.branchFree.cnpj });
      await client.query('SELECT app.set_return_tax_setting($1, $2::jsonb)', [a.branch1.id, JSON.stringify({ transfer_cfop_internal: '5151' })]);
      const changed = await prepare(client, await transfer(client, other, { quantity: 1 }));
      expect(changed.input.items[0].tax.cfop).toBe('5151');
    });
  });

  it('pendente segura a transferência; recusada pode emitir de novo, com outro número', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await stocked(client);
      const id = await transfer(client, prod);
      const first = await prepare(client, id);
      const nfe = await store(client, first);
      expect((await client.query('SELECT id, state FROM app.transfer_nfe_pending($1)', [id])).rows).toEqual([{ id: nfe, state: 'SP' }]);
      await expectCode(client, () => prepare(client, id), 'FA776');
      const listed = (await client.query('SELECT app.transfer_nfes($1::uuid[]) AS x', [[id]])).rows[0].x;
      expect(listed[id]).toMatchObject({ id: nfe, status: 'pending', number: first.number, can_issue: true });
      expect(await result(client, nfe, { kind: 'rejected', status_code: '539', reason: 'Duplicidade' })).toBe('rejected');
      const again = await prepare(client, id);
      expect(again.number).toBe(first.number + 1);
      const second = await store(client, again);
      expect(await result(client, second, {
        kind: 'authorized', protocol: '135260000000099', authorized_at: '2026-11-27T16:01:00Z', xml: '<nfeProc>' + 'y'.repeat(200) + '</nfeProc>',
        status_code: '100', reason: 'Autorizado',
      })).toBe('authorized');
      expect((await client.query('SELECT app.transfer_nfes($1::uuid[]) AS x', [[id]])).rows[0].x[id]).toMatchObject({ id: second, status: 'authorized' });
      expect((await client.query('SELECT status FROM app.central_nfe_xml($1)', [second])).rows).toEqual([{ status: 'authorized' }]);
      expect((await client.query('SELECT kind, transfer_group, purchase_return_id FROM central_nfe WHERE id = $1', [second])).rows)
        .toEqual([{ kind: 'transfer', transfer_group: id, purchase_return_id: null }]);
      await expectCode(client, () => prepare(client, id), 'FA776');
      // Cancelada: a transferência fica e aceita NF-e nova; a lista mostra a mais nova.
      expect(await client.query('SELECT app.central_nfe_cancel_register($1, $2::jsonb) AS s', [second, JSON.stringify({
        reason: 'Quantidade transferida errada', protocol: '135260000000903', status_code: '135',
        xml: '<procEventoNFe>' + 'e'.repeat(200) + '</procEventoNFe>', registered_at: new Date().toISOString(),
      })]).then((x) => x.rows[0].s)).toBe('canceled');
      expect((await client.query('SELECT app.transfer_nfes($1::uuid[]) AS x', [[id]])).rows[0].x[id])
        .toMatchObject({ id: second, status: 'canceled', cancel_reason: 'Quantidade transferida errada', cancelable_until: null });
      const third = await store(client, await prepare(client, id));
      expect((await client.query('SELECT app.transfer_nfes($1::uuid[]) AS x', [[id]])).rows[0].x[id]).toMatchObject({ id: third, status: 'pending' });
      await expectCode(client, () => prepare(client, id), 'FA776');
    });
  });

  it('sem NCM, sem custo médio, entre empresas diferentes ou com o destino sem dados fiscais, avisa', async () => {
    await asUser(a.admin.id, async (client) => {
      const noNcm = await stocked(client, { ncm: null });
      await expectCode(client, async () => prepare(client, await transfer(client, noNcm)), 'FA779');

      // Saldo por ajuste, sem nota de compra: sem custo médio.
      const code = gtin();
      await newProduct(client, code);
      await client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({ branchId: a.branch1.id, direction: 'in', quantity: 5, productLookup: code, reason: 'Acerto' })]);
      await expectCode(client, async () => prepare(client, await transfer(client, { code })), 'FA778');

      const prod = await stocked(client);
      const id = await transfer(client, prod);
      await ownerPool.query('UPDATE branch SET street = NULL WHERE id = $1', [a.branch2.id]);
      try {
        await expectCode(client, () => prepare(client, id), 'FA724');
      } finally {
        await ownerPool.query("UPDATE branch SET street = 'Rua Dois' WHERE id = $1", [a.branch2.id]);
      }
    });
    // Filial de outra empresa do mesmo grupo (outra raiz do CNPJ).
    const root = randomRoot();
    const company = (await ownerPool.query(
      "INSERT INTO company (economic_group_id, legal_name, trade_name, cnpj_root, tax_regime) VALUES ($1, 'Outra Ltda', 'Outra', $2, 1) RETURNING id",
      [a.group.id, root],
    )).rows[0].id;
    const other = (await ownerPool.query(
      'INSERT INTO branch (company_id, name, cnpj) VALUES ($1, $2, $3) RETURNING id', [company, 'Filial outra empresa', branchCnpj(root, 1)],
    )).rows[0].id;
    await setFiscal(other);
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [a.admin.id, other]).catch(() => {});
    await asUser(a.admin.id, async (client) => {
      const prod = await stocked(client);
      await expectCode(client, async () => prepare(client, await transfer(client, prod, { to: other })), 'FA777');
    });
  });

  it('só quem emite NF-e na origem; outro grupo e transferência que não existe ficam de fora', async () => {
    let id;
    const owner = await ownerPool.connect();
    try {
      await owner.query('BEGIN');
      await owner.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      const prod = await stocked(owner);
      id = await transfer(owner, prod);
      await owner.query('COMMIT');
    } finally {
      owner.release();
    }
    await asUser(a.oneBranchUser.id, async (client) => {
      await expectCode(client, () => prepare(client, id), 'FA002');
      await expectCode(client, () => client.query('SELECT * FROM app.transfer_nfe_certificate($1)', [id]), 'FA002');
    });
    await asUser(b.admin.id, async (client) => {
      await expectCode(client, () => prepare(client, id), 'FA006');
      await expectCode(client, () => client.query('SELECT * FROM app.transfer_nfe_pending($1)', [id]), 'FA006');
      expect((await client.query('SELECT app.transfer_nfes($1::uuid[]) AS x', [[id]])).rows[0].x).toEqual({});
    });
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => prepare(client, randomUUID()), 'FA006');
      // Certificado: a origem ainda não tem.
      const { rows } = await client.query('SELECT company_id, encrypted_pfx FROM app.transfer_nfe_certificate($1)', [id]);
      expect(rows).toEqual([{ company_id: a.company.id, encrypted_pfx: null }]);
    });
  });

  it('número fora da reserva não é guardado; a pendente de uma transferência não aparece na outra', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await transfer(client, await stocked(client));
      const second = await transfer(client, await stocked(client));
      const prepared = await prepare(client, first);
      await expectCode(client, () => store(client, { ...prepared, number: prepared.number + 5 }), 'FA931');
      const nfe = await store(client, prepared);
      await store(client, await prepare(client, second));
      expect((await client.query('SELECT id FROM app.transfer_nfe_pending($1)', [first])).rows).toEqual([{ id: nfe }]);
    });
  });

  it('a nota da transferência sempre tem a transferência; duas vivas para a mesma não entram', async () => {
    await asOwnerUser(a.admin.id, async (client) => {
      const id = await transfer(client, await stocked(client));
      const nfe = (await client.query('SELECT * FROM central_nfe WHERE id = $1', [await store(client, await prepare(client, id))])).rows[0];
      const copy = (overrides) => client.query(
        `INSERT INTO central_nfe (economic_group_id, branch_id, kind, transfer_group, series, number, access_key, environment, status, xml,
                                  total_value, emitted_at, user_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, 2, 'pending', $8, 1, now(), $9)`,
        [nfe.economic_group_id, nfe.branch_id, overrides.kind ?? 'transfer', overrides.group === undefined ? id : overrides.group,
          nfe.series, nfe.number + 100, `${nfe.access_key.slice(0, 30)}${String(randomInt(1e9)).padStart(9, '0')}${nfe.access_key.slice(39)}`,
          nfe.xml, nfe.user_id],
      );
      await client.query('SAVEPOINT s');
      await expect(copy({ group: null })).rejects.toMatchObject({ constraint: 'central_nfe_source_check' });
      await client.query('ROLLBACK TO s');
      await expect(copy({})).rejects.toMatchObject({ constraint: 'central_nfe_transfer_live_key' });
      await client.query('ROLLBACK TO s');
    });
  });

  it('quem vê o estoque (sem ver compras) baixa o XML da nota de transferência', async () => {
    const role = (await ownerPool.query(
      'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING id', [a.group.id, `Estoque ${randomBytes(3).toString('hex')}`],
    )).rows[0].id;
    await ownerPool.query("INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'stock.view'", [role]);
    const viewer = (await ownerPool.query(
      'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING id', [a.group.id, 'Consulta estoque'],
    )).rows[0].id;
    await ownerPool.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [viewer, role]);
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [viewer, a.branch1.id]);
    const client = await ownerPool.connect();
    let nfe;
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      const id = await transfer(client, await stocked(client));
      nfe = await store(client, await prepare(client, id));
      await client.query('COMMIT');
    } finally {
      client.release();
    }
    await asUser(viewer, async (c) => {
      expect((await c.query('SELECT status FROM app.central_nfe_xml($1)', [nfe])).rows).toEqual([{ status: 'pending' }]);
    });
  });
});
