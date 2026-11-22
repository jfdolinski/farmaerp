import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, setUser,
} from './helpers.mjs';

let a;
let b;
// Usuário do grupo A só com o perfil Gerente, gravado de verdade para valer em outras conexões.
let manager;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows } = await ownerPool.query(
    `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Gerente fornecedores') RETURNING *`,
    [a.group.id],
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
const createSupplier = (client, data = {}) =>
  client.query('SELECT app.create_supplier($1::jsonb) AS id', [JSON.stringify({ cnpj: cnpj(), legalName: 'Distribuidora Teste Ltda', ...data })])
    .then((r) => r.rows[0].id);
const createProduct = (client, data = {}) =>
  client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto ${randomBytes(4).toString('hex')}`, barcode: gtin(), ...data })])
    .then((r) => r.rows[0].id);
const link = (client, productId, supplierId, data = {}) =>
  client.query('SELECT app.add_product_supplier($1, $2::jsonb) AS id', [productId, JSON.stringify({ supplierId, supplierCode: `C-${randomBytes(4).toString('hex')}`, ...data })])
    .then((r) => r.rows[0].id);
const fraction = (client, productId, barcodeId = null, relationId = null) =>
  client.query('SELECT app.effective_fraction($1, $2, $3) AS f', [productId, barcodeId, relationId]).then((r) => Number(r.rows[0].f));
async function committedAsAdmin(fn) {
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
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('cadastro do fornecedor', () => {
  it('limpa a pontuação, guarda o endereço e confere a inscrição com o estado', async () => {
    await asUser(a.admin.id, async (client) => {
      const raw = cnpj();
      const masked = `${raw.slice(0, 2)}.${raw.slice(2, 5)}.${raw.slice(5, 8)}/${raw.slice(8, 12)}-${raw.slice(12)}`;
      const id = await createSupplier(client, {
        cnpj: masked, legalName: '  Distribuidora Ação Ltda ', tradeName: 'Ação', stateRegistration: '110.042.490.114', state: 'sp',
        phone: '(11) 3333-4444', email: 'Compras@Exemplo.test', postalCode: '01001-000', city: 'São Paulo', cityCode: '3550308',
      });
      const { rows: [row] } = await client.query('SELECT * FROM v_supplier WHERE id = $1', [id]);
      expect(row).toMatchObject({
        cnpj: raw, legal_name: 'Distribuidora Ação Ltda', state: 'SP', state_registration: '110042490114',
        phone: '1133334444', email: 'compras@exemplo.test', postal_code: '01001000',
      });
    });
  });

  it.each([
    ['CNPJ inválido', { cnpj: '11111111111111' }, 'FA902'],
    ['CNPJ vazio', { cnpj: '' }, 'FA902'],
    ['razão social vazia', { legalName: ' ' }, 'FA924'],
    ['inscrição sem estado', { stateRegistration: '110042490114' }, 'FA924'],
    ['inscrição com dígito errado', { stateRegistration: '110042490115', state: 'SP' }, 'FA924'],
    ['telefone curto', { phone: '1234' }, 'FA924'],
    ['e-mail sem domínio', { email: 'compras@' }, 'FA924'],
    ['estado inexistente', { state: 'ZZ' }, 'FA924'],
    ['código IBGE curto', { cityCode: '123' }, 'FA924'],
  ])('recusa %s', async (_label, data, code) => {
    await asUser(a.admin.id, async (client) => {
      await expect(createSupplier(client, data)).rejects.toSatisfy(hasCode(code));
    });
  });

  it('aceita ISENTO e CNPJ alfanumérico', async () => {
    await asUser(a.admin.id, async (client) => {
      const alpha = branchCnpj('AB1C2D3E', 1);
      const id = await createSupplier(client, { cnpj: alpha.toLowerCase(), stateRegistration: 'isento', state: 'PR' });
      const { rows: [row] } = await client.query('SELECT cnpj, state_registration FROM v_supplier WHERE id = $1', [id]);
      expect(row).toEqual({ cnpj: alpha, state_registration: 'ISENTO' });
    });
  });

  it('o mesmo CNPJ não entra duas vezes no grupo, mas pode existir em outro grupo', async () => {
    const shared = cnpj();
    await asUser(a.admin.id, async (client) => {
      await createSupplier(client, { cnpj: shared });
      await expectCode(client, () => createSupplier(client, { cnpj: shared }), 'FA923');
      await setUser(client, b.admin.id);
      await expect(createSupplier(client, { cnpj: shared })).resolves.toBeTruthy();
    });
  });

  it('encerrado libera o CNPJ para um cadastro novo', async () => {
    await asUser(a.admin.id, async (client) => {
      const shared = cnpj();
      const id = await createSupplier(client, { cnpj: shared });
      await client.query('SELECT app.delete_supplier($1)', [id]);
      await expect(createSupplier(client, { cnpj: shared })).resolves.not.toBe(id);
    });
  });

  it('a edição não mexe no CNPJ, e o CNPJ não muda nem direto na tabela', async () => {
    await asUser(a.admin.id, async (client) => {
      const original = cnpj();
      const id = await createSupplier(client, { cnpj: original });
      await client.query('SELECT app.update_supplier($1, $2::jsonb)', [id, JSON.stringify({ cnpj: cnpj(), legalName: 'Novo nome' })]);
      const { rows: [row] } = await client.query('SELECT cnpj, legal_name FROM v_supplier WHERE id = $1', [id]);
      expect(row).toEqual({ cnpj: original, legal_name: 'Novo nome' });
      await expectCode(client, () => client.query('SELECT app.update_supplier($1, $2::jsonb)', [id, '{"legalName": ""}']), 'FA924');
    });
    const { rows: [{ id }] } = await ownerPool.query(
      `INSERT INTO supplier (economic_group_id, cnpj, legal_name) VALUES ($1, $2, 'Direto') RETURNING id`, [a.group.id, cnpj()],
    );
    await expect(ownerPool.query('UPDATE supplier SET cnpj = $1 WHERE id = $2', [cnpj(), id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('DELETE FROM supplier WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA103'));
  });

  it('editar ou encerrar o que não existe ou é de outro grupo responde FA006', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await createSupplier(client);
      await setUser(client, b.admin.id);
      await expectCode(client, () => client.query('SELECT app.update_supplier($1, $2::jsonb)', [id, '{"legalName": "X"}']), 'FA006');
      await expectCode(client, () => client.query('SELECT app.delete_supplier($1)', [id]), 'FA006');
    });
  });
});

describe('permissões e visibilidade', () => {
  it('o Gerente vê e cadastra, porque recebe a nota da loja', async () => {
    await asUser(manager.id, async (client) => {
      const id = await createSupplier(client);
      const { rows } = await client.query('SELECT 1 FROM v_supplier WHERE id = $1', [id]);
      expect(rows).toHaveLength(1);
    });
  });

  it('sem purchases.manage não altera, e sem purchases.view não enxerga', async () => {
    const id = await asUser(a.admin.id, async (client) => {
      const created = await createSupplier(client);
      await setUser(client, a.oneBranchUser.id);
      await expectCode(client, () => createSupplier(client), 'FA002');
      await expectCode(client, () => client.query('SELECT app.update_supplier($1, $2::jsonb)', [created, '{"legalName": "X"}']), 'FA002');
      await expectCode(client, () => client.query('SELECT app.delete_supplier($1)', [created]), 'FA002');
      expect((await client.query('SELECT 1 FROM v_supplier WHERE id = $1', [created])).rows).toEqual([]);
      return created;
    });
    expect(id).toBeTruthy();
  });

  it('outro grupo não enxerga o fornecedor nem os códigos', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client);
      await link(client, productId, supplierId);
      await setUser(client, b.admin.id);
      expect((await client.query('SELECT 1 FROM v_supplier WHERE id = $1', [supplierId])).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_product_supplier WHERE supplier_id = $1', [supplierId])).rows).toEqual([]);
      expect((await client.query('SELECT * FROM app.search_suppliers($1)', [''])).rows.map((r) => r.id)).not.toContain(supplierId);
    });
  });

  it('a API não escreve direto nas tabelas', async () => {
    await asUser(a.admin.id, async (client) => {
      await client.query('SAVEPOINT s');
      await expect(client.query(`INSERT INTO supplier (economic_group_id, cnpj, legal_name) VALUES ($1, $2, 'X')`, [a.group.id, cnpj()]))
        .rejects.toMatchObject({ code: '42501' });
      await client.query('ROLLBACK TO s');
      await expect(client.query('UPDATE product_supplier SET fraction_quantity = 2')).rejects.toMatchObject({ code: '42501' });
    });
  });
});

describe('códigos do fornecedor nos produtos', () => {
  it('um código aponta um só produto, mas o produto pode ter vários códigos e fornecedores', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await createSupplier(client);
      const second = await createSupplier(client);
      const productId = await createProduct(client);
      const other = await createProduct(client);
      await link(client, productId, first, { supplierCode: '123' });
      await link(client, productId, first, { supplierCode: '123-CX' });
      await link(client, productId, second, { supplierCode: '123' });
      await expectCode(client, () => link(client, other, first, { supplierCode: '123' }), 'FA925');
      const { rows } = await client.query('SELECT supplier_code FROM v_product_supplier WHERE product_id = $1 ORDER BY supplier_code', [productId]);
      expect(rows.map((r) => r.supplier_code)).toEqual(['123', '123', '123-CX']);
    });
  });

  it('tira os espaços das pontas e recusa código vazio, longo ou fracionamento zero', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client);
      const id = await link(client, productId, supplierId, { supplierCode: '  ABC 1 ' });
      expect((await client.query('SELECT supplier_code FROM v_product_supplier WHERE id = $1', [id])).rows[0].supplier_code).toBe('ABC 1');
      await expectCode(client, () => link(client, productId, supplierId, { supplierCode: ' ' }), 'FA926');
      await expectCode(client, () => link(client, productId, supplierId, { supplierCode: 'x'.repeat(61) }), 'FA926');
      await expectCode(client, () => link(client, productId, supplierId, { fractionQuantity: 0 }), 'FA926');
    });
  });

  it('produto e fornecedor precisam estar ativos e no grupo', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client);
      await setUser(client, b.admin.id);
      const otherSupplier = await createSupplier(client);
      const otherProduct = await createProduct(client);
      await setUser(client, a.admin.id);
      await expectCode(client, () => link(client, otherProduct, supplierId), 'FA004');
      await expectCode(client, () => link(client, productId, otherSupplier), 'FA004');
      const ended = await createSupplier(client);
      await client.query('SELECT app.delete_supplier($1)', [ended]);
      await expectCode(client, () => link(client, productId, ended), 'FA004');
    });
  });

  it('encerrar o fornecedor encerra os códigos, e o código volta a ficar livre', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client);
      await link(client, productId, supplierId, { supplierCode: 'X1' });
      await link(client, productId, supplierId, { supplierCode: 'X2' });
      await client.query('SELECT app.delete_supplier($1)', [supplierId]);
      expect((await client.query('SELECT 1 FROM v_product_supplier WHERE supplier_id = $1', [supplierId])).rows).toEqual([]);
      const { rows } = await client.query('SELECT count(*)::int AS n FROM product_supplier WHERE supplier_id = $1 AND deleted_at IS NOT NULL', [supplierId]);
      expect(rows[0].n).toBe(2);
    });
  });

  it('remover libera o código para outro produto, e o código não muda direto na tabela', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const first = await createProduct(client);
      const second = await createProduct(client);
      const id = await link(client, first, supplierId, { supplierCode: 'MOVE' });
      await client.query('SELECT app.remove_product_supplier($1)', [id]);
      await expect(link(client, second, supplierId, { supplierCode: 'MOVE' })).resolves.toBeTruthy();
      await expectCode(client, () => client.query('SELECT app.remove_product_supplier($1)', [id]), 'FA006');
    });
    // Gravado de verdade: a trava roda no UPDATE do dono da tabela.
    const { productId, relation, otherProduct } = await committedAsAdmin(async (client) => {
      const supplierId = await createSupplier(client);
      const created = await createProduct(client);
      return { productId: created, otherProduct: await createProduct(client), relation: await link(client, created, supplierId, { supplierCode: 'A' }) };
    });
    for (const change of ["supplier_code = 'B'", `product_id = '${otherProduct}'::uuid`]) {
      await expect(ownerPool.query(`UPDATE product_supplier SET ${change} WHERE id = $1`, [relation]), change).rejects.toSatisfy(hasCode('FA104'));
    }
    await expect(ownerPool.query('DELETE FROM product_supplier WHERE id = $1', [relation])).rejects.toSatisfy(hasCode('FA103'));
    expect(productId).toBeTruthy();
  });

  it('sem purchases.manage não liga, não ajusta e não remove código', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client);
      const id = await link(client, productId, supplierId);
      await setUser(client, a.oneBranchUser.id);
      await expectCode(client, () => link(client, productId, supplierId), 'FA002');
      await expectCode(client, () => client.query('SELECT app.update_product_supplier($1, 2)', [id]), 'FA002');
      await expectCode(client, () => client.query('SELECT app.remove_product_supplier($1)', [id]), 'FA002');
      expect((await client.query('SELECT 1 FROM v_product_supplier WHERE id = $1', [id])).rows, 'sem purchases.view não enxerga o código').toEqual([]);
      await setUser(client, manager.id);
      expect((await client.query('SELECT 1 FROM v_product_supplier WHERE id = $1', [id])).rows, 'o Gerente enxerga').toHaveLength(1);
    });
  });

  it('a tabela recusa código com espaço nas pontas, venha de onde vier', async () => {
    const { productId, supplierId } = await committedAsAdmin(async (client) => ({
      supplierId: await createSupplier(client),
      productId: await createProduct(client),
    }));
    await expect(ownerPool.query(
      `INSERT INTO product_supplier (economic_group_id, product_id, supplier_id, supplier_code) VALUES ($1, $2, $3, ' X ')`,
      [a.group.id, productId, supplierId],
    )).rejects.toSatisfy(hasCode('FA926'));
  });
});

describe('fracionamento em três níveis', () => {
  it('relação com o fornecedor > código de barras > produto', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client, { fractionQuantity: 1 });
      const { rows: [barcode] } = await client.query('SELECT id FROM v_product_barcode WHERE product_id = $1', [productId]);
      const relation = await link(client, productId, supplierId);

      expect(await fraction(client, productId)).toBe(1);
      expect(await fraction(client, productId, barcode.id, relation), 'relação sem fracionamento cai no código de barras').toBe(1);
      await client.query('SELECT app.update_barcode($1, $2::jsonb)', [barcode.id, JSON.stringify({ fractionQuantity: 10, scanEnabled: true, sendsToSupplier: true, channels: [] })]);
      expect(await fraction(client, productId, barcode.id)).toBe(10);
      expect(await fraction(client, productId, barcode.id, relation)).toBe(10);

      await client.query('SELECT app.update_product_supplier($1, 30)', [relation]);
      expect(await fraction(client, productId, barcode.id, relation)).toBe(30);
      expect(await fraction(client, productId, null, relation)).toBe(30);
      expect(await fraction(client, productId, barcode.id), 'sem a relação, vale o código de barras').toBe(10);

      await client.query('SELECT app.update_product_supplier($1, NULL)', [relation]);
      expect(await fraction(client, productId, barcode.id, relation), 'vazio volta para o código de barras').toBe(10);
    });
  });

  it('relação de outro produto ou removida não vale', async () => {
    await asUser(a.admin.id, async (client) => {
      const supplierId = await createSupplier(client);
      const productId = await createProduct(client, { fractionQuantity: 2 });
      const other = await createProduct(client);
      const foreign = await link(client, other, supplierId, { fractionQuantity: 50 });
      expect(await fraction(client, productId, null, foreign)).toBe(2);
      const own = await link(client, productId, supplierId, { fractionQuantity: 12 });
      expect(await fraction(client, productId, null, own)).toBe(12);
      await client.query('SELECT app.remove_product_supplier($1)', [own]);
      expect(await fraction(client, productId, null, own)).toBe(2);
    });
  });

  it('as chamadas antigas, com um ou dois argumentos, continuam iguais', async () => {
    await asUser(a.admin.id, async (client) => {
      const productId = await createProduct(client, { fractionQuantity: 4 });
      const one = await client.query('SELECT app.effective_fraction($1) AS f', [productId]);
      const two = await client.query('SELECT app.effective_fraction($1, NULL) AS f', [productId]);
      expect([Number(one.rows[0].f), Number(two.rows[0].f)]).toEqual([4, 4]);
    });
  });
});

describe('busca', () => {
  it('acha pelo nome sem acento, pelo começo do CNPJ e conta os códigos ativos', async () => {
    await asUser(a.admin.id, async (client) => {
      const tag = randomBytes(3).toString('hex');
      const raw = cnpj();
      const id = await createSupplier(client, { cnpj: raw, legalName: `Comércio Água ${tag}` });
      const productId = await createProduct(client);
      await link(client, productId, id);
      const removed = await link(client, productId, id);
      await client.query('SELECT app.remove_product_supplier($1)', [removed]);
      const search = (q) => client.query('SELECT * FROM app.search_suppliers($1)', [q]).then((r) => r.rows);
      const [byName] = await search(`comercio agua ${tag}`);
      expect(byName).toMatchObject({ id, product_count: '1' });
      expect((await search(raw.slice(0, 8))).map((r) => r.id)).toContain(id);
      expect((await search(`${raw.slice(0, 2)}.${raw.slice(2, 5)}.${raw.slice(5, 8)}`)).map((r) => r.id)).toContain(id);
      expect((await search(raw.slice(0, 5))).map((r) => r.id), 'menos de 8 dígitos não busca por CNPJ').not.toContain(id);
    });
  });
});

describe('perfil padrão', () => {
  it('grupo novo dá ao Gerente ver e cadastrar fornecedores', async () => {
    const { rows } = await ownerPool.query(
      `SELECT p.code FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
        WHERE rp.role_id = $1 AND rp.deleted_at IS NULL AND p.code LIKE 'purchases.%' ORDER BY p.code`,
      [a.managerRole.id],
    );
    expect(rows.map((r) => r.code)).toEqual(['purchases.manage', 'purchases.view']);
  });

  it('sem usuário, a API não lê fornecedor nenhum', async () => {
    const client = await appPool.connect();
    try {
      expect((await client.query('SELECT 1 FROM v_supplier')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_product_supplier')).rows).toEqual([]);
    } finally {
      client.release();
    }
  });
});
