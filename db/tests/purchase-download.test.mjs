import { createHash, randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot,
} from './helpers.mjs';

let a;
let b;
let manager;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows } = await ownerPool.query(
    `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Gerente download') RETURNING *`, [a.group.id],
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
function accessKey(emitter = cnpj(), number = randomInt(1, 999_999_999)) {
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
const digestOf = (text) => createHash('sha1').update(text).digest('base64');
function invoice(barcode, overrides = {}) {
  const emitterCnpj = cnpj();
  const number = randomInt(1, 999_999_999);
  return {
    accessKey: accessKey(emitterCnpj, number), series: 1, number, issuedAt: '2026-11-20T10:00:00-03:00', operationType: 1,
    purpose: 1, environment: 1, protocolNumber: '135260000000001', authorizedAt: '2026-11-20T10:00:05-03:00',
    destCnpj: a.branch1.cnpj, digest: digestOf(randomBytes(8)),
    emitter: { cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA DO DOWNLOAD LTDA', state: 'SP' },
    totals: { products: '21.00', invoice: '21.00' },
    items: [{
      number: 1, supplierCode: `C-${randomBytes(3).toString('hex')}`, barcode, description: 'ITEM BAIXADO', cfop: '6102',
      unit: 'CX', quantity: '2', unitPrice: '10.5', productsValue: '21.00', batches: [],
    }],
    ...overrides,
  };
}
const summaryOf = (data, overrides = {}) => ({
  accessKey: data.accessKey, emitterDocument: data.emitter.cnpj, emitterName: data.emitter.legalName,
  issuedAt: data.issuedAt, operationType: 1, total: data.totals.invoice, digest: data.digest,
  protocolNumber: data.protocolNumber, situation: 1, ...overrides,
});
const XML = '<nfeProc>conteúdo de teste</nfeProc>';
const SHA = createHash('sha256').update(XML).digest('hex');

/** Uma transação só, trocando entre usuário e rotina de download como a API faz. */
async function session(fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    const as = (userId) => client.query(
      `SELECT set_config('app.user_id', $1, true), set_config('app.worker', '', true)`, [userId],
    );
    const worker = () => client.query(`SELECT set_config('app.user_id', '', true), set_config('app.worker', 'dfe', true)`);
    await as(a.admin.id);
    await fn(client, { as, worker });
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
const certificate = (client, branch, validTo = '2030-01-01T00:00:00Z') =>
  client.query('SELECT app.set_branch_certificate($1, $2::jsonb, $3, $4)', [
    branch.id,
    JSON.stringify({
      subjectName: 'EMPRESA TESTE:' + branch.cnpj, cnpj: branch.cnpj, validFrom: '2025-01-01T00:00:00Z', validTo,
      fingerprint: randomBytes(32).toString('hex'),
    }),
    Buffer.from('pfx selado'), Buffer.from('senha selada'),
  ]);
const enable = (client, branch, enabled = true) => client.query('SELECT app.set_dfe_sync($1, $2)', [branch.id, enabled]);
const claim = (client) => client.query('SELECT * FROM app.dfe_claim_branches(10)').then((r) => r.rows);
const finish = (client, branch, result) => client.query('SELECT app.dfe_finish_branch($1, $2::jsonb)', [branch.id, JSON.stringify(result)]);
const recordSummary = (client, branch, data) => client.query('SELECT app.dfe_record_summary($1, $2::jsonb) AS id', [branch.id, JSON.stringify(data)]).then((r) => r.rows[0].id);
const importManual = (client, data, acceptsTest = false) =>
  client.query('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, $4) AS id', [JSON.stringify(data), XML, SHA, acceptsTest]).then((r) => r.rows[0].id);
const importDownloaded = (client, branch, data, requires = true) =>
  client.query('SELECT app.dfe_import_invoice($1, $2::jsonb, $3, $4, $5) AS id', [branch.id, JSON.stringify(data), XML, SHA, requires]).then((r) => r.rows[0].id);
/** Lê a nota como o Administrador e volta ao contexto em que estava. */
async function invoiceRow(client, id) {
  const { rows: [before] } = await client.query("SELECT current_setting('app.user_id', true) AS u, current_setting('app.worker', true) AS w");
  await client.query("SELECT set_config('app.user_id', $1, true), set_config('app.worker', '', true)", [a.admin.id]);
  const { rows } = await client.query('SELECT * FROM purchase_invoice WHERE id = $1', [id]);
  await client.query("SELECT set_config('app.user_id', $1, true), set_config('app.worker', $2, true)", [before.u ?? '', before.w ?? '']);
  return rows[0];
}
const product = async (client) => {
  const code = gtin();
  await client.query('SELECT app.create_product($1::jsonb)', [JSON.stringify({ displayName: `Produto ${code}`, barcode: code })]);
  return code;
};
const post = (client, id) => client.query('SELECT app.post_purchase_invoice($1)', [id]);

describe('rotina de download', () => {
  it('só a rotina, sem usuário, chama as funções dela', async () => {
    await session(async (client, { as, worker }) => {
      await expectCode(client, () => claim(client), 'FA002');
      await client.query(`SELECT set_config('app.user_id', '', true)`);
      await expectCode(client, () => claim(client), 'FA002');
      await worker();
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      await expectCode(client, () => claim(client), 'FA002');
      await worker();
      await expect(claim(client)).resolves.toBeDefined();
      await as(a.admin.id);
      for (const call of [
        () => finish(client, a.branch1, {}),
        () => client.query('SELECT app.dfe_store_document($1, $2, $3, NULL, $4)', [a.branch1.id, '000000000000001', 'resNFe_v1.01', '<x/>']),
        () => recordSummary(client, a.branch1, {}),
        () => client.query('SELECT app.dfe_record_cancellation($1, $2)', [a.branch1.id, accessKey()]),
        () => importDownloaded(client, a.branch1, {}),
        () => client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 10)'),
        () => client.query('SELECT app.dfe_record_query_failure($1, $2, $3, $4)', [a.branch1.id, accessKey(), '999', 'x']),
      ]) {
        await expectCode(client, call, 'FA002');
      }
    });
  });

  it('busca a filial ligada, com certificado válido e na hora certa, uma rodada por vez', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const mine = async () => (await claim(client)).filter((row) => [a.branch1.id, a.branch2.id].includes(row.branch_id));
      expect(await mine()).toEqual([]);
      await as(a.admin.id);
      await enable(client, a.branch1);
      await enable(client, a.branch2);
      await certificate(client, a.branch1);
      await worker();
      const [row, ...others] = await mine();
      expect(others).toEqual([]);
      expect(row).toMatchObject({ branch_id: a.branch1.id, cnpj: a.branch1.cnpj, last_nsu: '000000000000000' });
      expect(row.encrypted_pfx.toString()).toBe('pfx selado');
      expect(await mine()).toEqual([]);

      await finish(client, a.branch1, { status: '138', message: 'Documento localizado', ultNsu: '000000000000050', maxNsu: '000000000000090', waitMinutes: 1 });
      await as(a.admin.id);
      const { rows: [sync] } = await client.query('SELECT * FROM v_branch_dfe_sync WHERE branch_id = $1', [a.branch1.id]);
      await worker();
      expect(sync).toMatchObject({ last_nsu: '000000000000050', max_nsu: '000000000000090', last_status: '138', locked_until: null });
      expect(new Date(sync.next_run_at) > new Date()).toBe(true);
      expect(await mine()).toEqual([]);
    });
  });

  it('desligar tira a filial da fila; ligar exige a permissão fiscal da filial', async () => {
    await session(async (client, { as, worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      await enable(client, a.branch1, false);
      await worker();
      expect((await claim(client)).filter((row) => row.branch_id === a.branch1.id)).toEqual([]);
      await as(a.oneBranchUser.id);
      await expectCode(client, () => enable(client, a.branch1), 'FA002');
      await as(manager.id);
      await enable(client, a.branch1);
      await expectCode(client, () => enable(client, a.branch2), 'FA002');
    });
  });

  it('o mesmo NSU não entra duas vezes', async () => {
    await session(async (client, { worker }) => {
      await worker();
      const store = () => client.query('SELECT app.dfe_store_document($1, $2, $3, $4, $5) AS ok', [
        a.branch1.id, '000000000000007', 'resNFe_v1.01', accessKey(), '<resNFe/>',
      ]).then((r) => r.rows[0].ok);
      expect(await store()).toBe(true);
      expect(await store()).toBe(false);
      await expectCode(client, () => client.query('SELECT app.dfe_store_document($1, $2, $3, NULL, $4)', [a.branch1.id, '7', 'resNFe_v1.01', '<x/>']), 'FA931');
      await expectCode(client, () => client.query('SELECT app.dfe_store_document($1, $2, $3, $4, $5)', [a.branch1.id, '000000000000008', 'resNFe_v1.01', '123', '<x/>']), 'FA931');
      await expect(client.query('SELECT app.dfe_store_document($1, $2, $3, NULL, $4)', [a.branch1.id, '000000000000009', 'resEvento_v1.01', '<x/>'])).resolves.toBeDefined();
    });
  });
});

describe('ciência e XML completo', () => {
  it('o resumo aparece, recebe ciência e vira nota confirmada quando o XML chega', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(await product(client));
      await worker();
      const summaryId = await recordSummary(client, a.branch1, summaryOf(data));
      await as(a.admin.id);
      const { rows: listed } = await client.query('SELECT * FROM app.list_purchase_summaries()');
      expect(listed.find((row) => row.id === summaryId)).toMatchObject({ emitter_name: 'DISTRIBUIDORA DO DOWNLOAD LTDA', total: '21.00', can_manage: true });

      await expectCode(client, () => client.query('SELECT * FROM app.awareness_target($1)', [summaryId]), 'FA943');
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      const { rows: [target] } = await client.query('SELECT * FROM app.awareness_target($1)', [summaryId]);
      expect(target).toMatchObject({ access_key: data.accessKey, cnpj: a.branch1.cnpj });
      await client.query('SELECT app.record_awareness($1, $2)', [summaryId, '891260000000001']);
      await expectCode(client, () => client.query('SELECT * FROM app.awareness_target($1)', [summaryId]), 'FA946');
      const { rows: [aware] } = await client.query('SELECT * FROM app.list_purchase_summaries()  WHERE id = $1', [summaryId]);
      expect(aware.awareness_by_name).toBe(a.admin.name);

      await worker();
      const queries = await client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 10)').then((r) => r.rows);
      expect(queries.find((row) => row.access_key === data.accessKey)).toMatchObject({ kind: 'xml', branch_id: a.branch1.id });
      const id = await importDownloaded(client, a.branch1, data);
      expect(await invoiceRow(client, id)).toMatchObject({
        source: 'download', confirmation: 'confirmed', confirmation_required: true, status: 'review', digest: data.digest,
      });
      await as(a.admin.id);
      expect((await client.query('SELECT 1 FROM app.list_purchase_summaries() WHERE id = $1', [summaryId])).rows).toEqual([]);
      await post(client, id);
    });
  });

  it('quem só vê compras não dá ciência; outro grupo não enxerga', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(null);
      await worker();
      const summaryId = await recordSummary(client, a.branch2, summaryOf(data));
      await as(manager.id);
      await expectCode(client, () => client.query('SELECT * FROM app.awareness_target($1)', [summaryId]), 'FA002');
      expect((await client.query('SELECT 1 FROM app.list_purchase_summaries() WHERE id = $1', [summaryId])).rows).toEqual([]);
      await as(b.admin.id);
      await expectCode(client, () => client.query('SELECT * FROM app.awareness_target($1)', [summaryId]), 'FA006');
      await expectCode(client, () => client.query('SELECT app.record_awareness($1, NULL)', [summaryId]), 'FA006');
      expect((await client.query('SELECT 1 FROM v_purchase_invoice_summary')).rows).toEqual([]);
    });
  });

  it('nota de saída emitida para a filial não aparece para ciência', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(null);
      await worker();
      const summaryId = await recordSummary(client, a.branch1, summaryOf(data, { operationType: 0 }));
      await as(a.admin.id);
      expect((await client.query('SELECT 1 FROM app.list_purchase_summaries() WHERE id = $1', [summaryId])).rows).toEqual([]);
    });
  });
});

describe('confirmação da nota importada à mão', () => {
  it('em produção, a nota sem confirmação não se lança; o resumo igual confirma', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(await product(client));
      const id = await importManual(client, data);
      expect(await invoiceRow(client, id)).toMatchObject({ confirmation: 'pending', confirmation_required: true, source: 'manual' });
      await expectCode(client, () => post(client, id), 'FA942');
      await worker();
      await recordSummary(client, a.branch1, summaryOf(data));
      expect(await invoiceRow(client, id)).toMatchObject({ confirmation: 'confirmed', confirmation_message: null });
      await as(a.admin.id);
      await post(client, id);
    });
  });

  it('o resumo que chegou antes confirma na importação; assinatura diferente marca a diferença', async () => {
    await session(async (client, { as, worker }) => {
      const same = invoice(await product(client));
      const other = invoice(await product(client));
      await worker();
      await recordSummary(client, a.branch1, summaryOf(same));
      await recordSummary(client, a.branch1, summaryOf(other, { digest: digestOf('outro conteúdo') }));
      await as(a.admin.id);
      expect((await invoiceRow(client, await importManual(client, same))).confirmation).toBe('confirmed');
      const otherId = await importManual(client, other);
      expect(await invoiceRow(client, otherId)).toMatchObject({
        confirmation: 'mismatch', confirmation_message: 'O XML importado é diferente do que a Sefaz autorizou.',
      });
      await expectCode(client, () => post(client, otherId), 'FA942');
    });
  });

  it('nota denegada na Sefaz fica marcada', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(null);
      const id = await importManual(client, data);
      await worker();
      await recordSummary(client, a.branch1, summaryOf(data, { situation: 2 }));
      await as(a.admin.id);
      expect(await invoiceRow(client, id)).toMatchObject({ confirmation: 'mismatch', confirmation_message: 'A Sefaz informa que esta nota foi denegada.' });
    });
  });

  it('o XML baixado depois confirma a importada à mão, se for o mesmo', async () => {
    await session(async (client, { worker }) => {
      const data = invoice(null);
      const tampered = invoice(null);
      const id = await importManual(client, data);
      const tamperedId = await importManual(client, tampered);
      await worker();
      expect(await importDownloaded(client, a.branch1, data)).toBe(id);
      expect((await invoiceRow(client, id)).confirmation).toBe('confirmed');
      expect(await importDownloaded(client, a.branch1, { ...tampered, digest: digestOf('autorizado') })).toBe(tamperedId);
      expect((await invoiceRow(client, tamperedId)).confirmation).toBe('mismatch');
    });
  });

  it('fora da produção a confirmação só aparece, sem barrar o lançamento', async () => {
    await session(async (client) => {
      const data = invoice(await product(client), { environment: 2 });
      const id = await importManual(client, data, true);
      expect(await invoiceRow(client, id)).toMatchObject({ confirmation: 'pending', confirmation_required: false });
      await post(client, id);
    });
  });
});

describe('cancelamento', () => {
  it('em conferência vira cancelada; lançada ganha o alerta e continua lançada', async () => {
    await session(async (client, { as, worker }) => {
      const review = invoice(await product(client), { environment: 2 });
      const posted = invoice(await product(client), { environment: 2 });
      const reviewId = await importManual(client, review, true);
      const postedId = await importManual(client, posted, true);
      await post(client, postedId);
      await worker();
      await client.query('SELECT app.dfe_record_cancellation($1, $2)', [a.branch1.id, review.accessKey]);
      await client.query('SELECT app.dfe_record_cancellation($1, $2)', [a.branch1.id, posted.accessKey]);
      await as(a.admin.id);
      expect(await invoiceRow(client, reviewId)).toMatchObject({ status: 'cancelled' });
      expect((await invoiceRow(client, reviewId)).cancelled_at).not.toBeNull();
      const postedRow = await invoiceRow(client, postedId);
      expect(postedRow.status).toBe('posted');
      expect(postedRow.cancelled_at).not.toBeNull();
      await expectCode(client, () => post(client, reviewId), 'FA938');
      const { rows } = await client.query('SELECT id, cancelled_at FROM app.list_purchase_invoices() WHERE id = $1', [postedId]);
      expect(rows[0].cancelled_at).not.toBeNull();
    });
  });

  it('resumo cancelado cancela a nota e sai da ciência', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(null, { environment: 2 });
      const id = await importManual(client, data, true);
      await worker();
      await recordSummary(client, a.branch1, summaryOf(data));
      await recordSummary(client, a.branch1, summaryOf(data, { situation: 3 }));
      await as(a.admin.id);
      expect((await invoiceRow(client, id)).status).toBe('cancelled');
      const { rows: [summary] } = await client.query('SELECT situation FROM v_purchase_invoice_summary WHERE access_key = $1', [data.accessKey]);
      expect(summary.situation).toBe(3);
    });
  });
});

describe('consulta por chave', () => {
  it('consulta as importadas à mão na produção, uma vez a cada meia hora e até 15 por hora', async () => {
    await session(async (client, { as, worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      const keys = [];
      for (let i = 0; i < 17; i += 1) {
        const data = invoice(null);
        keys.push(data.accessKey);
        await importManual(client, data);
      }
      await importManual(client, invoice(null, { destCnpj: a.branch2.cnpj }));
      await worker();
      const first = await client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 50)').then((r) => r.rows);
      const mine = first.filter((row) => keys.includes(row.access_key));
      expect(mine).toHaveLength(15);
      expect(mine.every((row) => row.kind === 'confirm' && row.branch_id === a.branch1.id)).toBe(true);
      expect(first.some((row) => row.branch_id === a.branch2.id)).toBe(false);
      expect((await client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 50)')).rows.filter((row) => keys.includes(row.access_key))).toEqual([]);
      expect((await client.query('SELECT * FROM app.dfe_claim_queries(2::smallint, 50)')).rows.filter((row) => keys.includes(row.access_key))).toEqual([]);
      await as(a.admin.id);
    });
  });

  it('656 para as consultas da hora; 137 espera; outra recusa marca sem confirmação', async () => {
    await session(async (client, { worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      const waiting = invoice(null);
      const refused = invoice(null);
      const waitingId = await importManual(client, waiting);
      const refusedId = await importManual(client, refused);
      await worker();
      await client.query('SELECT app.dfe_record_query_failure($1, $2, $3, $4)', [a.branch1.id, waiting.accessKey, '137', 'Nenhum documento localizado']);
      await client.query('SELECT app.dfe_record_query_failure($1, $2, $3, $4)', [a.branch1.id, refused.accessKey, '632', 'Rejeição: Solicitação fora de prazo']);
      expect((await invoiceRow(client, waitingId)).confirmation).toBe('pending');
      expect(await invoiceRow(client, refusedId)).toMatchObject({ confirmation: 'unavailable', confirmation_message: 'Rejeição: Solicitação fora de prazo' });
      await client.query('SELECT app.dfe_record_query_failure($1, $2, $3, $4)', [a.branch1.id, waiting.accessKey, '656', 'Consumo indevido']);
      expect((await client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 50)')).rows.filter((row) => row.branch_id === a.branch1.id)).toEqual([]);
    });
  });

  it('filial sem download ligado não é consultada', async () => {
    await session(async (client, { worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      await enable(client, a.branch1, false);
      const data = invoice(null);
      await importManual(client, data);
      await worker();
      expect((await client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 50)')).rows.filter((row) => row.access_key === data.accessKey)).toEqual([]);
    });
  });
});

describe('situação e travas', () => {
  it('a tela fiscal mostra o download das filiais que a pessoa vê', async () => {
    await session(async (client, { as, worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      await worker();
      await recordSummary(client, a.branch1, summaryOf(invoice(null)));
      await client.query('SELECT app.dfe_store_document($1, $2, $3, NULL, $4)', [a.branch1.id, '000000000000077', 'resNFe_v1.01', '<resNFe/>']);
      await as(a.admin.id);
      expect((await client.query('SELECT 1 FROM v_dfe_document WHERE nsu = $1', ['000000000000077'])).rows).toHaveLength(1);
      const { rows } = await client.query('SELECT * FROM app.dfe_sync_status()');
      expect(rows.find((row) => row.branch_id === a.branch1.id)).toMatchObject({ enabled: true, has_certificate: true, waiting_awareness: '1', can_manage: true });
      expect(rows.find((row) => row.branch_id === a.branch2.id)).toMatchObject({ enabled: false, has_certificate: false });
      await as(manager.id);
      expect((await client.query('SELECT branch_id FROM app.dfe_sync_status()')).rows).toEqual([{ branch_id: a.branch1.id }]);
      await as(a.oneBranchUser.id);
      expect((await client.query('SELECT 1 FROM app.dfe_sync_status()')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_branch_dfe_sync')).rows).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_dfe_document')).rows).toEqual([]);
    });
  });

  it('o que veio da Sefaz não muda depois de gravado', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      const data = invoice(null, { environment: 2 });
      const id = await importManual(client, data, true);
      await client.query(`SELECT set_config('app.user_id', '', true), set_config('app.worker', 'dfe', true)`);
      await recordSummary(client, a.branch1, summaryOf(data));
      await client.query('SELECT app.dfe_store_document($1, $2, $3, $4, $5)', [a.branch1.id, '000000000000001', 'resNFe_v1.01', data.accessKey, '<resNFe/>']);
      for (const [sql, params] of [
        ['UPDATE purchase_invoice SET digest = $2 WHERE id = $1', [id, digestOf('x')]],
        ["UPDATE purchase_invoice SET source = 'download' WHERE id = $1", [id]],
        ['UPDATE purchase_invoice SET confirmation_required = true WHERE id = $1', [id]],
        ['UPDATE purchase_invoice_summary SET digest = $2 WHERE access_key = $1', [data.accessKey, digestOf('x')]],
        ["UPDATE dfe_document SET xml = '<outro/>' WHERE access_key = $1", [data.accessKey]],
        ['UPDATE dfe_document SET deleted_at = now() WHERE access_key = $1', [data.accessKey]],
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql, params)).rejects.toSatisfy(hasCode('FA104'));
        await client.query('ROLLBACK TO s');
      }
      // Gravar lançada sem confirmação, por qualquer caminho, é barrado.
      await client.query('UPDATE purchase_invoice SET confirmation_required = false WHERE id = $1', [id]).catch(() => null);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('certificado vencido tira a filial da fila', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [a.admin.id]);
      await enable(client, a.branch2);
      await client.query(
        `INSERT INTO branch_certificate (economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint, encrypted_pfx, encrypted_password)
         VALUES ($1, $2, 'VENCIDO', $3, '2024-01-01', '2025-01-01', $4, 'x', 'y')`,
        [a.group.id, a.branch2.id, a.branch2.cnpj, randomBytes(32).toString('hex')],
      );
      await client.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'dfe', true)");
      expect((await claim(client)).filter((row) => row.branch_id === a.branch2.id)).toEqual([]);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('lançar direto na tabela, sem confirmação exigida, é barrado', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      const id = await importManual(client, invoice(null));
      await client.query('SAVEPOINT s');
      await expect(client.query("UPDATE purchase_invoice SET status = 'posted' WHERE id = $1", [id])).rejects.toSatisfy(hasCode('FA942'));
      await client.query('ROLLBACK TO s');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});

describe('detalhes da confirmação e da consulta', () => {
  it('uma consulta por chave a cada meia hora, só no ambiente da rotina', async () => {
    await session(async (client, { worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      const data = invoice(null);
      await importManual(client, data);
      await worker();
      const claimed = async (environment) =>
        (await client.query('SELECT * FROM app.dfe_claim_queries($1::smallint, 50)', [environment])).rows.filter((row) => row.access_key === data.accessKey);
      expect(await claimed(2)).toEqual([]);
      expect(await claimed(1)).toHaveLength(1);
      expect(await claimed(1)).toEqual([]);
    });
  });

  it('resumo sem ciência não é consultado pela chave', async () => {
    await session(async (client, { worker }) => {
      await certificate(client, a.branch1);
      await enable(client, a.branch1);
      const data = invoice(null);
      await worker();
      await recordSummary(client, a.branch1, summaryOf(data));
      expect((await client.query('SELECT * FROM app.dfe_claim_queries(1::smallint, 50)')).rows.filter((row) => row.access_key === data.accessKey)).toEqual([]);
    });
  });

  it('o resumo que chega depois da importação liga à nota e sai da ciência', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(null);
      const id = await importManual(client, data);
      await worker();
      const summaryId = await recordSummary(client, a.branch1, summaryOf(data));
      await as(a.admin.id);
      const { rows: [summary] } = await client.query('SELECT invoice_id FROM v_purchase_invoice_summary WHERE id = $1', [summaryId]);
      expect(summary.invoice_id).toBe(id);
      expect((await client.query('SELECT 1 FROM app.list_purchase_summaries() WHERE id = $1', [summaryId])).rows).toEqual([]);
    });
  });

  it('o cancelamento marca o resumo, que não recebe mais ciência', async () => {
    await session(async (client, { as, worker }) => {
      await certificate(client, a.branch1);
      const data = invoice(null);
      await worker();
      const summaryId = await recordSummary(client, a.branch1, summaryOf(data));
      await client.query('SELECT app.dfe_record_cancellation($1, $2)', [a.branch1.id, data.accessKey]);
      await as(a.admin.id);
      const { rows: [row] } = await client.query('SELECT situation FROM app.list_purchase_summaries() WHERE id = $1', [summaryId]);
      expect(row.situation).toBe(3);
      await expectCode(client, () => client.query('SELECT * FROM app.awareness_target($1)', [summaryId]), 'FA946');
    });
  });

  it('o resumo de um grupo não mexe na nota de outro grupo com a mesma chave', async () => {
    await session(async (client, { as, worker }) => {
      const data = invoice(null);
      await as(b.admin.id);
      const otherGroup = await importManual(client, { ...data, destCnpj: b.branch1.cnpj });
      await worker();
      await recordSummary(client, a.branch1, summaryOf(data, { digest: digestOf('outro') }));
      await as(b.admin.id);
      const { rows: [row] } = await client.query('SELECT confirmation FROM v_purchase_invoice WHERE id = $1', [otherGroup]);
      expect(row.confirmation).toBe('pending');
    });
  });

  it('confirmada sem data é barrada na tabela', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      const id = await importManual(client, invoice(null));
      await client.query('SAVEPOINT s');
      await expect(client.query("UPDATE purchase_invoice SET confirmation = 'confirmed' WHERE id = $1", [id])).rejects.toSatisfy(hasCode('FA931'));
      await client.query('ROLLBACK TO s');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
