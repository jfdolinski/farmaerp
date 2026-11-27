import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asUser, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot,
} from './helpers.mjs';

// Parte E1: conteúdo do XML guardado na nota, duplicatas (financeiro) e auditoria das alterações.

let a;
let b;
let viewer;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows: [role] } = await ownerPool.query(
    `INSERT INTO role (economic_group_id, name) VALUES ($1, 'Só vê compras') RETURNING *`, [a.group.id],
  );
  await ownerPool.query(`INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = 'purchases.view'`, [role.id]);
  viewer = (await ownerPool.query(
    `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Vê compras') RETURNING *`, [a.group.id],
  )).rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [viewer.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [viewer.id, role.id, a.branch1.id]);
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
    emitter: { cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA DO CONTEUDO LTDA', state: 'SP' },
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
const itemsOf = (client, invoiceId) =>
  client.query('SELECT * FROM purchase_invoice_item WHERE invoice_id = $1 ORDER BY item_number', [invoiceId]).then((r) => r.rows);
const store = (client, id, content, installments) =>
  client.query('SELECT app.store_purchase_content($1, $2::jsonb, $3::jsonb)', [id, JSON.stringify(content), JSON.stringify(installments)]);
const extra = (client, id) => client.query('SELECT app.purchase_invoice_extra($1) AS x', [id]).then((r) => r.rows[0].x);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};
/**
 * Rotina da API: sem usuário, com app.worker = purchase_content. Sem usuário a RLS esconde as linhas,
 * então quem quer conferir o resultado grava (commit) e lê como dono.
 */
async function asWorker(fn, { worker = 'purchase_content', commit = false } = {}) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', $1, true)", [worker]);
    const result = await fn(client);
    await client.query(commit ? 'COMMIT' : 'ROLLBACK');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
/** Grava de verdade como o administrador do grupo A (fora da transação do teste). */
async function committed(fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } finally {
    client.release();
  }
}
const committedInvoice = (data = {}) => committed((client) => importInvoice(client, invoice(data)));
/** Executa como dono numa transação desfeita no final. */
async function asOwnerTx(fn) {
  const client = await ownerPool.connect();
  try {
    await client.query('BEGIN');
    return await fn(client);
  } finally {
    await client.query('ROLLBACK');
    client.release();
  }
}
const ownerRow = (sql, params) => ownerPool.query(sql, params).then((r) => r.rows);
/** Erro de CHECK da tabela, pelo nome da trava. */
const violates = async (client, sql, params, constraint) => {
  await client.query('SAVEPOINT c');
  await expect(client.query(sql, params)).rejects.toMatchObject({ code: '23514', constraint });
  await client.query('ROLLBACK TO c');
};
const denied = async (client, sql, params) => {
  await client.query('SAVEPOINT d');
  await expect(client.query(sql, params)).rejects.toThrow(/permission denied/);
  await client.query('ROLLBACK TO d');
};

const CONTENT = { ide: { nNF: '123', natOp: 'VENDA' }, transp: { modFrete: '0' }, infAdic: { infCpl: 'Pedido 55' } };
const INSTALLMENTS = [
  { number: '001', dueDate: '2026-12-20', amount: '10.50' },
  { number: ' 002 ', dueDate: '2027-01-20', amount: '10.5' },
];

describe('conteúdo do XML e duplicatas', () => {
  it('quem importa grava o conteúdo e as duplicatas, na ordem; a tela recebe tudo', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await store(client, id, CONTENT, INSTALLMENTS);
      const x = await extra(client, id);
      expect(x.content).toEqual(CONTENT);
      expect(x.content_read_at).not.toBeNull();
      expect(x.content_error).toBeNull();
      expect(x.installments).toEqual([
        { line: 1, number: '001', due_date: '2026-12-20', amount: 10.5 },
        { line: 2, number: '002', due_date: '2027-01-20', amount: 10.5 },
      ]);
      const { rows } = await client.query('SELECT economic_group_id, branch_id FROM v_purchase_invoice_installment WHERE invoice_id = $1', [id]);
      expect(rows).toEqual([
        { economic_group_id: a.group.id, branch_id: a.branch1.id },
        { economic_group_id: a.group.id, branch_id: a.branch1.id },
      ]);
    });
  });

  it('nota sem cobrança fica com o financeiro vazio; sem número e sem vencimento também valem', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await store(client, id, CONTENT, []);
      expect((await extra(client, id)).installments).toEqual([]);
      const other = await importInvoice(client, invoice());
      await store(client, other, CONTENT, [{ number: ' ', dueDate: '2026-12-01', amount: '0' }]);
      expect((await extra(client, other)).installments).toEqual([{ line: 1, number: null, due_date: '2026-12-01', amount: 0 }]);
    });
  });

  it('já lido: não grava de novo nem duplica o financeiro', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await store(client, id, CONTENT, INSTALLMENTS);
      await store(client, id, { outro: true }, [{ number: '9', dueDate: '2030-01-01', amount: '1' }]);
      const x = await extra(client, id);
      expect(x.content).toEqual(CONTENT);
      expect(x.installments).toHaveLength(2);
    });
  });

  it.each([
    ['conteúdo que não é objeto', [], INSTALLMENTS],
    ['duplicatas que não são lista', CONTENT, {}],
    ['duplicata que não é objeto', CONTENT, ['x']],
    ['valor inválido', CONTENT, [{ number: '1', dueDate: '2026-12-01', amount: '1,50' }]],
    ['valor negativo', CONTENT, [{ number: '1', dueDate: '2026-12-01', amount: '-1' }]],
    ['valor com três casas', CONTENT, [{ number: '1', dueDate: '2026-12-01', amount: '1.505' }]],
    ['valor grande demais', CONTENT, [{ number: '1', dueDate: '2026-12-01', amount: '12345678901234' }]],
    ['vencimento inválido', CONTENT, [{ number: '1', dueDate: '01/12/2026', amount: '1' }]],
    ['vencimento que não existe', CONTENT, [{ number: '1', dueDate: '2026-02-30', amount: '1' }]],
    ['sem valor', CONTENT, [{ number: '1', dueDate: '2026-12-01' }]],
    ['segunda duplicata inválida', CONTENT, [{ number: '1', dueDate: '2026-12-01', amount: '1' }, { number: '2', dueDate: '2026-12-01', amount: 'x' }]],
    ['mais de 120 duplicatas', CONTENT, Array.from({ length: 121 }, () => ({ number: '1', dueDate: '2026-12-01', amount: '1' }))],
  ])('recusa %s', async (_name, content, installments) => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await expectCode(client, () => store(client, id, content, installments), 'FA005');
      const x = await extra(client, id);
      expect(x.content).toBeNull();
      expect(x.installments).toEqual([]);
    });
  });

  it('duplicata sem vencimento vale (o dVenc é opcional), com valor numérico', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await store(client, id, CONTENT, [{ amount: 7.25 }, { number: '2', dueDate: null, amount: '3' }]);
      expect((await extra(client, id)).installments).toEqual([
        { line: 1, number: null, due_date: null, amount: 7.25 },
        { line: 2, number: '2', due_date: null, amount: 3 },
      ]);
    });
  });

  it('aceita exatamente 120 duplicatas e número com 60 letras', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      const list = Array.from({ length: 120 }, (_, i) => ({ number: i === 0 ? 'N'.repeat(60) : String(i), dueDate: '2026-12-01', amount: '1' }));
      await store(client, id, CONTENT, list);
      const x = await extra(client, id);
      expect(x.installments).toHaveLength(120);
      expect(x.installments[119].line).toBe(120);
    });
  });

  it('quem só vê compras não grava; outro grupo não acha a nota; nota inexistente avisa', async () => {
    const id = await committedInvoice();
    await asUser(viewer.id, async (client) => {
      await expectCode(client, () => store(client, id, CONTENT, []), 'FA002');
      expect((await extra(client, id)).content).toBeNull();
    });
    await asUser(b.admin.id, async (client) => {
      await expectCode(client, () => store(client, id, CONTENT, []), 'FA002');
      expect(await extra(client, id)).toBeNull();
    });
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => store(client, '0190a000-0000-7000-8000-000000000000', CONTENT, []), 'FA006');
    });
  });

  it('o conteúdo gravado não muda mais, nem as duplicatas', async () => {
    const id = await committedInvoice();
    await asWorker((client) => store(client, id, CONTENT, INSTALLMENTS), { commit: true });
    const other = await committedInvoice();
    await asOwnerTx(async (client) => {
      await expectCode(client, () => client.query(`UPDATE purchase_invoice SET content = '{"a":1}' WHERE id = $1`, [id]), 'FA104');
      await expectCode(client, () => client.query('UPDATE purchase_invoice SET content_read_at = now() WHERE id = $1', [id]), 'FA104');
      await expectCode(client, () => client.query('UPDATE purchase_invoice SET content = NULL, content_read_at = NULL WHERE id = $1', [id]), 'FA104');
      await expectCode(client, () => client.query('UPDATE purchase_invoice_installment SET amount = 1 WHERE invoice_id = $1', [id]), 'FA104');
      await expectCode(client, () => client.query('UPDATE purchase_invoice_installment SET due_date = NULL WHERE invoice_id = $1', [id]), 'FA104');
      // A primeira leitura (sem conteúdo antes) passa: é o que a função faz.
      await client.query(`UPDATE purchase_invoice SET content = '{"a":1}', content_read_at = now() WHERE id = $1`, [other]);
      // Outra coluna da nota lida continua mudando.
      await client.query('UPDATE purchase_invoice SET updated_at = now() WHERE id = $1', [id]);
    });
  });

  it('a API não escreve direto nas tabelas novas', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await importInvoice(client, invoice());
      await denied(client, 'INSERT INTO purchase_invoice_installment (economic_group_id, branch_id, invoice_id, line, amount) VALUES ($1, $2, $3, 1, 1)',
        [a.group.id, a.branch1.id, id]);
      await denied(client, `INSERT INTO purchase_invoice_audit (economic_group_id, branch_id, invoice_id, kind, detail) VALUES ($1, $2, $3, 'linked', '{}')`,
        [a.group.id, a.branch1.id, id]);
      await denied(client, `UPDATE purchase_invoice SET content = '{}', content_read_at = now() WHERE id = $1`, [id]);
      await denied(client, 'SELECT app.record_purchase_audit($1, $2, $3)', [id, 'linked', '{}']);
      await denied(client, 'SELECT app.require_purchase_content_worker()', []);
    });
  });

  it('travas da tabela: conteúdo objeto, leitura junto, erro curto, duplicata e auditoria válidas', async () => {
    const id = await committedInvoice();
    await asOwnerTx(async (client) => {
      const fails = (sql, params, constraint) => violates(client, sql, params, constraint);
      await fails(`UPDATE purchase_invoice SET content = '[]', content_read_at = now() WHERE id = $1`, [id], 'purchase_invoice_content_check');
      await fails(`UPDATE purchase_invoice SET content = '{}' WHERE id = $1`, [id], 'purchase_invoice_content_read_check');
      await fails('UPDATE purchase_invoice SET content_read_at = now() WHERE id = $1', [id], 'purchase_invoice_content_read_check');
      await fails(`UPDATE purchase_invoice SET content_error = '' WHERE id = $1`, [id], 'purchase_invoice_content_error_check');
      await fails('UPDATE purchase_invoice SET content_error = repeat($2, 501) WHERE id = $1', [id, 'x'], 'purchase_invoice_content_error_check');
      await client.query('UPDATE purchase_invoice SET content_error = repeat($2, 500) WHERE id = $1', [id, 'x']);
      const ins = 'INSERT INTO purchase_invoice_installment (economic_group_id, branch_id, invoice_id, line, number, amount) VALUES ($1, $2, $3, $4, $5, $6)';
      const base = [a.group.id, a.branch1.id, id];
      await fails(ins, [...base, 0, '1', 1], 'purchase_invoice_installment_line_check');
      await fails(ins, [...base, 121, '1', 1], 'purchase_invoice_installment_line_check');
      await fails(ins, [...base, 1, ' ', 1], 'purchase_invoice_installment_number_check');
      await fails(ins, [...base, 1, 'x'.repeat(61), 1], 'purchase_invoice_installment_number_check');
      await fails(ins, [...base, 1, '1', -0.01], 'purchase_invoice_installment_amount_check');
      await client.query(ins, [...base, 120, 'x'.repeat(60), 0]);
      await client.query('SAVEPOINT u');
      await expect(client.query(ins, [...base, 120, '2', 0])).rejects.toMatchObject({ code: '23505', constraint: 'purchase_invoice_installment_line_key' });
      await client.query('ROLLBACK TO u');
      const audit = 'INSERT INTO purchase_invoice_audit (economic_group_id, branch_id, invoice_id, kind, detail) VALUES ($1, $2, $3, $4, $5::jsonb)';
      await fails(audit, [...base, 'posted', '{}'], 'purchase_invoice_audit_kind_check');
      await fails(audit, [...base, 'linked', '[]'], 'purchase_invoice_audit_detail_check');
      await client.query(audit, [...base, 'discarded', '{}']);
      await expectCode(client, () => client.query(`UPDATE purchase_invoice_audit SET detail = '{"x":1}' WHERE invoice_id = $1`, [id]), 'FA104');
      await expectCode(client, () => client.query('UPDATE purchase_invoice_audit SET deleted_at = now() WHERE invoice_id = $1', [id]), 'FA104');
    });
  });
});

describe('rotina que lê as notas já recebidas', () => {
  it('só a rotina pega a fila, grava e marca falha', async () => {
    const id = await committedInvoice();
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => client.query('SELECT app.purchase_content_pending(10)'), 'FA002');
      await expectCode(client, () => client.query('SELECT app.purchase_content_failed($1, $2)', [id, 'x']), 'FA002');
    });
    await asWorker(async (client) => {
      await expectCode(client, () => client.query('SELECT app.purchase_content_pending(10)'), 'FA002');
      await expectCode(client, () => store(client, id, CONTENT, []), 'FA002');
      await expectCode(client, () => client.query('SELECT app.purchase_content_failed($1, $2)', [id, 'x']), 'FA002');
    }, { worker: 'abc' });
    await asWorker(async (client) => {
      await expectCode(client, () => client.query('SELECT app.purchase_content_pending(10)'), 'FA002');
    }, { worker: '' });
    // Usuário logado que também marca a rotina continua sem a fila.
    await asUser(a.admin.id, async (client) => {
      await client.query("SELECT set_config('app.worker', 'purchase_content', true)");
      await expectCode(client, () => client.query('SELECT app.purchase_content_pending(10)'), 'FA002');
    });
    expect((await ownerRow('SELECT content, content_error FROM purchase_invoice WHERE id = $1', [id]))[0]).toEqual({ content: null, content_error: null });
  });

  it('a fila traz as notas sem conteúdo com o XML, as mais antigas primeiro; lida ou com falha sai da fila', async () => {
    const first = await committedInvoice();
    const second = await committedInvoice();
    const third = await committedInvoice();
    await asWorker(async (client) => {
      const queue = async (limit = 100) => (await client.query('SELECT app.purchase_content_pending($1) AS q', [limit])).rows[0].q;
      const ids = (await queue()).map((row) => row.id);
      expect(ids.indexOf(first)).toBeGreaterThanOrEqual(0);
      expect(ids.indexOf(first)).toBeLessThan(ids.indexOf(second));
      expect(ids.indexOf(second)).toBeLessThan(ids.indexOf(third));
      expect((await queue()).find((row) => row.id === first).xml).toBe(XML);

      await store(client, first, CONTENT, INSTALLMENTS);
      await client.query('SELECT app.purchase_content_failed($1, $2)', [second, '  Falha ao ler o XML: tag ausente.  ']);
      const after = (await queue()).map((row) => row.id);
      expect(after).not.toContain(first);
      expect(after).not.toContain(second);
      expect(after).toContain(third);
      // Falha depois de lida não marca nada.
      await client.query('SELECT app.purchase_content_failed($1, $2)', [first, 'tarde']);
    }, { commit: true });
    const rows = await ownerRow('SELECT id, content IS NOT NULL AS read, content_error FROM purchase_invoice WHERE id = ANY($1)', [[first, second, third]]);
    const by = Object.fromEntries(rows.map((r) => [r.id, r]));
    expect(by[first]).toMatchObject({ read: true, content_error: null });
    expect(by[second]).toMatchObject({ read: false, content_error: 'Falha ao ler o XML: tag ausente.' });
    expect(by[third]).toMatchObject({ read: false, content_error: null });
  });

  it('nota sem o XML guardado não entra na fila', async () => {
    const id = await committedInvoice();
    await asOwnerTx(async (client) => {
      const pending = async () => {
        const { rows: [{ q }] } = await client.query('SELECT app.purchase_content_pending(100) AS q');
        return q.map((row) => row.id);
      };
      await client.query("SELECT set_config('app.worker', 'purchase_content', true)");
      expect(await pending()).toContain(id);
      await client.query('UPDATE purchase_invoice_document SET deleted_at = now() WHERE invoice_id = $1', [id]);
      expect(await pending()).not.toContain(id);
    });
  });

  it('o limite vale entre 1 e 100; vazio usa 20', async () => {
    for (let i = 0; i < 3; i += 1) await committedInvoice();
    await asWorker(async (client) => {
      const size = async (limit) => (await client.query('SELECT jsonb_array_length(app.purchase_content_pending($1)) AS n', [limit])).rows[0].n;
      expect(await size(1)).toBe(1);
      expect(await size(0)).toBe(1);
      expect(await size(-5)).toBe(1);
      expect(await size(2)).toBe(2);
      const { rows: [{ total }] } = await ownerPool.query(
        `SELECT count(*)::int AS total FROM purchase_invoice i JOIN purchase_invoice_document d ON d.invoice_id = i.id AND d.deleted_at IS NULL
          WHERE i.content IS NULL AND i.content_error IS NULL`,
      );
      expect(await size(null)).toBe(Math.min(total, 20));
      expect(await size(1000)).toBe(Math.min(total, 100));
    });
  });

  it('falha sem motivo grava um texto padrão; motivo longo é cortado em 500', async () => {
    const id = await committedInvoice();
    const other = await committedInvoice();
    const third = await committedInvoice();
    await asWorker(async (client) => {
      await client.query('SELECT app.purchase_content_failed($1, $2)', [id, '   ']);
      await client.query('SELECT app.purchase_content_failed($1, $2)', [other, 'y'.repeat(600)]);
      await client.query('SELECT app.purchase_content_failed($1, NULL)', [third]);
    }, { commit: true });
    const rows = await ownerRow('SELECT id, content_error FROM purchase_invoice WHERE id = ANY($1)', [[id, other, third]]);
    const by = Object.fromEntries(rows.map((r) => [r.id, r.content_error]));
    expect(by[id]).toBe('Falha na leitura do XML.');
    expect(by[other]).toBe('y'.repeat(500));
    expect(by[third]).toBe('Falha na leitura do XML.');
  });

  it('a rotina grava o conteúdo na filial da nota', async () => {
    const id = await committedInvoice();
    await asWorker((client) => store(client, id, CONTENT, INSTALLMENTS), { commit: true });
    expect(await ownerRow('SELECT branch_id, economic_group_id, line FROM purchase_invoice_installment WHERE invoice_id = $1 ORDER BY line', [id])).toEqual([
      { branch_id: a.branch1.id, economic_group_id: a.group.id, line: 1 },
      { branch_id: a.branch1.id, economic_group_id: a.group.id, line: 2 },
    ]);
    const [row] = await ownerRow('SELECT content, content_read_at IS NOT NULL AS read FROM purchase_invoice WHERE id = $1', [id]);
    expect(row).toEqual({ content: CONTENT, read: true });
  });
});

describe('auditoria da nota', () => {
  const link = (client, itemId, productId) => client.query('SELECT app.link_purchase_item($1, $2)', [itemId, productId]);
  const setBatches = (client, itemId, batches) =>
    client.query('SELECT app.set_purchase_item_batches($1, $2::jsonb)', [itemId, JSON.stringify(batches)]);
  const auditOf = (client, id) =>
    client.query('SELECT kind, detail, user_id FROM purchase_invoice_audit WHERE invoice_id = $1 ORDER BY occurred_at, id', [id]).then((r) => r.rows);

  it('item ligado a produto e trocado de produto, com quem fez e os nomes', async () => {
    await asUser(a.admin.id, async (client) => {
      const first = await createProduct(client, { displayName: 'Primeiro produto' });
      const second = await createProduct(client, { displayName: 'Segundo produto' });
      const { rows: names } = await client.query('SELECT id, code::text || $2 || display_name AS label FROM product WHERE id = ANY($1)', [[first, second], ' · ']);
      const label = Object.fromEntries(names.map((r) => [r.id, r.label]));
      const id = await importInvoice(client, invoice({ items: [item({ description: 'DIPIRONA 500' })] }));
      const [it] = await itemsOf(client, id);
      await link(client, it.id, first);
      await link(client, it.id, second);
      const rows = await auditOf(client, id);
      expect(rows).toEqual([
        {
          kind: 'linked', user_id: a.admin.id,
          detail: { item_number: 1, description: 'DIPIRONA 500', source: 'manual', product_id: first, product: label[first], previous_product: null },
        },
        {
          kind: 'linked', user_id: a.admin.id,
          detail: { item_number: 1, description: 'DIPIRONA 500', source: 'manual', product_id: second, product: label[second], previous_product: label[first] },
        },
      ]);
    });
  });

  it('item que liga sozinho na importação não entra na auditoria; mudar outra coluna do item também não', async () => {
    await asUser(a.admin.id, async (client) => {
      const code = gtin();
      await createProduct(client, { barcode: code });
      const id = await importInvoice(client, invoice({ items: [item({ barcode: code })] }));
      const [it] = await itemsOf(client, id);
      expect(it.product_id).not.toBeNull();
      expect(await auditOf(client, id)).toEqual([]);
    });
    const id = await committedInvoice();
    await asOwnerTx(async (client) => {
      await client.query('UPDATE purchase_invoice_item SET match_source = match_source, updated_at = now() WHERE invoice_id = $1', [id]);
      await client.query('UPDATE purchase_invoice_item SET product_id = product_id WHERE invoice_id = $1', [id]);
      expect(await auditOf(client, id)).toEqual([]);
    });
  });

  it('item desligado do produto fica como desligado (pela tabela; não há função que desligue)', async () => {
    const prod = await committed((client) => createProduct(client));
    const id = await committedInvoice();
    await asOwnerTx(async (client) => {
      await client.query(`UPDATE purchase_invoice_item SET product_id = $2, match_source = 'manual' WHERE invoice_id = $1`, [id, prod]);
      await client.query('UPDATE purchase_invoice_item SET product_id = NULL, match_source = NULL WHERE invoice_id = $1', [id]);
      const rows = await auditOf(client, id);
      expect(rows.map((r) => r.kind)).toEqual(['linked', 'unlinked']);
      expect(rows[1].detail.product).toBeNull();
      expect(rows[1].detail.product_id).toBeNull();
      expect(rows[1].detail.previous_product).toMatch(/ · /);
      expect(rows[1].user_id).toBeNull();
    });
  });

  it('a troca de produto vale também para os iguais esperando em outra nota, com a auditoria de cada nota', async () => {
    const emitterCnpj = cnpj();
    const supplierCode = `C-${randomBytes(3).toString('hex')}`;
    const first = await committedInvoice({ emitterCnpj, items: [item({ supplierCode })] });
    const second = await committedInvoice({ emitterCnpj, items: [item({ supplierCode })] });
    await asUser(a.admin.id, async (client) => {
      const prod = await createProduct(client);
      const [it] = await itemsOf(client, first);
      await link(client, it.id, prod);
      const [other] = await auditOf(client, second);
      expect(other).toMatchObject({ kind: 'linked', detail: { source: 'supplier_code', product_id: prod } });
    });
  });

  it('lote digitado entra; o do XML trocado sai; o do XML que entra com a nota não aparece', async () => {
    await asUser(a.admin.id, async (client) => {
      const code = gtin();
      const prod = await createProduct(client, { barcode: code });
      await client.query('SELECT app.set_batch_tracking($1, $2, true)', [prod, a.branch1.id]);
      const id = await importInvoice(client, invoice({ items: [item({ barcode: code, batches: [{ number: 'XML1', quantity: '2', expiresOn: '2028-01-01' }] })] }));
      expect(await auditOf(client, id)).toEqual([]);
      const [it] = await itemsOf(client, id);
      await setBatches(client, it.id, [{ number: 'M1', quantity: '2', expiresOn: '2029-02-01' }]);
      const rows = await auditOf(client, id);
      expect(rows.map((r) => [r.kind, r.detail.batch_number, r.detail.source]).sort()).toEqual([
        ['batch_added', 'M1', 'manual'],
        ['batch_removed', 'XML1', 'xml'],
      ]);
      const added = rows.find((r) => r.kind === 'batch_added');
      expect(added).toMatchObject({ user_id: a.admin.id, detail: { item_number: 1, description: 'ITEM DE TESTE', quantity: 2, expires_on: '2029-02-01' } });
      // Mesma transação, mesmo horário: a tela mostra na ordem inversa da gravação, sempre igual.
      const { rows: [{ order }] } = await client.query(
        'SELECT array_agg(kind ORDER BY occurred_at DESC, id DESC) AS order FROM purchase_invoice_audit WHERE invoice_id = $1', [id],
      );
      const { rows: [{ moments }] } = await client.query(
        'SELECT count(DISTINCT occurred_at)::int AS moments FROM purchase_invoice_audit WHERE invoice_id = $1', [id],
      );
      expect(moments).toBe(1);
      expect((await extra(client, id)).audit.map((row) => row.kind)).toEqual(order);
    });
  });

  it('lote apagado de novo não registra outra vez', async () => {
    const id = await committedInvoice();
    await asOwnerTx(async (client) => {
      const [it] = await itemsOf(client, id);
      const { rows: [batch] } = await client.query(
        `INSERT INTO purchase_invoice_item_batch (economic_group_id, branch_id, item_id, batch_number, quantity, expires_on, source)
         SELECT economic_group_id, branch_id, $1, 'L1', 1, '2030-01-01', 'xml' FROM purchase_invoice_item WHERE id = $1 RETURNING id`, [it.id],
      );
      expect(await auditOf(client, id)).toEqual([]);
      await client.query('UPDATE purchase_invoice_item_batch SET deleted_at = now() WHERE id = $1', [batch.id]);
      await client.query('UPDATE purchase_invoice_item_batch SET updated_at = now() WHERE id = $1', [batch.id]);
      expect((await auditOf(client, id)).map((r) => r.kind)).toEqual(['batch_removed']);
    });
  });

  it('custo liberado e nota descartada entram, com o motivo', async () => {
    await asUser(a.admin.id, async (client) => {
      const code = gtin();
      const prod = await createProduct(client, { barcode: code });
      await client.query('SELECT app.create_product_rule($1::jsonb)', [JSON.stringify({ typeCode: 'cost_tolerance', level: 'product', productLookup: code, value: 5 })]);
      const firstId = await importInvoice(client, invoice({ items: [item({ barcode: code, quantity: '1', productsValue: '10.00' })] }));
      await client.query('SELECT app.post_purchase_invoice($1)', [firstId]);
      const id = await importInvoice(client, invoice({ items: [item({ barcode: code, quantity: '1', productsValue: '20.00' })] }));
      const [it] = await itemsOf(client, id);
      await client.query('SELECT app.release_purchase_item_cost($1, $2)', [it.id, 'Reajuste do fornecedor']);
      await client.query('SELECT app.discard_purchase_invoice($1, $2)', [id, 'Nota em duplicidade']);
      const rows = await auditOf(client, id);
      expect(rows.map((r) => r.kind)).toEqual(['cost_released', 'discarded']);
      expect(rows[0]).toMatchObject({
        user_id: a.admin.id,
        detail: { item_number: 1, entry_cost: 20, average_cost: 10, tolerance: 5, reason: 'Reajuste do fornecedor' },
      });
      expect(rows[1]).toEqual({ kind: 'discarded', user_id: a.admin.id, detail: { reason: 'Nota em duplicidade' } });
    });
  });

  it('outra mudança da nota não registra descarte', async () => {
    const id = await committedInvoice();
    await asOwnerTx(async (client) => {
      await client.query('UPDATE purchase_invoice SET updated_at = now() WHERE id = $1', [id]);
      await client.query(`UPDATE purchase_invoice SET content_error = 'x' WHERE id = $1`, [id]);
      expect(await auditOf(client, id)).toEqual([]);
    });
  });

  it('a tela recebe lançada, estornada e as alterações, da mais nova para a mais antiga, com o nome de quem fez', async () => {
    await asUser(a.admin.id, async (client) => {
      const prod = await createProduct(client);
      const id = await importInvoice(client, invoice({ items: [item({ quantity: '1', productsValue: '5.00' })] }));
      const [it] = await itemsOf(client, id);
      await link(client, it.id, prod);
      await client.query('SELECT app.post_purchase_invoice($1)', [id]);
      await client.query('SELECT app.reverse_purchase_invoice($1, $2)', [id, 'Produto ligado errado']);
      const x = await extra(client, id);
      expect(x.audit.map((row) => row.kind).sort()).toEqual(['linked', 'posted', 'reversed']);
      for (const row of x.audit) expect(row.user_name).toBe(a.admin.name);
      const times = x.audit.map((row) => new Date(row.occurred_at).getTime());
      expect([...times].sort((p, q) => q - p)).toEqual(times);
      expect(x.audit.find((row) => row.kind === 'reversed').detail).toEqual({ reason: 'Produto ligado errado' });
      expect(x.audit.find((row) => row.kind === 'posted').detail).toEqual({});
      expect(x.audit.find((row) => row.kind === 'linked').detail.product_id).toBe(prod);
    });
  });

  it('quem só vê compras vê a auditoria; outro grupo não', async () => {
    const id = await committedInvoice();
    await asUser(viewer.id, async (client) => {
      const x = await extra(client, id);
      expect(x.installments).toEqual([]);
      expect(x.audit).toEqual([]);
      const { rows } = await client.query('SELECT count(*)::int AS n FROM v_purchase_invoice WHERE id = $1', [id]);
      expect(rows[0].n).toBe(1);
    });
    await ownerPool.query(
      `INSERT INTO purchase_invoice_audit (economic_group_id, branch_id, invoice_id, kind, detail) VALUES ($1, $2, $3, 'discarded', '{}')`,
      [a.group.id, a.branch1.id, id],
    );
    await ownerPool.query(
      'INSERT INTO purchase_invoice_installment (economic_group_id, branch_id, invoice_id, line, amount) VALUES ($1, $2, $3, 1, 1)',
      [a.group.id, a.branch1.id, id],
    );
    await asUser(viewer.id, async (c) => {
      expect((await c.query('SELECT count(*)::int AS n FROM v_purchase_invoice_audit WHERE invoice_id = $1', [id])).rows[0].n).toBe(1);
      expect((await c.query('SELECT count(*)::int AS n FROM v_purchase_invoice_installment WHERE invoice_id = $1', [id])).rows[0].n).toBe(1);
      expect((await extra(c, id)).audit).toHaveLength(1);
    });
    await asUser(b.admin.id, async (c) => {
      expect((await c.query('SELECT count(*)::int AS n FROM v_purchase_invoice_audit WHERE invoice_id = $1', [id])).rows[0].n).toBe(0);
      expect((await c.query('SELECT count(*)::int AS n FROM v_purchase_invoice_installment WHERE invoice_id = $1', [id])).rows[0].n).toBe(0);
      expect(await extra(c, id)).toBeNull();
    });
  });

  it('a outra filial do grupo sem permissão de compras não vê', async () => {
    const id = await committedInvoice();
    const { rows: [other] } = await ownerPool.query(
      `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Só filial 2') RETURNING *`, [a.group.id],
    );
    await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [other.id, a.branch2.id]);
    await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [other.id, a.managerRole.id, a.branch2.id]);
    await asUser(other.id, async (c) => {
      expect(await extra(c, id)).toBeNull();
      await expectCode(c, () => store(c, id, CONTENT, []), 'FA002');
    });
  });
});
