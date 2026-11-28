import { randomBytes, randomInt } from 'node:crypto';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setUser } from './helpers.mjs';

// Catálogo externo (catalogo-produtos): cópia horária e consulta na hora, gravadas só pela rotina
// do Catálogo; pendente não vincula; o que saiu do catálogo some da busca.

let a;
let platform;

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
const asWorker = (sql, params, worker = 'catalog') =>
  run((c) => c.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', $1, true)", [worker]), sql, params);
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);
/** Usuário com as permissões dadas, só na filial dada. */
async function userAt(codes, branch) {
  const role = (await ownerPool.query('INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING id', [a.group.id, `Perfil ${randomInt(1e9)}`])).rows[0].id;
  await ownerPool.query('INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)', [role, codes]);
  const user = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Usuário ${randomInt(1e9)}`])).rows[0];
  await ownerPool.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [user.id, role]);
  await ownerPool.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
  return user;
}
const setKey = (user, branch, prefix = 'cat_abc12') =>
  asUser(user, 'SELECT app.set_branch_catalog_key($1, $2, $3)', [branch.id, randomBytes(48), prefix]);
const start = (trigger, branch = a.branch1) =>
  asWorker('SELECT app.catalog_sync_start($1, $2) AS s', [trigger, branch.id]).then((r) => r[0].s);
const apply = (items) => asWorker('SELECT app.catalog_sync_apply($1::jsonb) AS r', [JSON.stringify(items)]).then((r) => r[0].r);

/** GTIN-13 com dígito certo, ao acaso. */
function gtin() {
  let base = '789';
  for (let i = 0; i < 9; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const key = () => `catalogo:${randomInt(1, 999_999_999)}`;
const hash = () => Array.from({ length: 64 }, () => '0123456789abcdef'[randomInt(16)]).join('');
const row = (sourceKey) => ownerPool.query(
  `SELECT cp.*, m.name AS manufacturer, ARRAY(SELECT b.code FROM catalog_product_barcode b WHERE b.catalog_product_id = cp.id AND b.deleted_at IS NULL ORDER BY b.code) AS codes
     FROM catalog_product cp LEFT JOIN catalog_manufacturer m ON m.id = cp.manufacturer_id
    WHERE cp.source_key = $1 AND cp.deleted_at IS NULL`, [sourceKey],
).then((r) => r.rows[0]);
const newProduct = (catalogProductId) => asUser(a.admin, 'SELECT app.create_product($1::jsonb) AS id', [
  JSON.stringify({ displayName: `Produto do Catálogo ${randomInt(1e6)}`, barcode: gtin(), catalogProductId }),
]).then((r) => r[0].id);

beforeAll(async () => {
  ({ a } = await createFixtures());
  platform = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, 'Plataforma'])).rows[0];
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [platform.id]);
  await setKey(a.admin, a.branch1);
});
afterAll(closePools);

describe('chave do Catálogo por filial', () => {
  it('quem cuida do certificado da filial cadastra e troca; a tela mostra só o começo; uma por filial', async () => {
    await setKey(a.admin, a.branch2, 'cat_primeira');
    await expect(setKey(a.admin, a.branch2, 'cat_x')).resolves.toBeDefined();
    const rows = await asUser(a.admin, 'SELECT * FROM app.branch_catalog_keys()');
    expect(rows.find((r) => r.branch_id === a.branch2.id)).toMatchObject({ key_prefix: 'cat_x', can_manage: true, key_updated_at: expect.any(Date) });
    expect(rows.find((r) => r.branch_id === a.branchFree.id)).toMatchObject({ key_prefix: null });
    expect(rows[0]).not.toHaveProperty('encrypted_key');
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM branch_catalog_key WHERE branch_id = $1 AND deleted_at IS NULL', [a.branch2.id])).rows[0].n).toBe(1);
    await asUser(a.admin, 'SELECT app.clear_branch_catalog_key($1)', [a.branch2.id]);
    expect((await asUser(a.admin, 'SELECT * FROM app.branch_catalog_keys()')).find((r) => r.branch_id === a.branch2.id).key_prefix).toBeNull();
  });

  it('sem a permissão do certificado, de outro grupo ou com chave fora do formato, recusa', async () => {
    await expect(setKey(a.oneBranchUser, a.branch1)).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.oneBranchUser, 'SELECT app.clear_branch_catalog_key($1)', [a.branch1.id])).rejects.toSatisfy(hasCode('FA002'));
    const other = (await createFixtures()).b;
    await expect(setKey(other.admin, a.branch1)).rejects.toSatisfy(hasCode('FA006'));
    await expect(setKey(a.admin, a.branch2, 'abc')).rejects.toSatisfy(hasCode('FA231'));
    await expect(asUser(a.admin, 'SELECT app.set_branch_catalog_key($1, $2, $3)', [a.branch2.id, Buffer.alloc(5), 'cat_a'])).rejects.toSatisfy(hasCode('FA231'));
    // Quem não vê o fiscal da filial não vê a filial na lista.
    expect((await asUser(other.admin, 'SELECT * FROM app.branch_catalog_keys()')).map((r) => r.branch_id)).not.toContain(a.branch1.id);
    const viewer = await userAt(['fiscal.view'], a.branch1);
    expect((await asUser(viewer, 'SELECT branch_id, can_manage FROM app.branch_catalog_keys()'))).toEqual([{ branch_id: a.branch1.id, can_manage: false }]);
    await expect(setKey(viewer, a.branch1)).rejects.toSatisfy(hasCode('FA002'));
  });

  it('a rotina lê as chaves de todas as filiais; o usuário, só a da filial principal dele', async () => {
    const keys = await asWorker('SELECT * FROM app.catalog_branch_keys()');
    const mine = keys.find((k) => k.branch_id === a.branch1.id);
    expect(mine.encrypted_key).toBeInstanceOf(Buffer);
    expect((await asUser(a.admin, 'SELECT * FROM app.user_catalog_key()'))).toEqual([{ branch_id: a.branch1.id, encrypted_key: mine.encrypted_key }]);
    // Usuário só de uma filial sem chave: nada, mesmo com a filial 1 tendo chave.
    const onlyFree = await userAt(['fiscal.view'], a.branchFree);
    expect(await asUser(onlyFree, 'SELECT * FROM app.user_catalog_key()')).toEqual([]);
    expect(await asWorker('SELECT * FROM app.user_catalog_key()')).toEqual([]);
    // Filial sem chave não começa cópia.
    await expect(start('manual', a.branchFree)).rejects.toSatisfy(hasCode('FA228'));
  });
});

describe('rotina do Catálogo', () => {
  it('só a rotina grava: usuário, outra rotina ou sem nada recebem FA002', async () => {
    for (const sql of [
      "SELECT app.catalog_sync_start('manual', gen_random_uuid())", 'SELECT * FROM app.catalog_branch_keys()', "SELECT app.catalog_sync_apply('[]'::jsonb)",
      'SELECT * FROM app.catalog_images_due(10)', "SELECT app.catalog_sync_images('catalogo:1', '{}', '[]'::jsonb)",
      "SELECT app.catalog_sync_finish(gen_random_uuid(), '{}'::jsonb, NULL)",
    ]) {
      await expect(asUser(a.admin, sql), sql).rejects.toSatisfy(hasCode('FA002'));
      await expect(asWorker(sql, [], 'fiscal'), sql).rejects.toSatisfy(hasCode('FA002'));
      // Usuário logado com a marca da rotina também não passa.
      await expect(run((c) => c.query("SELECT set_config('app.user_id', $1, true), set_config('app.worker', 'catalog', true)", [a.admin.id]), sql), sql)
        .rejects.toSatisfy(hasCode('FA002'));
    }
  });

  it('grava o item no formato daqui: limpa o que não cabe, descarta código inválido, guarda pendente, imagens e impressão digital', async () => {
    const k = key();
    const [good, other] = [gtin(), gtin()];
    const fingerprint = hash();
    const result = await apply([{
      sourceKey: k, name: '  Dorflex  C/10 Comp ', manufacturer: 'Sanofi', activeIngredient: 'dipirona 300 mg + orfenadrina 35 mg',
      msRegistration: '1.0300.0085.001-1', controlledClass: 'Antimicrobiano', ncm: '3004.90.99', cest: '13.001.00',
      barcodes: [good, '123', other, good], pending: false, hash: fingerprint, images: ['https://catalogo.test/files/a.webp', 'https://catalogo.test/files/b.webp'],
    }]);
    expect(result).toEqual({ changed: 1, failures: [] });
    const saved = await row(k);
    expect(saved).toMatchObject({
      name: 'Dorflex  C/10 Comp', manufacturer: 'Sanofi', active_ingredient: 'dipirona 300 mg + orfenadrina 35 mg', ms_registration: '1030000850011',
      controlled_class: 'antimicrobial', ncm: '30049099', cest: '1300100', external_pending: false, external_removed_at: null, external_hash: fingerprint,
      external_image_urls: ['https://catalogo.test/files/a.webp', 'https://catalogo.test/files/b.webp'],
    });
    expect(saved.codes).toEqual([good, other].sort());

    // Valores fora do formato daqui ficam vazios; controlado desconhecido também.
    await apply([{ sourceKey: k, name: 'Dorflex', msRegistration: '12', controlledClass: 'X9', ncm: '3004', cest: '1', barcodes: [good], hash: fingerprint }]);
    expect(await row(k)).toMatchObject({ ms_registration: null, controlled_class: null, ncm: null, cest: null, codes: [good], external_image_urls: [] });
    await apply([{ sourceKey: k, name: 'Rivotril', controlledClass: ' b1 ', barcodes: [good], hash: fingerprint }]);
    expect((await row(k)).controlled_class).toBe('B1');
  });

  it('marca e departamento ficam em campos próprios, a busca acha pela marca e devolve os dois', async () => {
    const k = key();
    const code = gtin();
    const brand = `Marca Teste ${randomInt(1e9)}`;
    await apply([{ sourceKey: k, name: 'Produto com marca', manufacturer: 'Fabricante Teste', brand: `  ${brand} `, department: ' Perfumaria ', barcodes: [code], hash: hash() }]);
    expect(await row(k)).toMatchObject({ manufacturer: 'Fabricante Teste', brand, department: 'Perfumaria' });
    const found = await asUser(a.admin, 'SELECT name, manufacturer, brand, department FROM app.search_catalog($1)', [brand]);
    expect(found).toEqual([{ name: 'Produto com marca', manufacturer: 'Fabricante Teste', brand, department: 'Perfumaria' }]);
    // Sem marca e sem departamento lá, ficam vazios aqui.
    await apply([{ sourceKey: k, name: 'Produto com marca', barcodes: [code], hash: hash() }]);
    expect(await row(k)).toMatchObject({ brand: null, department: null });
    expect(await asUser(a.admin, 'SELECT id FROM app.search_catalog($1)', [brand])).toEqual([]);
  });

  it('o código que passou para outro item sai do antigo; item recusado não para os outros', async () => {
    const [old, moved] = [key(), key()];
    const code = gtin();
    await apply([{ sourceKey: old, name: 'Cadastro antigo', barcodes: [code], hash: hash() }]);
    const result = await apply([
      { sourceKey: 'outra-origem:1', name: 'Sem a chave do catálogo', hash: hash() },
      { sourceKey: key(), name: '   ', hash: hash() },
      { sourceKey: moved, name: 'Cadastro novo', barcodes: [code], hash: hash() },
      { sourceKey: key(), name: 'Impressão inválida', hash: 'xyz' },
    ]);
    expect(result.changed).toBe(1);
    expect(result.failures.map((f) => f.sourceKey)).toEqual(['outra-origem:1', expect.stringMatching(/^catalogo:/), expect.stringMatching(/^catalogo:/)]);
    expect((await row(old)).codes).toEqual([]);
    expect((await row(moved)).codes).toEqual([code]);
    await expect(apply({ not: 'list' })).rejects.toSatisfy(hasCode('FA005'));
  });

  it('cópia: uma por vez, com a ETag e as impressões da última boa; no fim, o que não veio sai da busca e volta se reaparecer', async () => {
    const [stays, leaves] = [key(), key()];
    const [stayCode, leaveCode] = [gtin(), gtin()];
    const stayHash = hash();
    await apply([{ sourceKey: stays, name: 'Fica no catálogo', barcodes: [stayCode], hash: stayHash }, { sourceKey: leaves, name: 'Sai do catálogo', barcodes: [leaveCode], hash: hash() }]);

    const started = (await start('manual'));
    expect(started.runId).toEqual(expect.any(String));
    expect(started.hashes[stays]).toBe(stayHash);
    // Outra cópia no meio não começa.
    expect((await start('schedule'))).toBeNull();

    const everything = (await ownerPool.query("SELECT array_agg(source_key) AS k FROM catalog_product WHERE source_key LIKE 'catalogo:%' AND deleted_at IS NULL AND source_key <> $1", [leaves])).rows[0].k;
    const finished = (await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, $3) AS f', [
      started.runId, JSON.stringify({ status: 'updated', etag: 'W/"abc"', items: everything.length, changed: 2, failed: 0, message: null }), everything,
    ]))[0].f;
    expect(finished.removed).toBeGreaterThanOrEqual(1);
    expect((await row(leaves)).external_removed_at).not.toBeNull();
    const found = (code) => asUser(a.admin, 'SELECT id FROM app.search_catalog($1)', [code]).then((r) => r.length);
    expect(await found(leaveCode)).toBe(0);
    expect(await found(stayCode)).toBe(1);
    // A mesma cópia não fecha duas vezes.
    await expect(asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [started.runId, JSON.stringify({ status: 'failed' })]))
      .rejects.toSatisfy(hasCode('FA006'));

    // A próxima cópia recebe a ETag; o item que voltou ao catálogo volta à busca.
    const next = (await start('schedule'));
    expect(next.etag).toBe('W/"abc"');
    expect(next.hashes[leaves]).toBeUndefined();
    await apply([{ sourceKey: leaves, name: 'Sai do catálogo', barcodes: [leaveCode], hash: hash() }]);
    expect(await found(leaveCode)).toBe(1);
    // Catálogo igual (304): nada é marcado como fora.
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, $3)', [next.runId, JSON.stringify({ status: 'unchanged', etag: 'W/"abc"', items: 0, changed: 0, failed: 0 }), [stays]]);
    expect((await row(leaves)).external_removed_at).toBeNull();
  });

  it('a ETag que vale é a da última cópia boa, não a de uma falha', async () => {
    const good = (await start('manual'));
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [good.runId, JSON.stringify({ status: 'unchanged', etag: 'W/"boa"', items: 0, changed: 0, failed: 0 })]);
    const bad = (await start('manual'));
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [bad.runId, JSON.stringify({ status: 'failed', etag: 'W/"ruim"', message: 'Falhou no meio' })]);
    const next = (await start('schedule'));
    expect(next.etag).toBe('W/"boa"');
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [next.runId, JSON.stringify({ status: 'failed', message: 'Teste' })]);
  });

  it('cópia que ficou pela metade há mais de 30 minutos vira falha e libera a próxima', async () => {
    const stuck = (await start('manual'));
    await ownerPool.query("UPDATE catalog_sync_run SET started_at = now() - interval '31 minutes' WHERE id = $1", [stuck.runId]);
    const next = (await start('schedule'));
    expect(next.runId).not.toBe(stuck.runId);
    expect((await ownerPool.query('SELECT status, message FROM catalog_sync_run WHERE id = $1', [stuck.runId])).rows[0])
      .toEqual({ status: 'failed', message: 'Interrompida.' });
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [next.runId, JSON.stringify({ status: 'failed', message: 'Catálogo fora do ar' })]);
  });

  it('pendente aparece na busca por último e não vincula; o que saiu do catálogo também não', async () => {
    const [pending, ready, gone] = [key(), key(), key()];
    const name = `Teste vinculo ${randomInt(1e9)}`;
    await apply([
      { sourceKey: pending, name: `${name} provisorio`, barcodes: [gtin()], pending: true, hash: hash() },
      { sourceKey: ready, name: `${name} pronto`, barcodes: [gtin()], hash: hash() },
      { sourceKey: gone, name: `${name} saiu`, barcodes: [gtin()], hash: hash() },
    ]);
    await ownerPool.query('UPDATE catalog_product SET external_removed_at = now() WHERE source_key = $1', [gone]);
    const results = await asUser(a.admin, 'SELECT name, pending FROM app.search_catalog($1)', [name]);
    expect(results).toEqual([{ name: `${name} pronto`, pending: false }, { name: `${name} provisorio`, pending: true }]);

    await expect(newProduct((await row(pending)).id)).rejects.toSatisfy(hasCode('FA226'));
    const removedId = (await row(gone)).id;
    await expect(newProduct(removedId)).rejects.toSatisfy(hasCode('FA226'));
    const linked = await newProduct((await row(ready)).id);
    // Produto já vinculado continua vinculado quando o item sai do catálogo, e pode ser alterado.
    await ownerPool.query('UPDATE catalog_product SET external_removed_at = now() WHERE source_key = $1', [ready]);
    await ownerPool.query("UPDATE product SET display_name = display_name || ' alterado' WHERE id = $1", [linked]);
    // Salvar o produto regrava o mesmo vínculo: continua valendo.
    await ownerPool.query('UPDATE product SET catalog_product_id = catalog_product_id WHERE id = $1', [linked]);
    // Item pendente que ficou pronto passa a vincular.
    await apply([{ sourceKey: pending, name: `${name} provisorio`, barcodes: [], pending: false, hash: hash() }]);
    await expect(newProduct((await row(pending)).id)).resolves.toEqual(expect.any(String));
  });

  it('imagens: só dos itens vinculados, até ficarem iguais às de lá', async () => {
    const [linkedKey, loose] = [key(), key()];
    const urls = ['https://catalogo.test/files/1.webp'];
    await apply([{ sourceKey: linkedKey, name: 'Com produto', barcodes: [gtin()], hash: hash(), images: urls }, { sourceKey: loose, name: 'Sem produto', barcodes: [gtin()], hash: hash(), images: urls }]);
    await newProduct((await row(linkedKey)).id);
    const due = await asWorker('SELECT * FROM app.catalog_images_due(200)');
    expect(due.find((d) => d.source_key === linkedKey)).toEqual({ source_key: linkedKey, urls });
    expect(due.find((d) => d.source_key === loose)).toBeUndefined();

    const full = await sharp({ create: { width: 40, height: 30, channels: 3, background: '#3366aa' } }).webp().toBuffer();
    const image = { sha256: hash(), width: 40, height: 30, full: full.toString('base64'), thumb: full.toString('base64'), main: true };
    await asWorker('SELECT app.catalog_sync_images($1, $2, $3::jsonb)', [linkedKey, urls, JSON.stringify([image])]);
    expect((await asWorker('SELECT * FROM app.catalog_images_due(200)')).find((d) => d.source_key === linkedKey)).toBeUndefined();
    expect((await ownerPool.query('SELECT count(*)::int AS n FROM catalog_product_image i JOIN catalog_product cp ON cp.id = i.catalog_product_id WHERE cp.source_key = $1 AND i.deleted_at IS NULL', [linkedKey])).rows[0].n).toBe(1);
    // Mudou lá: volta para a fila.
    await apply([{ sourceKey: linkedKey, name: 'Com produto', hash: hash(), images: ['https://catalogo.test/files/2.webp'] }]);
    expect((await asWorker('SELECT * FROM app.catalog_images_due(200)')).find((d) => d.source_key === linkedKey)).toBeDefined();
    await expect(asWorker('SELECT app.catalog_sync_images($1, $2, $3::jsonb)', ['demo-1', urls, '[]'])).rejects.toSatisfy(hasCode('FA005'));
  });

  it('a situação da cópia é só da Plataforma', async () => {
    const status = (await asUser(platform, 'SELECT app.catalog_sync_status() AS s'))[0].s;
    expect(status).toMatchObject({ items: expect.any(Number), pending: expect.any(Number), removed: expect.any(Number), imagesDue: expect.any(Number) });
    expect(status.runs.length).toBeGreaterThan(0);
    expect(status.runs[0]).toMatchObject({ trigger: expect.any(String), status: expect.any(String), branch: expect.stringContaining(' · ') });
    expect(status.branches).toBeGreaterThanOrEqual(status.branchesWithKey);
    expect(status.withoutKey.length).toBeGreaterThan(0);
    expect(status.withoutKey.length).toBeLessThanOrEqual(20);
    await expect(asUser(a.admin, 'SELECT app.catalog_sync_status()')).rejects.toSatisfy(hasCode('FA002'));
  });
});
