import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

let a;
let b;
let manager;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  const { rows } = await ownerPool.query(
    `INSERT INTO user_account (economic_group_id, name) VALUES ($1, 'Gerente serviços') RETURNING *`, [a.group.id],
  );
  manager = rows[0];
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [manager.id, a.branch1.id]);
  await ownerPool.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [manager.id, a.managerRole.id, a.branch1.id]);
});
afterAll(closePools);

const key = () => Array.from({ length: 50 }, () => randomInt(10)).join('');
const nsu = (value) => String(value).padStart(15, '0');
let nextNsu = randomInt(1, 1_000_000);
const PROVIDER = '11444777000161';

function note(overrides = {}) {
  return {
    accessKey: key(), number: String(randomInt(1, 99999)), environment: 2, issuedAt: '2026-11-10T09:00:00-03:00',
    competence: '2026-11-01', processedAt: '2026-11-10T09:00:05-03:00', providerDocument: PROVIDER,
    providerName: 'MANUTENCAO DE AR LTDA', providerLocation: 'São Paulo', takerDocument: a.branch1.cnpj,
    serviceCode: '140101', municipalCode: '1401', nbsCode: '120011100', description: 'Manutenção do ar-condicionado da loja',
    incidenceLocation: 'São Paulo', serviceValue: '1000.00', unconditionalDiscount: '0', deductions: '0', issBase: '1000.00',
    issRate: '5.0000', issValue: '50.00', issWithholding: 2, irrf: '15.00', csll: '10.00', socialSecurity: '0', pis: '6.50',
    cofins: '30.00', pisCofinsWithholding: 3, totalWithheld: '111.50', netValue: '888.50', replacesKey: null,
    ...overrides,
  };
}

async function session(fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    const as = (userId) => client.query(`SELECT set_config('app.user_id', $1, true), set_config('app.worker', '', true)`, [userId]);
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
const store = (client, branch, type, accessKey, xml = '<NFSe/>') =>
  client.query('SELECT app.dfe_store_nfse_document($1, $2, $3, $4, $5) AS id', [branch.id, nsu((nextNsu += 1)), type, accessKey, xml])
    .then((r) => r.rows[0].id);
async function record(client, branch, data) {
  const documentId = await store(client, branch, 'NFSE', data.accessKey);
  return client.query('SELECT app.nfse_record_invoice($1, $2, $3::jsonb) AS id', [branch.id, documentId, JSON.stringify(data)]).then((r) => r.rows[0].id);
}
const event = (client, branch, accessKey, kind, substitute = null) =>
  client.query('SELECT app.nfse_record_event($1, $2, $3, $4)', [branch.id, accessKey, kind, substitute]);
const list = (client, args = [null, null, null, null]) =>
  client.query('SELECT * FROM app.list_service_invoices($1, $2, $3, $4)', args).then((r) => r.rows);
const certificate = (client, branch) =>
  client.query('SELECT app.set_branch_certificate($1, $2::jsonb, $3, $4)', [
    branch.id,
    JSON.stringify({ subjectName: `EMPRESA:${branch.cnpj}`, cnpj: branch.cnpj, validFrom: '2025-01-01T00:00:00Z', validTo: '2030-01-01T00:00:00Z', fingerprint: randomBytes(32).toString('hex') }),
    Buffer.from('pfx'), Buffer.from('senha'),
  ]);

describe('rotina da NFS-e', () => {
  it('só a rotina grava; busca a filial ligada na hora certa, com NSU próprio', async () => {
    await session(async (client, { as, worker }) => {
      for (const call of [
        () => client.query('SELECT * FROM app.dfe_claim_nfse_branches(10)'),
        () => client.query('SELECT app.dfe_finish_nfse_branch($1, $2::jsonb)', [a.branch1.id, '{}']),
        () => store(client, a.branch1, 'NFSE', key()),
        () => client.query('SELECT app.nfse_record_invoice($1, NULL, $2::jsonb)', [a.branch1.id, '{}']),
        () => event(client, a.branch1, key(), 'cancel'),
      ]) {
        await expectCode(client, call, 'FA002');
      }
      await certificate(client, a.branch1);
      await client.query('SELECT app.set_dfe_sync($1, true)', [a.branch1.id]);
      await worker();
      const claim = async () => (await client.query('SELECT * FROM app.dfe_claim_nfse_branches(10)')).rows.filter((row) => row.branch_id === a.branch1.id);
      const [row] = await claim();
      expect(row).toMatchObject({ cnpj: a.branch1.cnpj, last_nsu: '000000000000000' });
      expect(await claim()).toEqual([]);
      // A reserva da NFS-e não segura a NF-e, e vice-versa.
      expect((await client.query('SELECT * FROM app.dfe_claim_branches(10)')).rows.filter((r) => r.branch_id === a.branch1.id)).toHaveLength(1);

      await client.query('SELECT app.dfe_finish_nfse_branch($1, $2::jsonb)', [a.branch1.id, JSON.stringify({ status: 'NENHUM_DOCUMENTO_LOCALIZADO', lastNsu: nsu(42), waitMinutes: 60 })]);
      await as(a.admin.id);
      const { rows: [sync] } = await client.query('SELECT * FROM v_branch_dfe_sync WHERE branch_id = $1', [a.branch1.id]);
      expect(sync).toMatchObject({ nfse_last_nsu: nsu(42), nfse_last_status: 'NENHUM_DOCUMENTO_LOCALIZADO', nfse_locked_until: null, last_nsu: '000000000000000' });
      expect(new Date(sync.nfse_next_run_at) > new Date()).toBe(true);
      const { rows: status } = await client.query('SELECT * FROM app.dfe_sync_status() WHERE branch_id = $1', [a.branch1.id]);
      expect(status[0]).toMatchObject({ nfse_last_status: 'NENHUM_DOCUMENTO_LOCALIZADO' });
      await worker();
      expect(await claim()).toEqual([]);
    });
  });

  it('desligar tira a NFS-e da fila; ligar de novo põe na hora', async () => {
    await session(async (client, { as, worker }) => {
      await certificate(client, a.branch1);
      await client.query('SELECT app.set_dfe_sync($1, true)', [a.branch1.id]);
      await worker();
      await client.query('SELECT app.dfe_finish_nfse_branch($1, $2::jsonb)', [a.branch1.id, JSON.stringify({ waitMinutes: 60 })]);
      await as(a.admin.id);
      await client.query('SELECT app.set_dfe_sync($1, false)', [a.branch1.id]);
      await worker();
      expect((await client.query('SELECT * FROM app.dfe_claim_nfse_branches(10)')).rows.filter((r) => r.branch_id === a.branch1.id)).toEqual([]);
      await as(a.admin.id);
      await client.query('SELECT app.set_dfe_sync($1, true)', [a.branch1.id]);
      await worker();
      expect((await client.query('SELECT * FROM app.dfe_claim_nfse_branches(10)')).rows.filter((r) => r.branch_id === a.branch1.id)).toHaveLength(1);
    });
  });

  it('filial desligada não busca, mesmo na hora certa', async () => {
    await session(async (client, { worker }) => {
      await certificate(client, a.branch1);
      await client.query('SELECT app.set_dfe_sync($1, true)', [a.branch1.id]);
      await client.query('SELECT app.set_dfe_sync($1, false)', [a.branch1.id]);
      await worker();
      expect((await client.query('SELECT * FROM app.dfe_claim_nfse_branches(10)')).rows.filter((r) => r.branch_id === a.branch1.id)).toEqual([]);
    });
  });

  it('o mesmo NSU devolve o mesmo documento, separado do NSU da NF-e', async () => {
    await session(async (client, { worker }) => {
      await worker();
      const value = nsu((nextNsu += 1));
      const put = (type, k) => client.query('SELECT app.dfe_store_nfse_document($1, $2, $3, $4, $5) AS id', [a.branch1.id, value, type, k, '<NFSe/>']).then((r) => r.rows[0].id);
      const first = await put('NFSE', key());
      expect(await put('NFSE', key())).toBe(first);
      expect((await client.query('SELECT app.dfe_store_document($1, $2, $3, NULL, $4) AS ok', [a.branch1.id, value, 'resNFe_v1.01', '<resNFe/>'])).rows[0].ok).toBe(true);
      await expectCode(client, () => put('NFE', key()), 'FA931');
      await expectCode(client, () => client.query('SELECT app.dfe_store_nfse_document($1, $2, $3, $4, $5)', [a.branch1.id, nsu((nextNsu += 1)), 'NFSE', '123', '<x/>']), 'FA931');
    });
  });
});

describe('nota de serviço', () => {
  it('a recebida aparece com valores, retenções e o XML', async () => {
    await session(async (client, { as, worker }) => {
      const data = note();
      await worker();
      const id = await record(client, a.branch1, data);
      expect(await record(client, a.branch1, data)).toBe(id);
      await as(a.admin.id);
      const [row] = (await list(client)).filter((r) => r.id === id);
      expect(row).toMatchObject({
        provider_name: 'MANUTENCAO DE AR LTDA', service_value: '1000.00', iss_value: '50.00', iss_withholding: 2,
        total_withheld: '111.50', net_value: '888.50', status: 'active', competence: '2026-11-01',
      });
      const { rows: [full] } = await client.query('SELECT s.*, d.xml FROM v_service_invoice s JOIN v_dfe_document d ON d.id = s.document_id WHERE s.id = $1', [id]);
      expect(full).toMatchObject({ role: 'received', service_code: '140101', irrf_withheld: '15.00', pis_cofins_withholding: 3, xml: '<NFSe/>' });
    });
  });

  it('a emitida pela filial e a intermediada ficam guardadas, fora da lista', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const issued = await record(client, a.branch1, note({ providerDocument: a.branch1.cnpj, takerDocument: '52998224725' }));
      const other = await record(client, a.branch1, note({ takerDocument: '11222333000181' }));
      await as(a.admin.id);
      const { rows } = await client.query('SELECT id, role FROM v_service_invoice WHERE id = ANY($1) ORDER BY role', [[issued, other]]);
      expect(rows.map((r) => r.role)).toEqual(['intermediary', 'issued']);
      expect((await list(client)).filter((r) => [issued, other].includes(r.id))).toEqual([]);
    });
  });

  it('filtra por filial, período e situação', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const october = await record(client, a.branch1, note({ competence: '2026-10-01' }));
      const november = await record(client, a.branch1, note());
      const other = await record(client, a.branch2, note({ takerDocument: a.branch2.cnpj }));
      const december = await record(client, a.branch1, note({ competence: '2026-12-01' }));
      await as(a.admin.id);
      const ids = (rows) => rows.map((r) => r.id).filter((id) => [october, november, other, december].includes(id)).sort();
      expect(ids(await list(client, [a.branch1.id, null, null, null]))).toEqual([october, november, december].sort());
      expect(ids(await list(client, [null, '2026-11-01', '2026-11-30', null]))).toEqual([november, other].sort());
      expect(ids(await list(client, [null, null, null, 'cancelled']))).toEqual([]);
    });
  });

  it('cancelamento e substituição, em qualquer ordem de chegada', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const cancelled = note();
      const cancelledId = await record(client, a.branch1, cancelled);
      await event(client, a.branch1, cancelled.accessKey, 'cancel');

      // Substituição: o evento chega depois das duas notas.
      const old = note();
      const oldId = await record(client, a.branch1, old);
      const fresh = note({ replacesKey: old.accessKey });
      const freshId = await record(client, a.branch1, fresh);
      await event(client, a.branch1, old.accessKey, 'replace', fresh.accessKey);

      // A substituta chega antes da substituída.
      const late = note();
      const early = note({ replacesKey: late.accessKey });
      const earlyId = await record(client, a.branch1, early);
      const lateId = await record(client, a.branch1, late);

      // Evento de nota que não chegou não quebra nada.
      await event(client, a.branch1, key(), 'cancel');

      await as(a.admin.id);
      const status = async (id) => (await client.query('SELECT status, replaced_by, status_changed_at FROM v_service_invoice WHERE id = $1', [id])).rows[0];
      expect(await status(cancelledId)).toMatchObject({ status: 'cancelled', replaced_by: null });
      expect((await status(cancelledId)).status_changed_at).not.toBeNull();
      expect(await status(oldId)).toMatchObject({ status: 'replaced', replaced_by: freshId });
      expect(await status(freshId)).toMatchObject({ status: 'active' });
      expect(await status(lateId)).toMatchObject({ status: 'replaced', replaced_by: earlyId });
      expect((await list(client, [null, null, null, 'cancelled'])).map((r) => r.id)).toContain(cancelledId);

      // Cancelada não volta a valer, nem vira substituída depois.
      await worker();
      await event(client, a.branch1, cancelled.accessKey, 'replace', fresh.accessKey);
      await as(a.admin.id);
      expect(await status(cancelledId)).toMatchObject({ status: 'cancelled' });
    });
  });

  it('a substituta sozinha marca a antiga; o evento sozinho também', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const old = note();
      const oldId = await record(client, a.branch1, old);
      const fresh = note({ replacesKey: old.accessKey });
      const freshId = await record(client, a.branch1, fresh);

      const alone = note();
      const aloneId = await record(client, a.branch1, alone);
      await event(client, a.branch1, alone.accessKey, 'replace', key());

      await as(a.admin.id);
      const row = async (id) => (await client.query('SELECT status, replaced_by FROM v_service_invoice WHERE id = $1', [id])).rows[0];
      expect(await row(oldId)).toEqual({ status: 'replaced', replaced_by: freshId });
      expect(await row(aloneId)).toEqual({ status: 'replaced', replaced_by: null });
    });
  });

  it('o evento de um grupo não mexe na nota de outro grupo com a mesma chave', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const data = note({ takerDocument: b.branch1.cnpj });
      const otherGroup = await record(client, b.branch1, data);
      await event(client, a.branch1, data.accessKey, 'cancel');
      await as(b.admin.id);
      expect((await client.query('SELECT status FROM v_service_invoice WHERE id = $1', [otherGroup])).rows[0].status).toBe('active');
    });
  });

  it('só quem vê compras na filial vê a nota de serviço', async () => {
    await session(async (client, { as, worker }) => {
      await worker();
      const mine = await record(client, a.branch1, note());
      const branch2 = await record(client, a.branch2, note({ takerDocument: a.branch2.cnpj }));
      await as(manager.id);
      const seen = (await list(client)).map((r) => r.id);
      expect(seen).toContain(mine);
      expect(seen).not.toContain(branch2);
      await as(a.oneBranchUser.id);
      expect(await list(client)).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_service_invoice')).rows).toEqual([]);
      await as(b.admin.id);
      expect((await list(client)).filter((r) => [mine, branch2].includes(r.id))).toEqual([]);
    });
  });
});

describe('travas', () => {
  it('o que veio do ADN não muda; a situação só muda pelas regras', async () => {
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.worker', 'dfe', true)`);
      const data = note();
      const documentId = (await client.query('SELECT app.dfe_store_nfse_document($1, $2, $3, $4, $5) AS id', [a.branch1.id, nsu((nextNsu += 1)), 'NFSE', data.accessKey, '<NFSe/>'])).rows[0].id;
      const id = (await client.query('SELECT app.nfse_record_invoice($1, $2, $3::jsonb) AS id', [a.branch1.id, documentId, JSON.stringify(data)])).rows[0].id;
      for (const sql of [
        'UPDATE service_invoice SET net_value = 1 WHERE id = $1',
        "UPDATE service_invoice SET role = 'issued' WHERE id = $1",
        'UPDATE service_invoice SET deleted_at = now() WHERE id = $1',
        "UPDATE dfe_document SET kind = 'nfe' WHERE id = (SELECT document_id FROM service_invoice WHERE id = $1)",
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql, [id])).rejects.toSatisfy(hasCode('FA104'));
        await client.query('ROLLBACK TO s');
      }
      for (const sql of [
        "UPDATE service_invoice SET status = 'cancelled' WHERE id = $1",
        "UPDATE service_invoice SET status = 'expired', status_changed_at = now() WHERE id = $1",
      ]) {
        await client.query('SAVEPOINT s');
        await expect(client.query(sql, [id])).rejects.toSatisfy(hasCode('FA931'));
        await client.query('ROLLBACK TO s');
      }
      await client.query('SAVEPOINT s');
      await expect(client.query(
        `INSERT INTO service_invoice (economic_group_id, branch_id, document_id, role, access_key, number, environment, issued_at, competence,
                                      provider_name, description, service_value, net_value)
         SELECT economic_group_id, branch_id, document_id, role, access_key, '9', environment, issued_at, competence, provider_name,
                description, service_value, net_value FROM service_invoice WHERE id = $1`, [id],
      )).rejects.toSatisfy(hasCode('FA008'));
      await client.query('ROLLBACK TO s');
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.nfse_record_invoice($1, $2, $3::jsonb)', [a.branch1.id, documentId, JSON.stringify({ ...data, accessKey: key(), netValue: '-1' })]))
        .rejects.toSatisfy(hasCode('FA931'));
      await client.query('ROLLBACK TO s');
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
