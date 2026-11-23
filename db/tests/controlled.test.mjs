import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

let a;
let b;
let operator;
let pharmacist;
let session;
let b1;
let antimicrobial;
let common;
let batchL1;
let batchAM1;

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
const day = (offset) => new Date(Date.now() + offset * 86400000).toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });

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
async function push(entries) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setTerminal(client, a.terminal1.id);
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

const person = async (roleName) => {
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `${roleName} ${tag()}`])).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, a.branch1.id]);
  const role = (await ownerPool.query('SELECT id FROM role WHERE economic_group_id = $1 AND name = $2', [a.group.id, roleName])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, a.branch1.id]);
  return user;
};
const product = async (controlledClass) => {
  const sourceKey = `ctrl-${tag()}`;
  const catalogId = (await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey, name: `Controlado ${sourceKey}`, ...(controlledClass ? { controlledClass } : {}),
  })])).rows[0].id;
  return committed(a.admin, async (client) => {
    const barcode = gtin();
    const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({
      displayName: `Produto ${sourceKey}`, barcode, catalogProductId: catalogId,
    })]);
    await client.query('SELECT app.set_product_price($1, NULL, 20, NULL)', [rows[0].id]);
    return { id: rows[0].id, barcode };
  });
};

const complete = (overrides = {}) => ({
  id: uuidV7(), status: 'complete', pharmacist_id: pharmacist.id,
  prescription_type: 'notification_b', prescription_number: 'SP-123456', prescription_date: day(-2),
  prescriber_name: 'Dra. Ana Prescritora', prescriber_council: 'CRM', prescriber_number: '123456', prescriber_state: 'SP',
  buyer_name: 'João Comprador', buyer_document_type: 'rg', buyer_document: '12.345.678-9', buyer_issuer: 'SSP', buyer_state: 'SP',
  ...overrides,
});
let number = 0;
const sale = (item, quantity = 1) => {
  number += 1;
  return {
    id: uuidV7(), number, cash_session_id: session, operator_id: operator.id, customer_id: null, sold_at: new Date().toISOString(), fiscal_model: '65',
    items: [{ id: uuidV7(), line: 1, product_id: item.product.id, quantity, unit_price: 20, discount: 0, total: 20 * quantity, batch_id: item.batch ?? null, controlled: item.controlled ?? null }],
    payments: [{ id: uuidV7(), method: 'cash', amount: 20 * quantity }], subtotal: 20 * quantity, discount_total: 0, total: 20 * quantity,
  };
};
const alertsOf = async (payload) => (await ownerPool.query(
  "SELECT kind FROM sale_alert WHERE sale_id = $1 AND kind <> 'negative_stock' ORDER BY kind", [payload.id],
)).rows.map((row) => row.kind);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  operator = await person('Operador de caixa');
  pharmacist = await person('Farmacêutico');
  session = uuidV7();
  await push([['cash_session_open', { id: session, operator_id: operator.id, opened_at: new Date().toISOString(), opening_float: 0 }]]);
  b1 = await product('B1');
  antimicrobial = await product('antimicrobial');
  common = await product(null);
  await committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: b1.barcode, branchId: a.branch1.id, direction: 'in', quantity: 5, reason: 'Teste', batchNumber: 'L1', expiresOn: '2090-01-31',
  })]));
  batchL1 = (await ownerPool.query('SELECT id FROM product_batch WHERE product_id = $1', [b1.id])).rows[0].id;
  await committed(a.admin, (client) => client.query('SELECT app.adjust_stock($1::jsonb)', [JSON.stringify({
    productLookup: antimicrobial.barcode, branchId: a.branch1.id, direction: 'in', quantity: 5, reason: 'Teste', batchNumber: 'AM1', expiresOn: '2090-01-31',
  })]));
  batchAM1 = (await ownerPool.query('SELECT id FROM product_batch WHERE product_id = $1', [antimicrobial.id])).rows[0].id;
});
afterAll(closePools);

describe('venda de controlado', () => {
  it('completa: receita, comprador, lote e farmacêutico ficam registrados, sem alerta', async () => {
    const payload = sale({ product: b1, batch: batchL1, controlled: complete() });
    expect((await push([['sale', payload]]))[0]).toMatchObject({ status: 'applied' });
    const row = (await ownerPool.query('SELECT * FROM controlled_dispensing WHERE sale_id = $1', [payload.id])).rows[0];
    expect(row).toMatchObject({
      status: 'complete', controlled_class: 'B1', batch_id: batchL1, pharmacist_id: pharmacist.id, prescription_type: 'notification_b',
      prescription_number: 'SP-123456', prescriber_council: 'CRM', buyer_name: 'João Comprador', buyer_document_type: 'rg',
    });
    expect(Number(row.quantity)).toBe(1);
    expect(await alertsOf(payload)).toEqual([]);
    const balance = (await ownerPool.query('SELECT quantity FROM stock_balance WHERE batch_id = $1', [batchL1])).rows[0].quantity;
    expect(Number(balance)).toBe(4);
  });

  it('antimicrobiano exige idade e sexo do paciente; notificação exige o número', async () => {
    const bad = [
      sale({ product: antimicrobial, batch: batchAM1, controlled: complete({ prescription_type: 'antimicrobial', prescription_number: null }) }),
      sale({ product: antimicrobial, batch: batchAM1, controlled: complete({ prescription_type: 'antimicrobial', patient_age: 34 }) }),
      sale({ product: b1, batch: batchL1, controlled: complete({ buyer_document: null }) }),
      sale({ product: b1, batch: batchL1, controlled: complete({ buyer_issuer: ' ' }) }),
      sale({ product: b1, batch: batchL1, controlled: { ...complete(), id: '019a0000-0000-4000-8000-000000000001' } }),
      sale({ product: b1, batch: batchL1, controlled: complete({ prescription_number: null }) }),
      sale({ product: b1, batch: null, controlled: complete() }),
      sale({ product: b1, batch: batchL1, controlled: complete({ prescriber_state: 'sp' }) }),
      sale({ product: b1, batch: batchL1, controlled: complete({ prescriber_council: 'XYZ' }) }),
      sale({ product: b1, batch: batchL1, controlled: complete({ buyer_name: 'A' }) }),
      sale({ product: b1, batch: batchL1, controlled: complete({ prescription_date: '2026-13-01' }) }),
      sale({ product: b1, batch: batchL1, controlled: complete({ patient_sex: 'X' }) }),
      sale({ product: b1, batch: batchL1, controlled: { ...complete(), id: 'nada' } }),
      sale({ product: b1, batch: batchL1, controlled: { ...complete(), status: 'outro' } }),
      sale({ product: common, batch: null, controlled: complete() }),
    ];
    const results = await push(bad.map((payload) => ['sale', payload]));
    expect(results.map((r) => [r.status, r.code])).toEqual(bad.map(() => ['conflict', 'FA990']));
    // Antimicrobiano sem lote: a venda completa exige o lote.
    const noBatch = sale({ product: antimicrobial, controlled: { ...complete({ prescription_type: 'antimicrobial', prescription_number: null }), patient_age: 34, patient_sex: 'F' }, batch: null });
    expect((await push([['sale', noBatch]]))[0].code).toBe('FA990');
    // Com lote, idade e sexo, e sem número (não é notificação), passa sem alerta.
    const ok = sale({ product: antimicrobial, controlled: { ...complete({ prescription_type: 'antimicrobial', prescription_number: null }), patient_age: 34, patient_sex: 'F' }, batch: batchAM1 });
    expect((await push([['sale', ok]]))[0]).toMatchObject({ status: 'applied', code: null });
    expect(await alertsOf(ok)).toEqual([]);
  });

  it('pendente: liberada com estoque negativo, sem receita, com alerta para a manutenção', async () => {
    const payload = sale({ product: antimicrobial, controlled: { id: uuidV7(), status: 'pending', pharmacist_id: pharmacist.id, pending_reason: 'Sem lote no sistema; nota ainda não lançada' } });
    expect((await push([['sale', payload]]))[0]).toMatchObject({ status: 'applied' });
    const row = (await ownerPool.query('SELECT status, batch_id, pending_reason, prescription_type FROM controlled_dispensing WHERE sale_id = $1', [payload.id])).rows[0];
    expect(row).toEqual({ status: 'pending', batch_id: null, pending_reason: 'Sem lote no sistema; nota ainda não lançada', prescription_type: null });
    expect(await alertsOf(payload)).toEqual(['controlled_pending']);
    // Pendente sem motivo, ou com receita junto: conflito.
    const results = await push([
      ['sale', sale({ product: antimicrobial, controlled: { id: uuidV7(), status: 'pending', pharmacist_id: pharmacist.id } })],
      ['sale', sale({ product: antimicrobial, controlled: { ...complete(), status: 'pending', pending_reason: 'x' } })],
    ]);
    expect(results.map((r) => r.code)).toEqual(['FA990', 'FA990']);
  });

  it('alertas: sem dados, farmacêutico sem permissão, receita vencida ou futura, tipo errado', async () => {
    const cases = [
      [sale({ product: b1, batch: batchL1 }), ['controlled_missing']],
      [sale({ product: b1, batch: batchL1, controlled: complete({ pharmacist_id: operator.id }) }), ['controlled_release']],
      [sale({ product: b1, batch: batchL1, controlled: complete({ prescription_date: day(-31) }) }), ['prescription_expired']],
      [sale({ product: b1, batch: batchL1, controlled: complete({ prescription_date: day(2) }) }), ['prescription_expired']],
      [sale({ product: b1, batch: batchL1, controlled: complete({ prescription_type: 'special_control', prescription_number: null }) }), ['prescription_type']],
      [sale({ product: b1, batch: batchL1, controlled: complete({ prescription_date: day(-30) }) }), []],
    ];
    const results = await push(cases.map(([payload]) => ['sale', payload]));
    expect(results.every((r) => r.status === 'applied')).toBe(true);
    for (const [payload, expected] of cases) expect(await alertsOf(payload)).toEqual(expected);
  });

  it('farmacêutico de outro grupo não vale', async () => {
    const foreign = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [b.group.id, `Outro ${tag()}`])).rows[0];
    const results = await push([['sale', sale({ product: b1, batch: batchL1, controlled: complete({ pharmacist_id: foreign.id }) })]]);
    expect(results[0].code).toBe('FA004');
  });
});

describe('retaguarda e travas', () => {
  it('lista para quem vê controlados, com o documento mascarado', async () => {
    const list = await readAs(pharmacist, 'SELECT * FROM app.list_controlled_dispensings(NULL, NULL, NULL)');
    expect(list.length).toBeGreaterThan(0);
    const first = list.find((row) => row.status === 'complete' && row.buyer_name === 'João Comprador');
    expect(first).toMatchObject({ buyer_document_masked: '*********8-9', batch_number: 'L1', prescriber: 'Dra. Ana Prescritora · CRM 123456/SP', pharmacist_name: pharmacist.name });
    expect((await readAs(pharmacist, "SELECT * FROM app.list_controlled_dispensings('pending', NULL, NULL)")).every((row) => row.status === 'pending')).toBe(true);
    expect(await readAs(operator, 'SELECT * FROM app.list_controlled_dispensings(NULL, NULL, NULL)')).toEqual([]);
    expect(await readAs(b.admin, 'SELECT * FROM app.list_controlled_dispensings(NULL, NULL, NULL)')).toEqual([]);
    expect(await readAs(operator, 'SELECT id FROM v_controlled_dispensing')).toEqual([]);
    expect((await readAs(pharmacist, 'SELECT id FROM v_controlled_dispensing')).length).toBe(list.length);
  });

  it('o registro da venda não muda', async () => {
    const id = (await ownerPool.query('SELECT id FROM controlled_dispensing LIMIT 1')).rows[0].id;
    await expect(ownerPool.query('UPDATE controlled_dispensing SET quantity = 9 WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
    await expect(ownerPool.query('UPDATE controlled_dispensing SET pharmacist_id = $2 WHERE id = $1', [id, operator.id])).rejects.toSatisfy(hasCode('FA104'));
  });

  it('tipo de receita e validade por classe', async () => {
    const rows = (await ownerPool.query(`SELECT c, app.prescription_type_for(c) AS t FROM unnest(ARRAY['A1','A2','A3','B1','B2','C1','C2','C3','C4','C5','D1','antimicrobial']) c`)).rows;
    expect(Object.fromEntries(rows.map((r) => [r.c, r.t]))).toEqual({
      A1: 'notification_a', A2: 'notification_a', A3: 'notification_a', B1: 'notification_b', B2: 'notification_b2',
      C1: 'special_control', C2: 'notification_retinoid', C3: 'notification_thalidomide', C4: 'special_control', C5: 'special_control',
      D1: 'special_control', antimicrobial: 'antimicrobial',
    });
    expect((await ownerPool.query(`SELECT app.prescription_valid_days('antimicrobial') a, app.prescription_valid_days('notification_b') b`)).rows[0]).toEqual({ a: 10, b: 30 });
  });
});
