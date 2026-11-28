import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser, withCheckDigits } from './helpers.mjs';

// NF-e de venda no caixa (8B-2a): cliente pessoa jurídica (indicador de IE, cadastro no caixa) e a
// central recebendo a NF-e modelo 55 do terminal.

let a;
let b;
let operator;
let product;
let session;
let series55;
let series65;
let customer;
let clockMs = Date.now();
let sequence = 0;
let saleNumber = randomInt(1000, 900000);

const SP_IE = '110042490114';
const SP_CITY = '3550308';
const XML = `<nfeProc versao="4.00">${'x'.repeat(200)}</nfeProc>`;

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
/** CNPJ com dígitos certos, gerado ao acaso (não é de ninguém de propósito). */
const cnpj = () => withCheckDigits(`${randomInt(10_000_000, 100_000_000)}0001`);
const key = () => Array.from({ length: 44 }, () => randomInt(10)).join('');

async function run(setup, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setup(client);
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);
const asTerminal = (terminal, sql, params) => run((c) => setTerminal(c, terminal.id), sql, params);
const createAtPdv = (data, terminal = a.terminal1, who = operator) =>
  asTerminal(terminal, 'SELECT app.pdv_create_customer($1, $2::jsonb) AS r', [who.id, JSON.stringify(data)]).then((r) => r[0].r);
async function push(terminal, kind, payload) {
  sequence += 1;
  const rows = await asTerminal(terminal, 'SELECT app.pdv_push($1::jsonb) AS r', [JSON.stringify([
    { id: uuidV7(), sequence: Date.now() * 10 + sequence, kind, payload },
  ])]);
  return rows[0].r.results[0];
}
async function newSale({ model = '55', customerId = customer } = {}) {
  saleNumber += 1;
  const id = uuidV7();
  const result = await push(a.terminal1, 'sale', {
    id, number: saleNumber, cash_session_id: session, operator_id: operator.id, customer_id: customerId,
    sold_at: new Date().toISOString(), fiscal_model: model,
    items: [{ id: uuidV7(), line: 1, product_id: product, barcode_id: null, quantity: 1, unit_price: 10, discount: 0, total: 10, batch_id: null, release: null }],
    payments: [{ id: uuidV7(), method: 'cash', amount: 10, change: 0 }], subtotal: 10, discount_total: 0, total: 10,
  });
  expect(result).toMatchObject({ status: 'applied' });
  return id;
}
const nfe = (saleId, overrides = {}) => ({
  id: uuidV7(), model: '55', sale_id: saleId, series: series55, number: randomInt(1, 999999), access_key: key(), environment: 2,
  emission_type: 1, status: 'authorized', protocol: String(randomInt(1e9, 9e9)).padEnd(15, '0'), status_code: '100',
  reason: 'Autorizado o uso da NF-e', xml: XML, emitted_at: new Date().toISOString(), authorized_at: new Date().toISOString(), ...overrides,
});
const company = (overrides = {}) => ({
  personType: 'company', name: 'Farmácia Fictícia Ltda', tradeName: 'Fictícia', document: cnpj(), stateRegistration: SP_IE,
  email: 'compras@exemplo.test', phone: '1133334444', postalCode: '01001-000', street: 'Praça da Sé', streetNumber: '100',
  district: 'Sé', city: 'São Paulo', cityCode: SP_CITY, state: 'sp', ...overrides,
});

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows: [user] } = await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Operador ${randomInt(1e6)}`]);
  const role = (await ownerPool.query("SELECT id FROM role WHERE economic_group_id = $1 AND name = 'Operador de caixa'", [a.group.id])).rows[0].id;
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role, a.branch1.id]);
  operator = user;
  product = (await asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: `Produto NF-e ${randomInt(1e6)}`, barcode: gtin() })]))[0].id;
  await asUser(a.admin, 'SELECT app.set_product_price($1, NULL, 10, NULL)', [product]);
  session = uuidV7();
  expect((await push(a.terminal1, 'cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 })).status).toBe('applied');
  const seriesOf = async (model) => (await ownerPool.query(
    'SELECT series FROM terminal_fiscal_series WHERE terminal_id = $1 AND model = $2 AND deleted_at IS NULL', [a.terminal1.id, model],
  )).rows[0].series;
  series65 = await seriesOf('65');
  // Série da NF-e diferente da série da NFC-e, para a série de um modelo não valer no outro.
  await ownerPool.query(
    "UPDATE terminal_fiscal_series SET series = $2 WHERE terminal_id = $1 AND model = '55' AND deleted_at IS NULL",
    [a.terminal1.id, series65 === 880 ? 881 : 880],
  );
  series55 = await seriesOf('55');
  expect(series55).not.toBe(series65);
  customer = (await createAtPdv(company())).id;
});
afterAll(closePools);

describe('indicador de IE do cliente', () => {
  const createCustomer = (data) => asUser(a.admin, 'SELECT app.create_customer($1::jsonb) AS id', [JSON.stringify(data)]).then((r) => r[0].id);
  const indicator = (id) => ownerPool.query(
    'SELECT ie_indicator, app.customer_ie_indicator(ie_indicator, state_registration) AS effective FROM customer WHERE id = $1', [id],
  ).then((r) => r.rows[0]);

  it('vazio segue a inscrição: número é contribuinte, ISENTO é isento, sem inscrição não contribuinte', async () => {
    const base = { ...company(), personType: 'company' };
    expect(await indicator(await createCustomer({ ...base, document: cnpj() }))).toEqual({ ie_indicator: null, effective: 1 });
    expect(await indicator(await createCustomer({ ...base, document: cnpj(), stateRegistration: 'isento' }))).toEqual({ ie_indicator: null, effective: 2 });
    expect(await indicator(await createCustomer({ ...base, document: cnpj(), stateRegistration: null }))).toEqual({ ie_indicator: null, effective: 9 });
    // Informado vale mais que a inscrição (empresa com IE que não é contribuinte).
    expect(await indicator(await createCustomer({ ...base, document: cnpj(), ieIndicator: '9' }))).toEqual({ ie_indicator: 9, effective: 9 });
    expect(await indicator(await createCustomer({ ...base, document: cnpj(), stateRegistration: null, ieIndicator: 2 }))).toEqual({ ie_indicator: 2, effective: 2 });
  });

  it('indicador que não confere com a inscrição é recusado com FA964; a alteração também confere', async () => {
    const base = { ...company(), personType: 'company' };
    await expect(createCustomer({ ...base, document: cnpj(), stateRegistration: 'ISENTO', ieIndicator: '1' })).rejects.toSatisfy(hasCode('FA964'));
    await expect(createCustomer({ ...base, document: cnpj(), stateRegistration: null, ieIndicator: '1' })).rejects.toSatisfy(hasCode('FA964'));
    await expect(createCustomer({ ...base, document: cnpj(), ieIndicator: '2' })).rejects.toSatisfy(hasCode('FA964'));
    await expect(createCustomer({ ...base, document: cnpj(), ieIndicator: '3' })).rejects.toSatisfy(hasCode('FA964'));
    await expect(createCustomer({ ...base, document: cnpj(), ieIndicator: 'x' })).rejects.toSatisfy(hasCode('FA964'));
    await expect(createCustomer({ ...base, document: cnpj(), ieIndicator: '10' })).rejects.toSatisfy(hasCode('FA964'));
    const id = await createCustomer({ ...base, document: cnpj(), ieIndicator: '1' });
    const data = { ...base, document: (await ownerPool.query('SELECT document FROM customer WHERE id = $1', [id])).rows[0].document };
    await asUser(a.admin, 'SELECT app.update_customer($1, $2::jsonb)', [id, JSON.stringify({ ...data, stateRegistration: 'ISENTO', ieIndicator: '2' })]);
    expect(await indicator(id)).toEqual({ ie_indicator: 2, effective: 2 });
    await expect(asUser(a.admin, 'SELECT app.update_customer($1, $2::jsonb)', [id, JSON.stringify({ ...data, ieIndicator: '2' })]))
      .rejects.toSatisfy(hasCode('FA964'));
    await asUser(a.admin, 'SELECT app.update_customer($1, $2::jsonb)', [id, JSON.stringify({ ...data, ieIndicator: '' })]);
    expect(await indicator(id)).toEqual({ ie_indicator: null, effective: 1 });
  });
});

describe('pessoa jurídica cadastrada no caixa', () => {
  it('guarda CNPJ, razão social, fantasia, inscrição, e-mail e endereço; o caixa recebe a inscrição e o indicador', async () => {
    const data = company({ ieIndicator: '1' });
    const result = await createAtPdv(data);
    expect(result.data).toMatchObject({
      person_type: 'company', name: 'Farmácia Fictícia Ltda', trade_name: 'Fictícia', document: data.document,
      state_registration: SP_IE, ie_indicator: 1, email: 'compras@exemplo.test', postal_code: '01001000', street: 'Praça da Sé',
      street_number: '100', district: 'Sé', city: 'São Paulo', city_code: SP_CITY, state: 'SP',
    });
    const isento = await createAtPdv(company({ stateRegistration: 'Isento' }));
    expect(isento.data).toMatchObject({ state_registration: 'ISENTO', ie_indicator: 2 });
    const none = await createAtPdv(company({ stateRegistration: '' }));
    expect(none.data).toMatchObject({ state_registration: null, ie_indicator: 9 });
  });

  it('pessoa física continua como antes, sem fantasia; nascimento não vale para empresa', async () => {
    const person = await createAtPdv({ name: 'Cliente Pessoa Física', document: '52998224725', birthDate: '1990-01-02', tradeName: 'Nada' });
    expect(person.data).toMatchObject({ person_type: 'individual', trade_name: null, birth_date: '1990-01-02', ie_indicator: 9 });
    const firm = await createAtPdv(company({ birthDate: '1990-01-02' }));
    expect(firm.data.birth_date).toBeNull();
  });

  it('empresa sem endereço completo, com município de outro estado ou com dado errado é recusada', async () => {
    for (const field of ['postalCode', 'street', 'streetNumber', 'district', 'city', 'cityCode', 'state']) {
      await expect(createAtPdv(company({ [field]: ' ' })), field).rejects.toSatisfy(hasCode('FA904'));
    }
    await expect(createAtPdv(company({ cityCode: '3304557' }))).rejects.toSatisfy(hasCode('FA904'));
    await expect(createAtPdv(company({ cityCode: '3550308', state: 'XX' }))).rejects.toSatisfy(hasCode('FA904'));
    await expect(createAtPdv(company({ document: '11111111000111' }))).rejects.toSatisfy(hasCode('FA902'));
    await expect(createAtPdv(company({ stateRegistration: '123' }))).rejects.toSatisfy(hasCode('FA908'));
    await expect(createAtPdv(company({ stateRegistration: 'ISENTO', ieIndicator: '1' }))).rejects.toSatisfy(hasCode('FA964'));
    await expect(createAtPdv(company({ personType: 'ong' }))).rejects.toSatisfy(hasCode('FA904'));
    // Pessoa física com município informado também confere o estado.
    await expect(createAtPdv({ name: 'Cliente Outro Estado', document: '39053344705', cityCode: '3304557', state: 'SP' }))
      .rejects.toSatisfy(hasCode('FA904'));
  });

  it('a consulta do CNPJ no caixa é só de quem pode cadastrar cliente na filial do terminal', async () => {
    const can = (terminal, who) => asTerminal(terminal, 'SELECT app.pdv_can_create_customer($1) AS ok', [who?.id ?? null]).then((r) => r[0].ok);
    expect(await can(a.terminal1, operator)).toBe(true);
    expect(await can(a.terminal2, operator)).toBe(false);
    expect(await can(a.terminal1, b.admin)).toBe(false);
    expect(await can(a.terminal1, null)).toBe(false);
    await ownerPool.query('UPDATE user_account SET is_active = false WHERE id = $1', [a.secondAdmin.id]);
    expect(await can(a.terminal1, a.secondAdmin)).toBe(false);
    await expect(asUser(a.admin, 'SELECT app.pdv_can_create_customer($1)', [operator.id])).rejects.toSatisfy(hasCode('FA306'));
  });

  it('a descida do terminal leva a inscrição e o indicador do cliente', async () => {
    const [{ data }] = await ownerPool.query('SELECT data FROM app.pdv_customer_data($1, ARRAY[$2]::uuid[])', [a.terminal1.id, customer])
      .then((r) => r.rows);
    expect(data).toMatchObject({ state_registration: SP_IE, ie_indicator: 1 });
  });
});

describe('NF-e 55 do caixa na central', () => {
  it('autorizada: guarda com o modelo 55 e a série 55 do terminal; a venda fica autorizada e a série anda', async () => {
    const saleId = await newSale();
    const doc = nfe(saleId, { number: 700 });
    expect(await push(a.terminal1, 'nfce', doc)).toMatchObject({ status: 'applied', code: null });
    const row = (await ownerPool.query('SELECT model, series, status FROM fiscal_document WHERE id = $1', [doc.id])).rows[0];
    expect(row).toEqual({ model: '55', series: series55, status: 'authorized' });
    expect((await ownerPool.query('SELECT fiscal_status FROM sale WHERE id = $1', [saleId])).rows[0].fiscal_status).toBe('authorized');
    const used = await ownerPool.query(
      "SELECT model, last_used_number FROM terminal_fiscal_series WHERE terminal_id = $1 AND deleted_at IS NULL AND model = '55'", [a.terminal1.id],
    );
    expect(Number(used.rows[0].last_used_number)).toBeGreaterThanOrEqual(700);

    // Na retaguarda: a lista, a situação da venda e os arquivos dizem o modelo; NF-e não tem prazo de 30 minutos aqui.
    const listed = (await asUser(a.admin, 'SELECT * FROM app.list_fiscal_documents()')).find((r) => r.id === doc.id);
    expect(listed).toMatchObject({ model: '55', series: series55, cancelable_until: null });
    expect((await asUser(a.admin, 'SELECT app.sale_fiscal_document($1) AS d', [saleId]))[0].d).toMatchObject({ model: '55' });
    expect((await asUser(a.admin, 'SELECT app.fiscal_document_files($1) AS f', [doc.id]))[0].f).toMatchObject({ model: '55', xml: XML });

    // Pendente que depois autoriza: o caixa atualiza a mesma nota.
    const later = await newSale();
    const pending = nfe(later, { status: 'pending', protocol: null, authorized_at: null, status_code: null, reason: null });
    expect(await push(a.terminal1, 'nfce', pending)).toMatchObject({ status: 'applied' });
    expect(await push(a.terminal1, 'nfce', { ...pending, status: 'authorized', protocol: '135260000000777', authorized_at: new Date().toISOString() }))
      .toMatchObject({ status: 'applied' });
    expect((await ownerPool.query('SELECT status FROM fiscal_document WHERE id = $1', [pending.id])).rows[0].status).toBe('authorized');
  });

  it('a NFC-e continua igual, com ou sem o modelo no item; a lista mostra o prazo de cancelamento dela', async () => {
    const saleId = await newSale({ model: '65', customerId: null });
    const doc = { ...nfe(saleId, { series: series65 }) };
    delete doc.model;
    expect(await push(a.terminal1, 'nfce', doc)).toMatchObject({ status: 'applied' });
    const listed = (await asUser(a.admin, 'SELECT * FROM app.list_fiscal_documents()')).find((r) => r.id === doc.id);
    expect(listed.model).toBe('65');
    expect(listed.cancelable_until).not.toBeNull();
  });

  it('recusa modelo diferente do da venda, série de outro modelo, NF-e sem cliente, contingência e modelo desconhecido', async () => {
    const rejected = async (payload, detail) => {
      const result = await push(a.terminal1, 'nfce', payload);
      expect(result, detail).toMatchObject({ status: 'conflict', code: 'FA735' });
    };
    const sale55 = await newSale();
    const sale65 = await newSale({ model: '65', customerId: null });
    await rejected(nfe(sale65), 'NF-e numa venda de NFC-e');
    await rejected(nfe(sale55, { model: '65', series: series65 }), 'NFC-e numa venda de NF-e');
    await rejected(nfe(sale55, { series: series65 }), 'série da NFC-e');
    await rejected(nfe(sale55, { model: '57' }), 'modelo desconhecido');
    await rejected(nfe(sale55, { status: 'contingency', emission_type: 9, protocol: null, authorized_at: null }), 'contingência');
    // A contingência da NF-e é a SVC (6 ou 7), não a offline da NFC-e.
    expect(await push(a.terminal1, 'nfce', nfe(await newSale(), { emission_type: 6 }))).toMatchObject({ status: 'applied' });
    expect(await push(a.terminal1, 'nfce', nfe(await newSale(), { emission_type: 7 }))).toMatchObject({ status: 'applied' });
    await rejected(nfe(await newSale({ model: '65', customerId: null }), { model: '65', series: series65, emission_type: 6 }), 'NFC-e em SVC');
    await rejected(nfe(await newSale({ customerId: null })), 'sem cliente');

    // O mesmo id não troca de modelo.
    const doc = nfe(sale55, { status: 'pending', protocol: null, authorized_at: null });
    expect(await push(a.terminal1, 'nfce', doc)).toMatchObject({ status: 'applied' });
    await rejected({ ...doc, model: '65', series: series65 }, 'troca de modelo');
  });

  it('cancelar, reenviar e consultar a NF-e 55 pela central é recusado com FA780; o caixa também não cancela', async () => {
    const saleId = await newSale();
    const doc = nfe(saleId);
    await push(a.terminal1, 'nfce', doc);
    for (const action of ['cancel', 'resend', 'consult']) {
      await expect(asUser(a.admin, 'SELECT * FROM app.fiscal_action_context($1, $2)', [doc.id, action]), action)
        .rejects.toSatisfy(hasCode('FA780'));
    }
    await expect(asTerminal(a.terminal1, 'SELECT * FROM app.terminal_cancel_context($1, $2)', [doc.id, a.admin.id]))
      .rejects.toSatisfy(hasCode('FA780'));
    // Outro grupo continua sem ver a nota.
    await expect(asUser(b.admin, "SELECT * FROM app.fiscal_action_context($1, 'consult')", [doc.id])).rejects.toSatisfy(hasCode('FA006'));
  });

  it('o reenvio automático da central não pega a NF-e 55 (fica com o caixa)', async () => {
    // Tudo numa transação desfeita no fim: o lote é de todos os grupos e outros testes também reservam.
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      const old = new Date(Date.now() - 48 * 3_600_000).toISOString();
      const ids = {};
      for (const model of ['55', '65']) {
        const sale = await newSale(model === '55' ? {} : { model: '65', customerId: null });
        ids[model] = (await client.query(
          `INSERT INTO fiscal_document (economic_group_id, branch_id, terminal_id, sale_id, model, series, number, access_key, environment,
                                        emission_type, status, xml, emitted_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 2, 1, 'pending', $9, $10) RETURNING id`,
          [a.group.id, a.branch1.id, a.terminal1.id, sale, model, model === '55' ? series55 : series65, randomInt(1, 999999), key(), XML, old],
        )).rows[0].id;
      }
      await client.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'fiscal', true)");
      const picked = (await client.query('SELECT * FROM app.claim_fiscal_resend(30) AS id')).rows.map((r) => r.id);
      expect(picked).toContain(ids['65']);
      expect(picked).not.toContain(ids['55']);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
