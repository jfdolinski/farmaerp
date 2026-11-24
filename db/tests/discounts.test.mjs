import { readFileSync } from 'node:fs';
import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;
let operator;
let manager;
const tag = () => randomBytes(4).toString('hex');
let clockMs = Date.now();
function uuidV7() {
  clockMs += 1;
  const bytes = randomBytes(16);
  bytes.writeUIntBE(clockMs, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();

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
const readAs = async (user, sql, params = []) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    return (await client.query(sql, params)).rows;
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
const asTerminal = async (sql, params = [], terminal = a.terminal1) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    return (await client.query(sql, params)).rows[0];
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
};
let sequence = 0;
async function push(entries, terminal = a.terminal1) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, terminal.id);
    const { rows } = await client.query('SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify(entries.map(([kind, payload]) => {
      sequence += 1;
      return { id: uuidV7(), sequence, kind, payload };
    }))]);
    await client.query('COMMIT');
    return rows[0].r.results;
  } finally {
    client.release();
  }
}
const codes = (results) => results.map((r) => [r.status, r.code]);
const person = async (roleName, groupFixture = a) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [groupFixture.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, groupFixture.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [groupFixture.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, groupFixture.branch1.id]);
  return user;
};

const cases = JSON.parse(readFileSync(new URL('../../packages/discount-cases/cases.json', import.meta.url), 'utf8'));

function cpf() {
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits) => {
    const total = digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0);
    const rest = (total * 10) % 11;
    return rest === 10 ? 0 : rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}
const product = async () => {
  const sourceKey = `dev-${tag()}`;
  const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey, name: `Produto ${sourceKey}`,
  })])).rows[0].id;
  return committed(a.admin, async (client) => {
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${sourceKey}`, barcode: gtin(), catalogProductId: catalogId,
    })]);
    await client.query('SELECT app.set_product_price($1, NULL, 10, NULL)', [rows[0].id]);
    return { id: rows[0].id, code: (await client.query('SELECT code FROM product WHERE id = $1', [rows[0].id])).rows[0].code };
  });
};
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const rule = (actor, data) => committed(actor, (client) => client.query('SELECT app.create_discount_rule($1::jsonb) AS id', [JSON.stringify({
  name: 'Desconto de teste', kind: 'product', level: 'store_default', percent: 10, stacking: 'cumulative', ...data,
})]).then((r) => r.rows[0].id));
const saveGroup = (actor, id, name) => committed(actor, (client) => client.query('SELECT app.save_customer_group($1, $2) AS id', [id, name]).then((r) => r.rows[0].id));

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  manager = await person('Gerente');
});
afterAll(closePools);

describe('cálculo dos descontos (casos compartilhados com o PDV)', () => {
  const runs = [];
  for (const item of cases.cases) {
    const variants = item.variants ?? [{}];
    variants.forEach((variant, index) => runs.push({ name: `${item.name}${variants.length > 1 ? ` #${index + 1}` : ''}`, item, variant }));
  }
  it.each(runs)('$name', async ({ item, variant }) => {
    const rules = (variant.rules ?? item.rules).map((r) => ({ ...cases.base.rule, ...r }));
    const lines = (variant.lines ?? item.lines).map((l) => ({ ...l, product: cases.base.products[l.product] }));
    const context = { ...cases.base.context, ...(variant.context ?? {}) };
    const expected = variant.expected ?? item.expected;
    const result = (await ownerPool.query('SELECT app.discount_calculation($1::jsonb, $2::jsonb, $3::jsonb) AS r', [
      JSON.stringify(rules), JSON.stringify(lines), JSON.stringify(context),
    ])).rows[0].r;
    expect(result.map((r) => ({ line: r.line, total_cents: Number(r.total_cents), rules: r.applied.map((x) => x.rule_id) }))).toEqual(expected);
    for (const line of result) {
      expect(line.applied.reduce((sum, x) => sum + Number(x.amount_cents), 0)).toBe(Number(line.total_cents));
    }
  });
});

describe('regras de desconto', () => {
  it('cria cada tipo; campos fora do tipo, sem fim na promoção, cupom repetido ou fora do formato, faixa e nome: recusa', async () => {
    const group = await saveGroup(a.admin, null, `Idosos ${tag()}`);
    const kinds = [
      { kind: 'product', percent: 5 },
      { kind: 'promotion', percent: 15, validTo: '2099-01-01T00:00:00Z' },
      { kind: 'buy_x_pay_y', percent: null, buyQuantity: 3, payQuantity: 2 },
      { kind: 'quantity', percent: 50, minQuantity: 2 },
      { kind: 'payment_method', percent: 5, paymentMethod: 'pix' },
      { kind: 'customer_group', percent: 10, customerGroupId: group },
      { kind: 'birthday', percent: 15, stacking: 'exclusive' },
      { kind: 'cart_total', percent: 5, minTotal: 100 },
      { kind: 'coupon', percent: 10, coupon: ` cupom${tag().slice(0, 4)} ` },
    ];
    for (const data of kinds) {
      const id = await rule(a.admin, data);
      expect((await ownerPool.query('SELECT kind FROM discount_rule WHERE id = $1', [id])).rows[0].kind).toBe(data.kind);
    }
    const coupon = (await ownerPool.query("SELECT coupon FROM discount_rule WHERE kind = 'coupon' ORDER BY created_at DESC LIMIT 1")).rows[0].coupon;
    expect(coupon).toMatch(/^CUPOM[0-9A-F]{4}$/);
    await expect(rule(a.admin, { kind: 'coupon', coupon })).rejects.toSatisfy(hasCode('FA828'));
    await expect(rule(a.admin, { kind: 'coupon', coupon: 'com espaço' })).rejects.toSatisfy(hasCode('FA829'));
    await expect(rule(a.admin, { kind: 'product', percent: 5, minQuantity: 2 })).rejects.toSatisfy(hasCode('FA826'));
    await expect(rule(a.admin, { kind: 'buy_x_pay_y', buyQuantity: 3, payQuantity: 2 })).rejects.toSatisfy(hasCode('FA826'));
    await expect(rule(a.admin, { kind: 'customer_group', percent: 5 })).rejects.toSatisfy(hasCode('FA826'));
    await expect(rule(a.admin, { kind: 'promotion', percent: 5 })).rejects.toSatisfy(hasCode('FA827'));
    for (const bad of [{ percent: 0 }, { percent: 101 }, { kind: 'buy_x_pay_y', percent: null, buyQuantity: 2, payQuantity: 2 }, { kind: 'quantity', minQuantity: 1 }, { kind: 'cart_total', minTotal: 0 }]) {
      await expect(rule(a.admin, bad)).rejects.toSatisfy(hasCode('FA830'));
    }
    await expect(rule(a.admin, { name: ' ' })).rejects.toSatisfy(hasCode('FA831'));
    await expect(rule(a.admin, { kind: 'mágica' })).rejects.toSatisfy(hasCode('FA704'));
    await expect(rule(a.admin, { validFrom: '2026-01-02T00:00:00Z', validTo: '2026-01-01T00:00:00Z' })).rejects.toSatisfy(hasCode('FA703'));
    await expect(rule(a.admin, { level: 'manufacturer' })).rejects.toSatisfy(hasCode('FA702'));
    // Grupo de clientes, convênio e filial de outro grupo econômico.
    const outsiderGroup = await saveGroup(b.admin, null, `Fora ${tag()}`);
    await expect(rule(a.admin, { kind: 'customer_group', customerGroupId: outsiderGroup })).rejects.toSatisfy(hasCode('FA004'));
    await expect(rule(a.admin, { branchId: b.branch1.id })).rejects.toSatisfy(hasCode('FA002'));
    // Sem "Criar, editar e encerrar regras", não cria.
    await expect(rule(manager, {})).rejects.toSatisfy(hasCode('FA002'));
  });

  it('lista com a situação, encerra e não altera; quem não vê regras não vê', async () => {
    const active = await rule(a.admin, { name: `Ativa ${tag()}` });
    const scheduled = await rule(a.admin, { name: `Futura ${tag()}`, validFrom: '2099-01-01T00:00:00Z' });
    const ended = await rule(a.admin, { name: `Encerrada ${tag()}` });
    await committed(a.admin, (client) => client.query('SELECT app.end_discount_rule($1)', [ended]));
    await expect(committed(a.admin, (client) => client.query('SELECT app.end_discount_rule($1)', [ended]))).rejects.toSatisfy(hasCode('FA006'));
    await expect(committed(manager, (client) => client.query('SELECT app.end_discount_rule($1)', [active]))).rejects.toSatisfy(hasCode('FA002'));
    const current = await readAs(a.admin, 'SELECT * FROM app.list_discount_rules()');
    expect(current.find((r) => r.id === active)).toMatchObject({ status: 'active', target_name: null, stacking: 'cumulative' });
    expect(current.find((r) => r.id === scheduled)).toMatchObject({ status: 'scheduled' });
    expect(current.some((r) => r.id === ended)).toBe(false);
    const all = await readAs(a.admin, 'SELECT * FROM app.list_discount_rules(NULL, true)');
    expect(all.find((r) => r.id === ended)).toMatchObject({ status: 'ended' });
    expect(await readAs(operator, 'SELECT * FROM app.list_discount_rules()')).toEqual([]);
    expect(await readAs(b.admin, 'SELECT * FROM app.list_discount_rules(NULL, true)')).toEqual([]);
    await expect(ownerPool.query('UPDATE discount_rule SET percent = 50 WHERE id = $1', [active])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query("UPDATE discount_rule SET valid_to = now() + interval '1 day' WHERE id = $1", [active])).rejects.toSatisfy(hasCode('FA104'));
  });
});

describe('grupos de clientes', () => {
  it('cria, renomeia, põe o cliente no grupo e não tira grupo em uso', async () => {
    const name = `Clínicas ${tag()}`;
    const group = await saveGroup(a.admin, null, name);
    await expect(saveGroup(a.admin, null, ` ${name.toLowerCase()} `)).rejects.toSatisfy(hasCode('FA215'));
    await expect(saveGroup(a.admin, null, '  ')).rejects.toSatisfy(hasCode('FA216'));
    await expect(saveGroup(operator, null, `Sem permissão ${tag()}`)).rejects.toSatisfy(hasCode('FA002'));
    await saveGroup(a.admin, group, `${name} renomeado`);
    await expect(saveGroup(b.admin, group, 'x')).rejects.toSatisfy(hasCode('FA006'));
    const customer = await committed(a.admin, (client) => client.query('SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
      personType: 'individual', document: cpf(), name: 'Cliente Grupo',
    })]).then((r) => r.rows[0].id));
    await committed(a.admin, (client) => client.query('SELECT app.set_customer_group($1, $2)', [customer, group]));
    expect((await ownerPool.query('SELECT customer_group_id FROM customer WHERE id = $1', [customer])).rows[0].customer_group_id).toBe(group);
    await expect(committed(a.admin, (client) => client.query('SELECT app.remove_customer_group($1)', [group]))).rejects.toSatisfy(hasCode('FA105'));
    const other = await saveGroup(b.admin, null, `Outro ${tag()}`);
    await expect(committed(a.admin, (client) => client.query('SELECT app.set_customer_group($1, $2)', [customer, other]))).rejects.toSatisfy(hasCode('FA004'));
    await expect(committed(operator, (client) => client.query('SELECT app.set_customer_group($1, NULL)', [customer]))).rejects.toSatisfy(hasCode('FA002'));
    await committed(a.admin, (client) => client.query('SELECT app.set_customer_group($1, NULL)', [customer]));
    const inRule = await saveGroup(a.admin, null, `Com desconto ${tag()}`);
    await rule(a.admin, { kind: 'customer_group', customerGroupId: inRule });
    await expect(committed(a.admin, (client) => client.query('SELECT app.remove_customer_group($1)', [inRule]))).rejects.toSatisfy(hasCode('FA105'));
    await committed(a.admin, (client) => client.query('SELECT app.remove_customer_group($1)', [group]));
    expect((await readAs(a.admin, 'SELECT id FROM v_customer_group')).some((g) => g.id === group)).toBe(false);
  });
});

describe('desconto na venda com os cadastros da central', () => {
  it('produto, grupo do cliente, aniversariante e cupom pelo banco; simulador com permissão', async () => {
    // Só as regras deste caso: as dos outros testes saem.
    await ownerPool.query('UPDATE discount_rule SET deleted_at = now() WHERE economic_group_id = $1 AND deleted_at IS NULL', [a.group.id]);
    const item = await product();
    const group = await saveGroup(a.admin, null, `Funcionários ${tag()}`);
    const month = new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' }).slice(5, 7);
    const customer = await committed(a.admin, (client) => client.query('SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify({
      personType: 'individual', document: cpf(), name: 'Cliente Desconto', birthDate: `1985-${month}-10`,
    })]).then((r) => r.rows[0].id));
    await committed(a.admin, (client) => client.query('SELECT app.set_customer_group($1, $2)', [customer, group]));
    const onProduct = await rule(a.admin, { level: 'product', productLookup: String(item.code), percent: 10, branchId: a.branch1.id });
    const onGroup = await rule(a.admin, { kind: 'customer_group', customerGroupId: group, percent: 5 });
    const birthday = await rule(a.admin, { kind: 'birthday', percent: 30, stacking: 'exclusive' });
    const code = `C${tag().toUpperCase()}`;
    const coupon = await rule(a.admin, { kind: 'coupon', coupon: code, percent: 2 });
    await rule(a.admin, { branchId: a.branch2.id, percent: 50 });
    const run = (context) => readAs(a.admin, 'SELECT app.simulate_discounts($1, $2::jsonb, $3::jsonb) AS r', [
      a.branch1.id, JSON.stringify([{ line: 1, product_id: item.id, quantity: 2, unit_price: 10 }]), JSON.stringify(context),
    ]).then((rows) => rows[0].r[0]);
    const plain = await run({});
    const ids = (r) => r.applied.map((x) => x.rule_id);
    expect(ids(plain)).toEqual([onProduct]);
    expect(Number(plain.total_cents)).toBe(200);
    // Aniversariante (exclusiva, 30%) passa da soma das acumuláveis (10 + 5 + 2).
    const party = await run({ customer_id: customer, coupon: code.toLowerCase() });
    expect([ids(party), Number(party.total_cents)]).toEqual([[birthday], 600]);
    const withoutBirthday = await ownerPool.query('UPDATE customer SET birth_date = NULL WHERE id = $1', [customer]);
    expect(withoutBirthday.rowCount).toBe(1);
    const grouped = await run({ customer_id: customer, coupon: code });
    expect(ids(grouped).sort()).toEqual([onProduct, onGroup, coupon].sort());
    expect(Number(grouped.total_cents)).toBe(340);
    await expect(readAs(operator, 'SELECT app.simulate_discounts($1, $2::jsonb, $3::jsonb)', [a.branch1.id, '[]', '{}'])).rejects.toSatisfy(hasCode('FA002'));
    await expect(readAs(b.admin, 'SELECT app.simulate_discounts($1, $2::jsonb, $3::jsonb)', [a.branch1.id, '[]', '{}'])).rejects.toSatisfy(hasCode('FA002'));
  });
});

describe('descida para o PDV', () => {
  it('regras da filial e da rede descem; encerrada desce vazia; produto com a hierarquia e cliente com o grupo', async () => {
    const network = await rule(a.admin, { name: `Rede ${tag()}` });
    const here = await rule(a.admin, { name: `Filial ${tag()}`, branchId: a.branch1.id });
    const there = await rule(a.admin, { name: `Outra ${tag()}`, branchId: a.branch2.id });
    const initial = await ownerPool.query('SELECT id FROM app.pdv_targets($1, $2, $3, NULL, NULL) WHERE rank = 6', [a.branch1.id, a.group.id, a.terminal1.id]);
    const sent = initial.rows.map((r) => r.id);
    expect(sent).toEqual(expect.arrayContaining([network, here]));
    expect(sent).not.toContain(there);
    const data = (await ownerPool.query('SELECT * FROM app.pdv_discount_rule_data($1, $2::uuid[])', [a.branch1.id, [network, there]])).rows;
    expect(data.find((r) => r.id === network).data).toMatchObject({ id: network, kind: 'product', level: 'store_default', percent: 10, stacking: 'cumulative' });
    expect(data.find((r) => r.id === there).data).toBeNull();
    const mark = (await ownerPool.query('SELECT pg_current_xact_id()::text AS x')).rows[0].x;
    await committed(a.admin, (client) => client.query('SELECT app.end_discount_rule($1)', [network]));
    const changed = await ownerPool.query('SELECT id FROM app.pdv_targets($1, $2, $3, $4::xid8, pg_snapshot_xmin(pg_current_snapshot())) WHERE rank = 6', [
      a.branch1.id, a.group.id, a.terminal1.id, mark,
    ]);
    expect(changed.rows.map((r) => r.id)).toContain(network);
    expect((await ownerPool.query('SELECT data FROM app.pdv_discount_rule_data($1, ARRAY[$2]::uuid[])', [a.branch1.id, network])).rows[0].data).toBeNull();
    const item = await product();
    const productData = (await ownerPool.query('SELECT data FROM app.pdv_product_data($1, ARRAY[$2]::uuid[])', [a.branch1.id, item.id])).rows[0].data;
    expect(productData.discount_subject).toMatchObject({ id: item.id });
    expect(Object.keys(productData.discount_subject).sort()).toEqual([
      'category_id', 'commission_group_id', 'department_id', 'id', 'manufacturer_id', 'price_family_id', 'pricing_group_id', 'subcategory_id',
    ]);
  });
});
