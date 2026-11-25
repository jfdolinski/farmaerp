import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const tag = () => randomBytes(4).toString('hex');
const isoDate = async (days) => (await ownerPool.query(
  `SELECT to_char(app.local_today() + $1::int, 'YYYY-MM-DD') AS d`, [days],
)).rows[0].d;

// A descida só enxerga transações terminadas: tudo aqui é confirmado, como na vida real.
async function committed(user, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
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

/** Uma chamada da descida, como a API faz: terminal na transação e nada gravado. */
async function pullPage(terminal, { cursor = null, until = null, after = null, limit = 1000 } = {}) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal?.id ?? '');
    const { rows } = await client.query('SELECT app.pdv_pull($1, $2, $3, $4) AS r', [cursor, until, after, limit]);
    return rows[0].r;
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}

/** Busca a janela inteira, pacote por pacote, como o PDV. */
async function pullAll(terminal, cursor = null, limit = 1000) {
  const items = [];
  let page = await pullPage(terminal, { cursor, limit });
  items.push(...page.items);
  const until = page.until;
  while (page.next) {
    page = await pullPage(terminal, { cursor, until, after: page.next, limit });
    expect(page.until).toBe(until);
    items.push(...page.items);
  }
  const byKey = new Map(items.map((item) => [`${item.type}:${item.id}`, item.data]));
  return { until, items, byKey, has: (type, id) => byKey.has(`${type}:${id}`), get: (type, id) => byKey.get(`${type}:${id}`) };
}

const newProduct = (fixture, overrides = {}) => committed(fixture.admin, async (client) => {
  const barcode = overrides.barcode ?? gtin();
  const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [
    JSON.stringify({ displayName: `Produto sync ${tag()}`, barcode, ...overrides }),
  ]);
  await client.query('SELECT app.set_product_price($1, NULL, 10, NULL)', [rows[0].id]);
  return { id: rows[0].id, barcode };
});
const setPrice = (fixture, product, branch, price) => committed(fixture.admin, (client) =>
  client.query('SELECT app.set_product_price($1, $2, $3, $4)', [product.id, branch?.id ?? null, price, branch ? 'Preço da loja' : null]));
const setStatus = (fixture, product, branch, status) => committed(fixture.admin, (client) =>
  client.query('SELECT app.set_product_status($1, $2, $3, $4)', [product.id, [branch.id], status, 'Teste da descida']));
const adjust = (fixture, product, branch, quantity) => committed(fixture.admin, (client) =>
  client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: product.barcode, branchId: branch.id, direction: quantity > 0 ? 'in' : 'out',
    quantity: Math.abs(quantity), reason: 'Teste da descida',
  })]));

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('carga inicial', () => {
  it('traz a filial do terminal, com usuários, produtos e estoque, e nada de outro grupo', async () => {
    const active = await newProduct(a);
    const onOrder = await newProduct(a);
    const inactive = await newProduct(a);
    const blockedEmpty = await newProduct(a);
    const blockedWithStock = await newProduct(a);
    const otherGroup = await newProduct(b);
    await setStatus(a, onOrder, a.branch1, 'on_order');
    await setStatus(a, inactive, a.branch1, 'inactive');
    await adjust(a, blockedWithStock, a.branch1, 3);
    await setStatus(a, blockedEmpty, a.branch1, 'blocked');
    await setStatus(a, blockedWithStock, a.branch1, 'blocked');
    await adjust(a, active, a.branch1, 5);
    await setPrice(a, active, a.branch1, 7.5);

    const load = await pullAll(a.terminal1);
    expect(load.items[0]).toMatchObject({ type: 'fiscal', id: a.branch1.id });
    expect(load.items.filter((item) => item.type === 'fiscal')).toHaveLength(1);
    // Ordem de entrega: fiscal, usuários, produtos, estoque.
    const ranks = { fiscal: 1, user: 2, product: 3, stock: 4 };
    const order = load.items.map((item) => ranks[item.type]);
    expect(order).toEqual([...order].sort((x, y) => x - y));

    expect(load.get('product', active.id)).toMatchObject({ status: 'active', price: 7.5, batch_required: false });
    expect(load.get('product', active.id).barcodes).toEqual([
      { id: expect.any(String), code: active.barcode, is_primary: true, fraction_quantity: null },
    ]);
    expect(load.get('stock', active.id)).toEqual({ quantity: 5, batches: [] });
    expect(load.get('product', onOrder.id)).toMatchObject({ status: 'on_order', price: 10 });
    expect(load.get('product', blockedWithStock.id)).toMatchObject({ status: 'blocked' });
    for (const product of [inactive, blockedEmpty, otherGroup]) {
      expect(load.has('product', product.id)).toBe(false);
      expect(load.has('stock', product.id)).toBe(false);
    }
    // O preço da loja 1 não vale na loja 2.
    expect((await pullAll(a.terminal2)).get('product', active.id)).toMatchObject({ price: 10 });

    // Usuários: administradores e quem tem perfil na filial. Sem senha, e-mail ou outro grupo.
    expect(load.get('user', a.admin.id)).toMatchObject({ is_admin: true, limits: { sale_discount: null } });
    expect(load.has('user', a.noBranchUser.id)).toBe(false);
    expect(load.has('user', b.admin.id)).toBe(false);
    for (const item of load.items.filter((entry) => entry.type === 'user')) {
      expect(Object.keys(item.data).sort()).toEqual(['auth_mode', 'code', 'face', 'is_admin', 'limits', 'name', 'permissions', 'pin_hash', 'roles']);
    }
    // Nenhum segredo desce: só a lista de permissões cita "certificate", como nome de permissão.
    const withoutPermissions = load.items.map((item) => (item.type === 'user' ? { ...item.data, permissions: [] } : item));
    expect(JSON.stringify(withoutPermissions)).not.toMatch(/password|email|encrypted|certificate|csc|token/i);
  });

  it('pacotes pequenos entregam o mesmo que um pacote só', async () => {
    await newProduct(a);
    const single = await pullAll(a.terminal1);
    const paged = await pullAll(a.terminal1, null, 2);
    expect(paged.items.map((item) => `${item.type}:${item.id}`)).toEqual(single.items.map((item) => `${item.type}:${item.id}`));
    const page = await pullPage(a.terminal1, { limit: 2 });
    expect(page.items).toHaveLength(2);
    expect(page.next).toMatch(/^[1-4]:/);
    expect(page.format).toBe(7);
    // O total vem só no primeiro pacote, para o progresso da carga.
    expect(page.total).toBe(single.items.length);
    expect((await pullPage(a.terminal1, { until: page.until, after: page.next, limit: 2 })).total).toBeNull();
  });

  it('dados fiscais trazem a empresa, a filial e só as séries deste terminal', async () => {
    const fiscal = (await pullAll(a.terminal1)).get('fiscal', a.branch1.id);
    expect(fiscal.branch).toMatchObject({ id: a.branch1.id, cnpj: a.branch1.cnpj, name: a.branch1.name });
    expect(fiscal.company).toMatchObject({ id: a.company.id, legal_name: a.company.legal_name });
    const own = (await ownerPool.query(
      'SELECT id FROM terminal_fiscal_series WHERE terminal_id = $1 AND deleted_at IS NULL ORDER BY model', [a.terminal1.id],
    )).rows.map((row) => row.id);
    const branchWide = (await ownerPool.query(
      'SELECT count(*)::int AS n FROM terminal_fiscal_series WHERE branch_id = $1 AND deleted_at IS NULL', [a.branch1.id],
    )).rows[0].n;
    expect(fiscal.series.map((row) => row.id)).toEqual(own);
    expect(branchWide).toBeGreaterThanOrEqual(own.length);

    // Outro caixa da mesma filial tem a série dele; ela não desce para este terminal.
    const other = (await ownerPool.query(
      `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', 'active', $3) RETURNING *`,
      [a.branch1.id, `Caixa série ${tag()}`, `chave-${randomUUID()}`],
    )).rows[0];
    // O terminal novo já nasce com as séries dele.
    const otherSeries = (await pullAll(other)).get('fiscal', a.branch1.id).series.map((row) => row.id);
    expect(otherSeries.length).toBeGreaterThan(0);
    expect(otherSeries.some((id) => own.includes(id))).toBe(false);
    expect((await pullAll(a.terminal1)).get('fiscal', a.branch1.id).series.map((row) => row.id)).toEqual(own);
  });
});

describe('descida incremental', () => {
  it('sem mudança, nada desce; o cursor nunca volta', async () => {
    const { until } = await pullAll(a.terminal1);
    const again = await pullAll(a.terminal1, until);
    expect(again.items).toEqual([]);
    expect(BigInt(again.until)).toBeGreaterThanOrEqual(BigInt(until));
    const ahead = (BigInt(until) + 1000n).toString();
    expect(await pullPage(a.terminal1, { cursor: ahead })).toMatchObject({ until: ahead, items: [], next: null });
  });

  it('preço da loja desce só para ela; preço da rede desce para todas', async () => {
    const product = await newProduct(a);
    const start1 = (await pullAll(a.terminal1)).until;
    const start2 = (await pullAll(a.terminal2)).until;
    await setPrice(a, product, a.branch1, 8.25);
    const one = await pullAll(a.terminal1, start1);
    expect(one.get('product', product.id)).toMatchObject({ price: 8.25 });
    expect((await pullAll(a.terminal2, start2)).has('product', product.id)).toBe(false);

    await setPrice(a, product, null, 11);
    const network = await pullAll(a.terminal2, start2);
    expect(network.get('product', product.id)).toMatchObject({ price: 11 });
    // A outra loja também recebe, com o preço próprio mantido.
    expect((await pullAll(a.terminal1, one.until)).get('product', product.id)).toMatchObject({ price: 8.25 });
    // Outro grupo não vê nada disso.
    const otherStart = (await pullAll(b.terminal1)).until;
    await setPrice(a, product, null, 12);
    expect((await pullAll(b.terminal1, otherStart)).items).toEqual([]);
  });

  it('inativar retira o produto e o estoque; bloqueado sai quando zera o saldo', async () => {
    const product = await newProduct(a);
    await adjust(a, product, a.branch1, 2);
    let cursor = (await pullAll(a.terminal1)).until;
    await setStatus(a, product, a.branch1, 'blocked');
    let step = await pullAll(a.terminal1, cursor);
    expect(step.get('product', product.id)).toMatchObject({ status: 'blocked' });
    cursor = step.until;

    await adjust(a, product, a.branch1, -2);
    step = await pullAll(a.terminal1, cursor);
    expect(step.byKey.get(`product:${product.id}`)).toBeNull();
    expect(step.byKey.get(`stock:${product.id}`)).toBeNull();
    cursor = step.until;

    await adjust(a, product, a.branch1, 1);
    step = await pullAll(a.terminal1, cursor);
    expect(step.get('product', product.id)).toMatchObject({ status: 'blocked' });
    expect(step.get('stock', product.id)).toEqual({ quantity: 1, batches: [] });
    cursor = step.until;

    await setStatus(a, product, a.branch1, 'inactive');
    step = await pullAll(a.terminal1, cursor);
    expect(step.byKey.get(`product:${product.id}`)).toBeNull();
    expect(step.byKey.get(`stock:${product.id}`)).toBeNull();
  });

  it('edição do cadastro desce o produto com o nome novo', async () => {
    const product = await newProduct(a);
    const cursor = (await pullAll(a.terminal1)).until;
    await committed(a.admin, (client) => client.query('SELECT app.update_product($1, $2::jsonb)', [
      product.id, JSON.stringify({ displayName: 'Nome novo da descida' }),
    ]));
    expect((await pullAll(a.terminal1, cursor)).get('product', product.id)).toMatchObject({ name: 'Nome novo da descida' });
  });

  it('a janela não leva mudança feita depois do fim dela', async () => {
    const product = await newProduct(a);
    const first = await pullAll(a.terminal1);
    const window = await pullPage(a.terminal1, { cursor: first.until });
    await setPrice(a, product, null, 31);
    // Mesma janela (mesmo until): a mudança nova fica para a próxima.
    expect((await pullPage(a.terminal1, { cursor: first.until, until: window.until })).items).toEqual([]);
    expect((await pullAll(a.terminal1, window.until)).get('product', product.id)).toMatchObject({ price: 31 });
  });

  it('código de barras novo ou desligado para leitura muda o produto', async () => {
    const product = await newProduct(a);
    const cursor = (await pullAll(a.terminal1)).until;
    const extra = gtin();
    await committed(a.admin, (client) => client.query('SELECT app.add_barcode($1, $2::jsonb)', [
      product.id, JSON.stringify({ code: extra, scanEnabled: false }),
    ]));
    const step = await pullAll(a.terminal1, cursor);
    expect(step.get('product', product.id).barcodes.map((code) => code.code)).toEqual([product.barcode]);
  });

  it('estoque por lote, com validade, desce com o produto', async () => {
    const product = await newProduct(a);
    const cursor = (await pullAll(a.terminal1)).until;
    await committed(a.admin, (client) => client.query('SELECT app.set_batch_tracking($1, $2, true)', [product.id, a.branch1.id]));
    await committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
      productLookup: product.barcode, branchId: a.branch1.id, direction: 'in', quantity: 4, reason: 'Lote',
      batchNumber: 'L-SYNC', expiresOn: '2090-01-31',
    })]));
    const step = await pullAll(a.terminal1, cursor);
    expect(step.get('product', product.id)).toMatchObject({ batch_required: true });
    expect(step.get('stock', product.id)).toEqual({
      quantity: 4, batches: [{ id: expect.any(String), number: 'L-SYNC', expires_on: '2090-01-31', quantity: 4 }],
    });
    // Lote esgotado sai da lista.
    await committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
      productLookup: product.barcode, branchId: a.branch1.id, direction: 'out', quantity: 4, reason: 'Lote',
      batchNumber: 'L-SYNC',
    })]));
    expect((await pullAll(a.terminal1, step.until)).get('stock', product.id)).toEqual({ quantity: 0, batches: [] });
  });

  it('Catálogo: tributação em vigor e futura, da filial; fabricante renomeado', async () => {
    await ownerPool.query('UPDATE company SET tax_regime = 1 WHERE id = $1', [a.company.id]);
    await ownerPool.query(`UPDATE branch SET state = 'SP' WHERE id = $1`, [a.branch1.id]);
    const sourceKey = `sync-${tag()}`;
    const manufacturer = `Fabricante sync ${tag()}`;
    const rule = (validFrom, overrides = {}) => ({
      regimes: [1], states: ['SP'], validFrom, cfop: '5405', origin: 0, icmsCsosn: '500', pisCst: '49', cofinsCst: '49', ...overrides,
    });
    const upsert = (taxes, extra = {}) => ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [
      JSON.stringify({ sourceKey, name: `Item ${sourceKey}`, manufacturer, taxes, ...extra }),
    ]).then((r) => r.rows[0].id);
    const catalogId = await upsert([rule('2020-01-01', { cfop: '5102' }), rule('2024-01-01')]);
    const product = await newProduct(a, { catalogProductId: catalogId });
    let cursor = (await pullAll(a.terminal1)).until;

    const future = await isoDate(30);
    await upsert([
      rule('2020-01-01', { cfop: '5102' }), rule('2024-01-01'), rule(future, { cfop: '5102' }),
      rule('2024-01-01', { states: ['RJ'] }), rule('2024-01-01', { regimes: [3], icmsCsosn: undefined, icmsCst: '00', icmsRate: 18 }),
    ]);
    let step = await pullAll(a.terminal1, cursor);
    const data = step.get('product', product.id);
    expect(data.taxes.map((t) => [t.valid_from, t.cfop])).toEqual([['2024-01-01', '5405'], [future, '5102']]);
    expect(data.taxes[0]).not.toHaveProperty('state');
    expect(data.taxes[0]).toHaveProperty('icms_csosn', '500');
    // A filial 2 não tem estado: sem regra.
    expect((await pullAll(a.terminal2)).get('product', product.id).taxes).toEqual([]);
    cursor = step.until;

    await ownerPool.query('UPDATE catalog_manufacturer SET name = $1 WHERE name = $2', [`${manufacturer} novo`, manufacturer]);
    step = await pullAll(a.terminal1, cursor);
    expect(step.get('product', product.id)).toMatchObject({ manufacturer: `${manufacturer} novo` });
    cursor = step.until;

    // Regime da empresa muda a tributação de todos os produtos da filial: desce tudo de novo.
    await ownerPool.query('UPDATE company SET tax_regime = 3 WHERE id = $1', [a.company.id]);
    step = await pullAll(a.terminal1, cursor);
    expect(step.get('fiscal', a.branch1.id).company.tax_regime).toBe(3);
    expect(step.get('product', product.id).taxes.map((t) => t.icms_cst)).toEqual(['00']);
    const load = await pullAll(a.terminal1);
    expect(step.items.filter((item) => item.type === 'product').length)
      .toBe(load.items.filter((item) => item.type === 'product').length);
    await ownerPool.query('UPDATE company SET tax_regime = NULL WHERE id = $1', [a.company.id]);
  });

  it('estado da filial refaz a tributação de todos os produtos', async () => {
    const product = await newProduct(a);
    const cursor = (await pullAll(a.terminal2)).until;
    await ownerPool.query(`UPDATE branch SET state = 'RJ' WHERE id = $1`, [a.branch2.id]);
    const step = await pullAll(a.terminal2, cursor);
    expect(step.get('fiscal', a.branch2.id).branch.state).toBe('RJ');
    expect(step.has('product', product.id)).toBe(true);
    await ownerPool.query('UPDATE branch SET state = NULL WHERE id = $1', [a.branch2.id]);
  });

  it('nome da filial só refaz os dados fiscais', async () => {
    const cursor = (await pullAll(a.terminal1)).until;
    await ownerPool.query('UPDATE branch SET phone = $1 WHERE id = $2', ['1133334444', a.branch1.id]);
    const step = await pullAll(a.terminal1, cursor);
    expect(step.items.map((item) => item.type)).toEqual(['fiscal']);
    expect(step.get('fiscal', a.branch1.id).branch.phone).toBe('1133334444');
  });

  it('usuários: perfil, permissão, limite e vínculo com a filial', async () => {
    const role = (await ownerPool.query(
      `INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *`, [a.group.id, `Caixa sync ${tag()}`],
    )).rows[0];
    const user = (await ownerPool.query(
      'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Pessoa sync ${tag()}`],
    )).rows[0];
    let cursor = (await pullAll(a.terminal1)).until;
    const link = (await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2) RETURNING *', [user.id, a.branch1.id])).rows[0];
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
    let step = await pullAll(a.terminal1, cursor);
    expect(step.get('user', user.id)).toMatchObject({
      name: user.name, is_admin: false, permissions: [], roles: [{ id: role.id, name: role.name }],
      limits: { sale_discount: 0, stock_loss: 0 },
    });
    // O perfil só vale na filial 1.
    expect((await pullAll(a.terminal2)).has('user', user.id)).toBe(false);
    cursor = step.until;

    await ownerPool.query(`INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'stock.view'`, [role.id]);
    step = await pullAll(a.terminal1, cursor);
    expect(step.get('user', user.id)).toMatchObject({ permissions: ['stock.view'], limits: { sale_discount: 0 } });
    cursor = step.until;
    await ownerPool.query(
      `INSERT INTO role_limit (economic_group_id, role_id, limit_type_id, value) SELECT $1, $2, id, 15 FROM limit_type WHERE code = 'sale_discount'`,
      [a.group.id, role.id],
    );
    step = await pullAll(a.terminal1, cursor);
    expect(step.get('user', user.id)).toMatchObject({ permissions: ['stock.view'], limits: { sale_discount: 15 } });
    cursor = step.until;

    await ownerPool.query('UPDATE user_branch SET deleted_at = now() WHERE id = $1', [link.id]);
    step = await pullAll(a.terminal1, cursor);
    expect(step.byKey.get(`user:${user.id}`)).toBeNull();
  });

  it('transação demorada não fica para trás do cursor', async () => {
    const slow = await newProduct(a);
    const fast = await newProduct(a);
    const cursor = (await pullAll(a.terminal1)).until;

    const open = await appPool.connect();
    try {
      await open.query('BEGIN');
      await setUser(open, a.admin.id);
      await open.query('SELECT app.set_product_price($1, NULL, 21, NULL)', [slow.id]);
      await setPrice(a, fast, null, 22);

      // Com a transação aberta, a janela para antes dela.
      const during = await pullAll(a.terminal1, cursor);
      expect(during.has('product', slow.id)).toBe(false);
      await open.query('COMMIT');

      const after = await pullAll(a.terminal1, during.until);
      expect(after.get('product', slow.id)).toMatchObject({ price: 21 });
      const delivered = during.has('product', fast.id) ? during : after;
      expect(delivered.get('product', fast.id)).toMatchObject({ price: 22 });
    } finally {
      open.release();
    }
  });

  it('várias mudanças do mesmo item numa transação gravam uma linha só', async () => {
    const product = await newProduct(a);
    await committed(a.admin, async (client) => {
      for (const price of [1, 2, 3]) await client.query('SELECT app.set_product_price($1, NULL, $2, NULL)', [product.id, price]);
    });
    const { rows } = await ownerPool.query(
      `SELECT count(*)::int AS n FROM sync_change WHERE entity = 'product' AND entity_id = $1 AND branch_id IS NULL`, [product.id],
    );
    expect(rows[0].n).toBe(1);
  });
});

describe('proteções', () => {
  it('só o terminal ativo desce, e o formato do pedido é conferido', async () => {
    const terminal = (status) => ownerPool.query(
      `INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'cashier', $3, $4) RETURNING *`,
      [a.branch1.id, `Caixa ${status} ${tag()}`, status, `chave-${randomUUID()}`],
    ).then((r) => r.rows[0]);
    await expect(pullPage(null)).rejects.toSatisfy(hasCode('FA306'));
    await expect(pullPage({ id: randomUUID() })).rejects.toSatisfy(hasCode('FA306'));
    for (const [status, code] of [['pending', 'FA307'], ['blocked', 'FA304'], ['revoked', 'FA305']]) {
      await expect(pullPage(await terminal(status))).rejects.toSatisfy(hasCode(code));
    }
    for (const args of [
      { cursor: 'abc' }, { cursor: '-1' }, { until: '1x' }, { after: `3:${randomUUID()}` },
      { until: '10', after: `7:${randomUUID()}` }, { until: '10', after: '3:nada' }, { limit: 0 }, { limit: 5001 },
    ]) {
      await expect(pullPage(a.terminal1, args)).rejects.toSatisfy(hasCode('FA956'));
    }
  });

  it('a API não lê sync_change nem as funções internas', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await setUser(client, a.admin.id);
      for (const call of [
        'SELECT * FROM sync_change',
        'SELECT * FROM v_sync_change',
        `SELECT app.mark_sync_change('product', gen_random_uuid(), NULL, NULL)`,
        `SELECT * FROM app.pdv_product_data('${a.branch1.id}', ARRAY[]::uuid[])`,
        `SELECT * FROM app.pdv_targets('${a.branch1.id}', '${a.group.id}', '${a.terminal1.id}', NULL, '1')`,
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(call)).rejects.toThrow(/permission denied/);
        await client.query('ROLLBACK TO s');
      }
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('a tabela recusa escopo incoerente', async () => {
    for (const [entity, group, branch] of [
      ['product', null, null], ['catalog_product', a.group.id, null], ['product', null, a.branch1.id], ['outra', a.group.id, null],
    ]) {
      await expect(ownerPool.query(
        'INSERT INTO sync_change (economic_group_id, branch_id, entity, entity_id) VALUES ($1, $2, $3, gen_random_uuid())',
        [group, branch, entity],
      )).rejects.toSatisfy(hasCode('FA956'));
    }
  });
});
