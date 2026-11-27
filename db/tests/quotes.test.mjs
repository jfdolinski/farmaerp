import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Orçamento vindo do PDV, plaquinha, validade por filial e vendedor na venda.
let a;
let b;
let operator;
let clerk;
let outsider;
let product;

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
function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString();
const DAY = 86400000;

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
const person = async (roleName) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  if (roleName) {
    const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName])).rows[0];
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  }
  return user;
};

let number = 0;
const quote = (overrides = {}, items = null) => {
  number += 1;
  const lines = items ?? [{ id: uuidV7(), line: 1, product_id: product.id, quantity: 2, unit_price: 10, discount: 1, total: 19 }];
  const subtotal = lines.reduce((sum, i) => sum + Math.round(i.quantity * i.unit_price * 100) / 100, 0);
  const discount = lines.reduce((sum, i) => sum + i.discount, 0);
  return {
    id: uuidV7(), number, seller_id: clerk.id, customer_id: null, card_number: null, quoted_at: iso(),
    items: lines, subtotal, discount_total: discount, total: subtotal - discount, ...overrides,
  };
};
const row = async (id) => (await ownerPool.query('SELECT * FROM quote WHERE id = $1', [id])).rows[0];
const spDate = (value) => new Date(value).toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  clerk = await person('Balconista');
  outsider = await person(null);
  const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey: `orc-${tag()}`, name: 'Produto do orçamento',
  })])).rows[0].id;
  product = await committed(a.admin, async (client) => {
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${tag()}`, barcode: gtin(), catalogProductId: catalogId,
    })]);
    await client.query('SELECT app.set_product_price($1, NULL, 10, NULL)', [rows[0].id]);
    return { id: rows[0].id };
  });
});
afterAll(closePools);

describe('orçamento vindo do PDV', () => {
  it('grava com código, vendedor, itens e validade até o fim do dia', async () => {
    const payload = quote({ card_number: 12 }, [
      { id: uuidV7(), line: 1, product_id: product.id, quantity: 2, unit_price: 10, discount: 1, total: 19, release: { supervisor_id: operator.id, reason: ' Cliente fiel ' } },
      { id: uuidV7(), line: 2, product_id: product.id, quantity: 0.5, unit_price: 10, discount: 0, total: 5 },
    ]);
    expect(codes(await push([['quote', payload]]))).toEqual([['applied', null]]);
    const saved = await row(payload.id);
    const terminalNumber = (await ownerPool.query('SELECT number FROM terminal WHERE id = $1', [a.terminal1.id])).rows[0].number;
    expect(saved).toMatchObject({
      code: `O${terminalNumber}-${String(payload.number).padStart(6, '0')}`, status: 'open', seller_id: clerk.id, card_number: 12,
      branch_id: a.branch1.id, replaced_by: null,
    });
    expect([saved.subtotal, saved.discount_total, saved.total].map(Number)).toEqual([25, 1, 24]);
    // Validade 0: vence à meia-noite do dia da loja.
    expect(spDate(saved.expires_at.getTime() - 1)).toBe(spDate(payload.quoted_at));
    expect(spDate(saved.expires_at)).not.toBe(spDate(payload.quoted_at));
    const items = (await ownerPool.query('SELECT line, quantity::float, released_by, release_reason FROM quote_item WHERE quote_id = $1 ORDER BY line', [payload.id])).rows;
    expect(items).toEqual([
      { line: 1, quantity: 2, released_by: operator.id, release_reason: 'Cliente fiel' },
      { line: 2, quantity: 0.5, released_by: null, release_reason: null },
    ]);
  });

  it('validade da filial em dias', async () => {
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_sale_settings($1, 3, true)', [a.branch1.id]));
    const payload = quote();
    await push([['quote', payload]]);
    const saved = await row(payload.id);
    const expected = new Date(`${spDate(payload.quoted_at)}T12:00:00Z`);
    expected.setUTCDate(expected.getUTCDate() + 4);
    expect(spDate(saved.expires_at)).toBe(expected.toISOString().slice(0, 10));
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_sale_settings($1, 0, false)', [a.branch1.id]));
  });

  it('a plaquinha passa para o orçamento mais novo; o que chega atrasado já chega substituído', async () => {
    const first = quote({ card_number: 40, quoted_at: iso(-60000) });
    const second = quote({ card_number: 40 });
    const late = quote({ card_number: 40, quoted_at: iso(-30000) });
    expect(codes(await push([['quote', first], ['quote', second], ['quote', late]]))).toEqual([['applied', null], ['applied', null], ['applied', null]]);
    expect(await row(first.id)).toMatchObject({ status: 'replaced', replaced_by: second.id });
    expect(await row(second.id)).toMatchObject({ status: 'open', replaced_by: null });
    expect(await row(late.id)).toMatchObject({ status: 'replaced', replaced_by: second.id });
    // Sem plaquinha, nada é substituído.
    const loose = [quote(), quote()];
    await push(loose.map((q) => ['quote', q]));
    expect((await row(loose[0].id)).status).toBe('open');
  });

  it('a plaquinha é da loja: o mesmo número em outra loja não substitui', async () => {
    const other = { ...quote({ card_number: 50 }), seller_id: clerk.id };
    expect(codes(await push([['quote', other]], a.terminal2))).toEqual([['applied', null]]);
    await push([['quote', quote({ card_number: 50 })]]);
    expect(await row(other.id)).toMatchObject({ status: 'open', branch_id: a.branch2.id });
  });

  it('plaquinha de orçamento já vencido: o antigo fica vencido, não substituído', async () => {
    const old = quote({ card_number: 41, quoted_at: iso(-3 * DAY) });
    const fresh = quote({ card_number: 41 });
    await push([['quote', old], ['quote', fresh]]);
    expect(await row(old.id)).toMatchObject({ status: 'expired', replaced_by: null });
    expect((await row(fresh.id)).status).toBe('open');
  });

  it('fora do formato ou com contas que não fecham: conflito', async () => {
    const item = (over = {}) => [{ id: uuidV7(), line: 1, product_id: product.id, quantity: 2, unit_price: 10, discount: 1, total: 19, ...over }];
    const bad = [
      quote({ total: 18 }),
      quote({ card_number: 0 }),
      quote({ card_number: 10000 }),
      quote({ card_number: '5' }),
      quote({ seller_id: null }),
      quote({ quoted_at: 'hoje' }),
      quote({ quoted_at: '2026-02-30T10:00:00Z' }),
      quote({ id: '019a0000-0000-4000-8000-000000000001' }),
      quote({}, item({ discount: 21, total: -1 })),
      quote({}, item({ total: 20 })),
      // Um item a mais e outro a menos: a soma bate, mas cada item precisa fechar.
      quote({ total: 29 }, [
        { id: uuidV7(), line: 1, product_id: product.id, quantity: 2, unit_price: 10, discount: 1, total: 20 },
        { id: uuidV7(), line: 2, product_id: product.id, quantity: 1, unit_price: 10, discount: 0, total: 9 },
      ]),
      quote({}, item({ quantity: 0, total: -1 })),
      quote({}, item({ release: { supervisor_id: operator.id, reason: ' ' } })),
      quote({}, [...item(), { id: uuidV7(), line: 1, product_id: product.id, quantity: 1, unit_price: 10, discount: 0, total: 10 }]),
      quote({ items: [] }),
    ];
    expect(codes(await push(bad.map((q) => ['quote', q])))).toEqual(bad.map(() => ['conflict', 'FA883']));
    const once = quote();
    await push([['quote', once]]);
    expect(codes(await push([['quote', { ...once, id: uuidV7() }]]))).toEqual([['conflict', 'FA883']]);
    const foreignSeller = (await ownerPool.query("SELECT id FROM user_account WHERE economic_group_id = $1 LIMIT 1", [b.group.id])).rows[0].id;
    expect(codes(await push([['quote', quote({ seller_id: foreignSeller })]]))).toEqual([['conflict', 'FA004']]);
    expect(codes(await push([['quote', quote({}, item({ product_id: uuidV7() }))]]))).toEqual([['conflict', 'FA004']]);
  });

  it('o orçamento gravado não muda', async () => {
    const payload = quote();
    await push([['quote', payload]]);
    await expect(ownerPool.query('UPDATE quote SET total = 1 WHERE id = $1', [payload.id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE quote SET seller_id = $2 WHERE id = $1', [payload.id, operator.id])).rejects.toSatisfy(hasCode('FA104'));
  });
});

describe('retaguarda e parâmetros', () => {
  it('lista com a situação de agora e detalhe para quem vê as vendas', async () => {
    const expired = quote({ quoted_at: iso(-2 * DAY), card_number: 77 });
    const open = quote({ card_number: 78 });
    await push([['quote', expired], ['quote', open]]);
    const manager = a.admin;
    const listed = await readAs(manager, 'SELECT * FROM app.list_quotes($1, NULL, NULL, NULL)', [a.branch1.id]);
    expect(listed.find((r) => r.id === expired.id)).toMatchObject({ status: 'expired', card_number: 77, item_count: 1, seller_name: clerk.name });
    expect(listed.find((r) => r.id === open.id)).toMatchObject({ status: 'open' });
    const onlyOpen = await readAs(manager, "SELECT id FROM app.list_quotes(NULL, NULL, NULL, 'open')");
    expect(onlyOpen.map((r) => r.id)).toContain(open.id);
    expect(onlyOpen.map((r) => r.id)).not.toContain(expired.id);
    const detail = (await readAs(manager, 'SELECT app.quote_detail($1) AS d', [open.id]))[0].d;
    expect(detail).toMatchObject({ status: 'open', card_number: 78, seller_name: clerk.name, items: [expect.objectContaining({ line: 1, quantity: 2 })] });
    expect(await readAs(operator, 'SELECT * FROM app.list_quotes()')).toEqual([]);
    expect((await readAs(operator, 'SELECT app.quote_detail($1) AS d', [open.id]))[0].d).toBeNull();
  });

  it('parâmetros da filial: quem mexe na estrutura; descem nos dados fiscais com o perfil do terminal', async () => {
    await expect(committed(operator, (client) => client.query('SELECT app.set_branch_sale_settings($1, 2, true)', [a.branch1.id])))
      .rejects.toSatisfy(hasCode('FA002'));
    for (const [days, pin] of [[91, false], [-1, false], [null, false], [2, null]]) {
      await expect(committed(a.admin, (client) => client.query('SELECT app.set_branch_sale_settings($1, $2, $3)', [a.branch1.id, days, pin])))
        .rejects.toSatisfy(hasCode('FA884'));
    }
    const fiscalXid = async () => (await ownerPool.query(
      "SELECT max(xid)::text AS x FROM sync_change WHERE entity = 'fiscal' AND entity_id = $1", [a.branch1.id],
    )).rows[0].x;
    const start = await fiscalXid();
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_sale_settings($1, 2, true)', [a.branch1.id]));
    const afterSettings = await fiscalXid();
    expect(BigInt(afterSettings)).toBeGreaterThan(BigInt(start ?? 0));
    await ownerPool.query("UPDATE terminal SET profile = 'quote' WHERE id = $1", [a.terminal1.id]);
    expect(BigInt(await fiscalXid())).toBeGreaterThan(BigInt(afterSettings));
    const fiscal = (await ownerPool.query('SELECT app.pdv_fiscal_data($1, $2) AS d', [a.branch1.id, a.terminal1.id])).rows[0].d;
    expect(fiscal).toMatchObject({ terminal_profile: 'quote', quote_validity_days: 2, seller_pin_required: true, fixed_seller_id: null });
    expect(Number(fiscal.last_quote_number)).toBe(number);
    await ownerPool.query("UPDATE terminal SET profile = 'cashier' WHERE id = $1", [a.terminal1.id]);
    await committed(a.admin, (client) => client.query('SELECT app.set_branch_sale_settings($1, 0, false)', [a.branch1.id]));
  });
});

describe('perfil do terminal', () => {
  it('quem aprova terminais troca o perfil; inválido ou terminal pendente, não', async () => {
    // O Gerente vê os terminais, mas quem troca o perfil é quem aprova.
    const manager = await person('Gerente');
    for (const user of [operator, manager]) {
      await expect(committed(user, (client) => client.query("SELECT app.set_terminal_profile($1, 'quote')", [a.terminal1.id])))
        .rejects.toSatisfy(hasCode('FA002'));
    }
    for (const profile of ['balcao', null]) {
      await expect(committed(a.admin, (client) => client.query('SELECT app.set_terminal_profile($1, $2)', [a.terminal1.id, profile])))
        .rejects.toSatisfy(hasCode('FA218'));
    }
    await committed(a.admin, (client) => client.query("SELECT app.set_terminal_profile($1, 'quote')", [a.terminal1.id]));
    expect((await ownerPool.query('SELECT profile FROM terminal WHERE id = $1', [a.terminal1.id])).rows[0].profile).toBe('quote');
    await committed(a.admin, (client) => client.query("SELECT app.set_terminal_profile($1, 'cashier')", [a.terminal1.id]));
    const pending = (await ownerPool.query(
      "INSERT INTO terminal (branch_id, public_key) VALUES ($1, $2) RETURNING id", [a.branch1.id, `chave-${tag()}`],
    )).rows[0];
    await expect(committed(a.admin, (client) => client.query("SELECT app.set_terminal_profile($1, 'quote')", [pending.id])))
      .rejects.toSatisfy(hasCode('FA303'));
  });
});

describe('vendedor na venda', () => {
  it('grava o vendedor; sem permissão de orçar ou vender, alerta; de outro grupo, conflito', async () => {
    const session = uuidV7();
    await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: iso(), opening_float: 0 }]]);
    let saleNumber = 900000 + randomInt(9000);
    const sale = (seller) => {
      saleNumber += 1;
      return {
        id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: null, seller_id: seller,
        sold_at: iso(), fiscal_model: '65',
        items: [{ id: uuidV7(), line: 1, product_id: product.id, quantity: 1, unit_price: 10, discount: 0, total: 10 }],
        payments: [{ id: uuidV7(), method: 'cash', amount: 10 }], subtotal: 10, discount_total: 0, total: 10,
      };
    };
    const byClerk = sale(clerk.id);
    const byOutsider = sale(outsider.id);
    const old = sale(undefined);
    expect(codes(await push([['sale', byClerk], ['sale', byOutsider], ['sale', old]]))).toEqual([['applied', null], ['applied', null], ['applied', null]]);
    const sellers = (await ownerPool.query('SELECT id, seller_id FROM sale WHERE id = ANY($1)', [[byClerk.id, byOutsider.id, old.id]])).rows;
    expect(Object.fromEntries(sellers.map((r) => [r.id, r.seller_id]))).toEqual({ [byClerk.id]: clerk.id, [byOutsider.id]: outsider.id, [old.id]: null });
    const alerts = (await ownerPool.query("SELECT sale_id FROM sale_alert WHERE kind = 'seller_permission' AND sale_id = ANY($1)", [[byClerk.id, byOutsider.id, old.id]])).rows;
    expect(alerts.map((r) => r.sale_id)).toEqual([byOutsider.id]);
    const foreignSeller = (await ownerPool.query('SELECT id FROM user_account WHERE economic_group_id = $1 LIMIT 1', [b.group.id])).rows[0].id;
    expect(codes(await push([['sale', sale(foreignSeller)]]))).toEqual([['conflict', 'FA004']]);
    expect(codes(await push([['sale', sale('nada')]]))).toEqual([['conflict', 'FA962']]);
    await expect(ownerPool.query('UPDATE sale SET seller_id = $2 WHERE id = $1', [byClerk.id, operator.id])).rejects.toSatisfy(hasCode('FA104'));
  });
});

describe('orçamento no caixa', () => {
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
  const lookup = (key, terminal) => asTerminal('SELECT app.pdv_quote($1) AS q', [key], terminal).then((r) => r.q);
  let session;
  let saleNumber = 800000 + randomInt(9000);
  const sale = (quoteId, overrides = {}) => {
    saleNumber += 1;
    return {
      id: uuidV7(), number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: null, seller_id: clerk.id,
      quote_id: quoteId, sold_at: iso(), fiscal_model: '65',
      items: [{ id: uuidV7(), line: 1, product_id: product.id, quantity: 1, unit_price: 10, discount: 0, total: 10 }],
      payments: [{ id: uuidV7(), method: 'cash', amount: 10 }], subtotal: 10, discount_total: 0, total: 10, ...overrides,
    };
  };
  const alertsOf = async (saleId) => (await ownerPool.query(
    "SELECT detail FROM sale_alert WHERE sale_id = $1 AND kind = 'quote_status'", [saleId],
  )).rows.map((r) => r.detail);

  beforeAll(async () => {
    session = uuidV7();
    await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: iso(), opening_float: 0 }]]);
  });

  it('busca pela plaquinha ou pelo código; só da loja, aberto e válido', async () => {
    const open = quote({ card_number: 300 }, [
      { id: uuidV7(), line: 1, product_id: product.id, quantity: 2, unit_price: 10, discount: 2, total: 18, release: { supervisor_id: operator.id, reason: 'Fiel' } },
    ]);
    const expired = quote({ card_number: 301, quoted_at: iso(-3 * DAY) });
    const replacedFirst = quote({ card_number: 302, quoted_at: iso(-60000) });
    const replacedSecond = quote({ card_number: 302 });
    await push([['quote', open], ['quote', expired], ['quote', replacedFirst], ['quote', replacedSecond]]);
    const other = { ...quote({ card_number: 303 }), seller_id: clerk.id };
    await push([['quote', other]], a.terminal2);
    const codeOf = async (id) => (await row(id)).code;

    const byCard = await lookup('300');
    expect(byCard).toMatchObject({ id: open.id, card_number: 300, seller_id: clerk.id, customer_id: null });
    expect(byCard.items).toEqual([{ line: 1, product_id: product.id, quantity: 2, unit_price: 10, discount: 2, total: 18, release: { supervisor_id: operator.id, reason: 'Fiel' }, zero_stock_release: null }]);
    expect((await lookup(` ${(await codeOf(open.id)).toLowerCase()} `)).id).toBe(open.id);
    // A plaquinha 302 aponta para o orçamento novo; o código do antigo diz que foi substituído.
    expect((await lookup('302')).id).toBe(replacedSecond.id);
    await expect(lookup(await codeOf(replacedFirst.id))).rejects.toSatisfy(hasCode('FA888'));
    await expect(lookup('301')).rejects.toSatisfy(hasCode('FA887'));
    await expect(lookup(await codeOf(expired.id))).rejects.toSatisfy(hasCode('FA887'));
    // Outra loja: não acha, nem pelo código.
    await expect(lookup('303')).rejects.toSatisfy(hasCode('FA885'));
    await expect(lookup(await codeOf(other.id))).rejects.toSatisfy(hasCode('FA885'));
    expect((await lookup('303', a.terminal2)).id).toBe(other.id);
    for (const key of ['', 'abc', '99999', 'O1-12', null]) await expect(lookup(key)).rejects.toSatisfy(hasCode('FA885'));

    const list = (await asTerminal('SELECT app.pdv_open_quotes() AS l')).l;
    const ids = list.map((q) => q.id);
    expect(ids).toContain(open.id);
    expect(ids).toContain(replacedSecond.id);
    for (const id of [expired.id, replacedFirst.id, other.id]) expect(ids).not.toContain(id);
    expect(list.find((q) => q.id === open.id)).toMatchObject({ card_number: 300, seller_name: clerk.name, item_count: 1 });
  });

  it('a venda fecha o orçamento; o que não está aberto vira alerta, e a venda vale', async () => {
    const q1 = quote({ card_number: 310 });
    const late = quote({ quoted_at: iso(-3 * DAY) });
    const other = { ...quote(), seller_id: clerk.id };
    await push([['quote', q1], ['quote', late]]);
    await push([['quote', other]], a.terminal2);

    const first = sale(q1.id);
    const second = sale(q1.id);
    const fromExpired = sale(late.id);
    const fromOther = sale(other.id);
    expect(codes(await push([['sale', first], ['sale', second], ['sale', fromExpired], ['sale', fromOther]])).map(([s]) => s))
      .toEqual(['applied', 'applied', 'applied', 'applied']);
    expect(await row(q1.id)).toMatchObject({ status: 'converted', converted_sale_id: first.id });
    await expect(lookup((await row(q1.id)).code)).rejects.toSatisfy(hasCode('FA886'));
    await expect(lookup('310')).rejects.toSatisfy(hasCode('FA885'));
    expect((await ownerPool.query('SELECT quote_id FROM sale WHERE id = $1', [first.id])).rows[0].quote_id).toBe(q1.id);
    expect(await alertsOf(first.id)).toEqual([]);
    expect(await alertsOf(second.id)).toEqual([{ quote_code: (await row(q1.id)).code, status: 'converted' }]);
    expect(await alertsOf(fromExpired.id)).toEqual([{ quote_code: (await row(late.id)).code, status: 'expired' }]);
    expect((await row(late.id)).status).toBe('open');
    expect(await alertsOf(fromOther.id)).toEqual([{ quote_code: (await row(other.id)).code, status: 'other_branch' }]);
    expect((await row(other.id)).status).toBe('open');
    // A plaquinha volta a ficar livre: novo orçamento nela não substitui o convertido.
    const reuse = quote({ card_number: 310 });
    await push([['quote', reuse]]);
    expect((await row(q1.id)).status).toBe('converted');
    expect((await row(reuse.id)).status).toBe('open');

    expect(codes(await push([['sale', sale(uuidV7())]]))).toEqual([['conflict', 'FA004']]);
    expect(codes(await push([['sale', sale('nada')]]))).toEqual([['conflict', 'FA962']]);
    await expect(ownerPool.query('UPDATE sale SET quote_id = NULL WHERE id = $1', [first.id])).rejects.toSatisfy(hasCode('FA104'));
    const detail = (await readAs(a.admin, 'SELECT app.sale_detail($1) AS d', [first.id]))[0].d;
    expect(detail).toMatchObject({ quote_id: q1.id, quote_code: (await row(q1.id)).code });
  });
});
