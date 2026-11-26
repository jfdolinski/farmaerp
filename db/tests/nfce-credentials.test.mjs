import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// NFC-e no caixa (8A-2a): "Emitir NFC-e" por filial, chave de criptografia do caixa e a entrega
// do certificado e do CSC, sempre registrada.

let a;
let b;
const DAY = 24 * 60 * 60 * 1000;
const key = () => randomBytes(32).toString('base64url');

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

const setCertificate = (fixture, branch, validTo = new Date(Date.now() + 200 * DAY)) =>
  asUser(fixture.admin, 'SELECT app.set_branch_certificate($1, $2::jsonb, $3, $4) AS id', [
    branch.id,
    JSON.stringify({
      subjectName: `EMPRESA ${fixture.root}:${branch.cnpj}`,
      cnpj: branch.cnpj,
      validFrom: new Date(Date.now() - DAY).toISOString(),
      validTo: validTo.toISOString(),
      fingerprint: createHash('sha256').update(randomBytes(16)).digest('hex'),
    }),
    randomBytes(64),
    randomBytes(32),
  ]).then((r) => r[0].id);
// Certificado vencido não entra pela função (FA914): aqui ele é trocado direto no banco.
async function expireCertificate(branch) {
  await ownerPool.query('UPDATE branch_certificate SET deleted_at = now() WHERE branch_id = $1 AND deleted_at IS NULL', [branch.id]);
  await ownerPool.query(
    `INSERT INTO branch_certificate (economic_group_id, branch_id, subject_name, cnpj, valid_from, valid_to, fingerprint, encrypted_pfx, encrypted_password)
     SELECT economic_group_id, branch_id, subject_name, cnpj, now() - interval '2 days', now() - interval '1 day', fingerprint, encrypted_pfx, encrypted_password
       FROM branch_certificate WHERE branch_id = $1 ORDER BY created_at DESC LIMIT 1`,
    [branch.id],
  );
}
const setCsc = (fixture, branch) =>
  asUser(fixture.admin, 'SELECT app.set_branch_csc($1, $2, $3) AS id', [branch.id, '000001', randomBytes(48)]).then((r) => r[0].id);
const setNfce = (user, branch, enabled, environment = 2, hours = 24) =>
  asUser(user, 'SELECT app.set_branch_nfce($1, $2, $3::smallint, $4::smallint)', [branch.id, enabled, environment, hours]);
const settings = (user, branch) =>
  asUser(user, 'SELECT * FROM app.nfce_settings() WHERE branch_id = $1', [branch.id]).then((r) => r[0]);
const fiscalData = (branch, terminal) =>
  ownerPool.query('SELECT app.pdv_fiscal_data($1, $2) AS d', [branch.id, terminal.id]).then((r) => r.rows[0].d);
const changeXid = (branch) =>
  ownerPool.query("SELECT xid::text FROM sync_change WHERE entity = 'fiscal' AND entity_id = $1 AND branch_id = $1 AND deleted_at IS NULL", [branch.id])
    .then((r) => r.rows[0]?.xid ?? null);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  await ownerPool.query("UPDATE branch SET state = 'SP' WHERE id = ANY ($1)", [[a.branch1.id, a.branch2.id, b.branch1.id]]);
  await ownerPool.query("UPDATE branch SET state = 'RJ' WHERE id = $1", [a.branchFree.id]);
});
afterAll(closePools);

describe('Emitir NFC-e por filial', () => {
  it('só liga com inscrição, regime, CSC e certificado válido, num estado atendido', async () => {
    await expect(setNfce(a.oneBranchUser, a.branch1, true)).rejects.toSatisfy(hasCode('FA002'));
    await expect(setNfce(b.admin, a.branch1, true)).rejects.toSatisfy(hasCode('FA006'));
    await expect(setNfce(a.admin, a.branch1, true, 3)).rejects.toSatisfy(hasCode('FA728'));
    await expect(setNfce(a.admin, a.branch1, true, 2, 0)).rejects.toSatisfy(hasCode('FA728'));
    await expect(setNfce(a.admin, a.branch1, true, 2, 169)).rejects.toSatisfy(hasCode('FA728'));
    await expect(setNfce(a.admin, a.branchFree, true)).rejects.toSatisfy(hasCode('FA725'));

    // Sem nada: falta inscrição, regime e CSC.
    await expect(setNfce(a.admin, a.branch1, true)).rejects.toSatisfy(hasCode('FA727'));
    expect(await settings(a.admin, a.branch1)).toMatchObject({
      enabled: false, environment: 2, contingency_hours: 24, state_supported: true, has_state_registration: false,
      has_regime: false, has_certificate: false, has_csc: false, terminals: 1, terminals_ready: 0, can_manage: true,
    });
    // Cada requisito sozinho barra: CSC e certificado prontos, falta só a inscrição (o regime já está).
    await setCsc(a, a.branch1);
    await setCertificate(a, a.branch1);
    await asUser(a.admin, 'SELECT app.set_company_tax_regime($1, $2::smallint)', [a.company.id, 1]);
    await expect(setNfce(a.admin, a.branch1, true)).rejects.toSatisfy(hasCode('FA727'));
    await asUser(a.admin, 'SELECT app.set_branch_state_registration($1, $2)', [a.branch1.id, '110042490114']);
    // No grupo B, falta só o regime.
    await setCsc(b, b.branch1);
    await setCertificate(b, b.branch1);
    await asUser(b.admin, 'SELECT app.set_branch_state_registration($1, $2)', [b.branch1.id, '110042490114']);
    await expect(setNfce(b.admin, b.branch1, true)).rejects.toSatisfy(hasCode('FA727'));
    // Certificado vencido.
    await expireCertificate(a.branch1);
    await expect(setNfce(a.admin, a.branch1, true)).rejects.toSatisfy(hasCode('FA943'));
    const certificateBefore = await changeXid(a.branch1);
    await setCertificate(a, a.branch1);
    expect(await changeXid(a.branch1)).not.toBe(certificateBefore);

    const before = await changeXid(a.branch1);
    await setNfce(a.admin, a.branch1, true, 2, 36);
    expect(await changeXid(a.branch1)).not.toBe(before);
    expect(await settings(a.admin, a.branch1)).toMatchObject({ enabled: true, contingency_hours: 36, has_certificate: true, has_csc: true });
    // Quem não tem permissão fiscal nem vê a filial.
    expect(await settings(a.oneBranchUser, a.branch1)).toBeUndefined();
    expect(await settings(b.admin, a.branch1)).toBeUndefined();
  });

  it('desce para o PDV com a versão do certificado e do CSC; troca avisa o caixa', async () => {
    const data = await fiscalData(a.branch1, a.terminal1);
    expect(data.nfce).toMatchObject({ enabled: true, environment: 2, contingency_hours: 36 });
    expect(data.nfce.credential_version).toMatch(/^[0-9a-f-]{36}:[0-9a-f-]{36}$/);

    const before = await changeXid(a.branch1);
    const csc = await setCsc(a, a.branch1);
    expect(await changeXid(a.branch1)).not.toBe(before);
    expect((await fiscalData(a.branch1, a.terminal1)).nfce.credential_version).toMatch(new RegExp(`:${csc}$`));

    // Filial desligada não manda versão.
    expect((await fiscalData(a.branch2, a.terminal2)).nfce).toMatchObject({ enabled: false, credential_version: null });
  });
});

describe('entrega ao caixa', () => {
  it('registra a chave do caixa; entrega só a caixa de filial ligada, com chave', async () => {
    await expect(asTerminal(a.terminal1, 'SELECT app.terminal_nfce_credentials()')).rejects.toSatisfy(hasCode('FA731'));
    await expect(asTerminal(a.terminal1, 'SELECT app.set_terminal_fiscal_key($1)', ['curta'])).rejects.toSatisfy(hasCode('FA731'));
    await expect(asUser(a.admin, 'SELECT app.set_terminal_fiscal_key($1)', [key()])).rejects.toSatisfy(hasCode('FA306'));
    const first = key();
    await asTerminal(a.terminal1, 'SELECT app.set_terminal_fiscal_key($1)', [first]);
    const at = (await ownerPool.query('SELECT fiscal_key, fiscal_key_at FROM terminal WHERE id = $1', [a.terminal1.id])).rows[0];
    expect(at.fiscal_key).toBe(first);
    // A mesma chave de novo não muda a data.
    await asTerminal(a.terminal1, 'SELECT app.set_terminal_fiscal_key($1)', [first]);
    expect((await ownerPool.query('SELECT fiscal_key_at FROM terminal WHERE id = $1', [a.terminal1.id])).rows[0].fiscal_key_at).toEqual(at.fiscal_key_at);

    const [{ r: delivered }] = await asTerminal(a.terminal1, 'SELECT app.terminal_nfce_credentials() AS r');
    const version = (await fiscalData(a.branch1, a.terminal1)).nfce.credential_version;
    expect(delivered).toMatchObject({
      terminal_id: a.terminal1.id, company_id: a.company.id, branch_id: a.branch1.id, credential_version: version,
      fiscal_key: first, csc_id: '000001',
    });
    expect(Buffer.from(delivered.encrypted_pfx, 'base64')).toHaveLength(64);
    expect(Buffer.from(delivered.encrypted_csc, 'base64')).toHaveLength(48);
    expect(await settings(a.admin, a.branch1)).toMatchObject({ terminals: 1, terminals_ready: 1 });

    // Chave nova do caixa: o que desceu antes não vale mais.
    await asTerminal(a.terminal1, 'SELECT app.set_terminal_fiscal_key($1)', [key()]);
    expect(await settings(a.admin, a.branch1)).toMatchObject({ terminals_ready: 0 });
    await asTerminal(a.terminal1, 'SELECT app.terminal_nfce_credentials()');
    expect(await settings(a.admin, a.branch1)).toMatchObject({ terminals_ready: 1 });
    // Certificado novo: o caixa precisa buscar de novo.
    await setCertificate(a, a.branch1);
    expect(await settings(a.admin, a.branch1)).toMatchObject({ terminals_ready: 0 });

    const log = await asUser(a.admin, 'SELECT * FROM v_terminal_credential_delivery WHERE terminal_id = $1', [a.terminal1.id]);
    expect(log).toHaveLength(2);
    expect(await asUser(b.admin, 'SELECT * FROM v_terminal_credential_delivery WHERE terminal_id = $1', [a.terminal1.id])).toEqual([]);
    await expect(ownerPool.query('UPDATE terminal_credential_delivery SET fiscal_key = $2 WHERE id = $1', [log[0].id, key()]))
      .rejects.toSatisfy(hasCode('FA104'));
  });

  it('recusa terminal de orçamento, filial desligada e certificado vencido', async () => {
    await asTerminal(a.terminal2, 'SELECT app.set_terminal_fiscal_key($1)', [key()]);
    await expect(asTerminal(a.terminal2, 'SELECT app.terminal_nfce_credentials()')).rejects.toSatisfy(hasCode('FA730'));

    const quote = (await ownerPool.query(
      "INSERT INTO terminal (branch_id, name, profile, status, public_key) VALUES ($1, $2, 'quote', 'active', $3) RETURNING *",
      [a.branch1.id, `Orçamento ${randomUUID().slice(0, 6)}`, `chave-${randomUUID()}`],
    )).rows[0];
    await asTerminal(quote, 'SELECT app.set_terminal_fiscal_key($1)', [key()]);
    await expect(asTerminal(quote, 'SELECT app.terminal_nfce_credentials()')).rejects.toSatisfy(hasCode('FA729'));

    await ownerPool.query("UPDATE terminal SET status = 'blocked' WHERE id = $1", [a.terminal1.id]);
    await expect(asTerminal(a.terminal1, 'SELECT app.terminal_nfce_credentials()')).rejects.toSatisfy(hasCode('FA304'));
    await ownerPool.query("UPDATE terminal SET status = 'active' WHERE id = $1", [a.terminal1.id]);

    await expireCertificate(a.branch1);
    await expect(asTerminal(a.terminal1, 'SELECT app.terminal_nfce_credentials()')).rejects.toSatisfy(hasCode('FA943'));

    // Desligar não pede requisito nenhum.
    await setNfce(a.admin, a.branch1, false);
    expect((await fiscalData(a.branch1, a.terminal1)).nfce).toMatchObject({ enabled: false, credential_version: null });
  });
});
