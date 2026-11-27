import { randomInt } from 'node:crypto';
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
});
afterAll(closePools);

describe('rotina do Catálogo', () => {
  it('só a rotina grava: usuário, outra rotina ou sem nada recebem FA002', async () => {
    for (const sql of [
      "SELECT app.catalog_sync_start('manual')", "SELECT app.catalog_sync_apply('[]'::jsonb)",
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

    const started = (await asWorker("SELECT app.catalog_sync_start('manual') AS s"))[0].s;
    expect(started.runId).toEqual(expect.any(String));
    expect(started.hashes[stays]).toBe(stayHash);
    // Outra cópia no meio não começa.
    expect((await asWorker("SELECT app.catalog_sync_start('schedule') AS s"))[0].s).toBeNull();

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
    const next = (await asWorker("SELECT app.catalog_sync_start('schedule') AS s"))[0].s;
    expect(next.etag).toBe('W/"abc"');
    expect(next.hashes[leaves]).toBeUndefined();
    await apply([{ sourceKey: leaves, name: 'Sai do catálogo', barcodes: [leaveCode], hash: hash() }]);
    expect(await found(leaveCode)).toBe(1);
    // Catálogo igual (304): nada é marcado como fora.
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, $3)', [next.runId, JSON.stringify({ status: 'unchanged', etag: 'W/"abc"', items: 0, changed: 0, failed: 0 }), [stays]]);
    expect((await row(leaves)).external_removed_at).toBeNull();
  });

  it('a ETag que vale é a da última cópia boa, não a de uma falha', async () => {
    const good = (await asWorker("SELECT app.catalog_sync_start('manual') AS s"))[0].s;
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [good.runId, JSON.stringify({ status: 'unchanged', etag: 'W/"boa"', items: 0, changed: 0, failed: 0 })]);
    const bad = (await asWorker("SELECT app.catalog_sync_start('manual') AS s"))[0].s;
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [bad.runId, JSON.stringify({ status: 'failed', etag: 'W/"ruim"', message: 'Falhou no meio' })]);
    const next = (await asWorker("SELECT app.catalog_sync_start('schedule') AS s"))[0].s;
    expect(next.etag).toBe('W/"boa"');
    await asWorker('SELECT app.catalog_sync_finish($1, $2::jsonb, NULL)', [next.runId, JSON.stringify({ status: 'failed', message: 'Teste' })]);
  });

  it('cópia que ficou pela metade há mais de 30 minutos vira falha e libera a próxima', async () => {
    const stuck = (await asWorker("SELECT app.catalog_sync_start('manual') AS s"))[0].s;
    await ownerPool.query("UPDATE catalog_sync_run SET started_at = now() - interval '31 minutes' WHERE id = $1", [stuck.runId]);
    const next = (await asWorker("SELECT app.catalog_sync_start('schedule') AS s"))[0].s;
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
    expect(status.runs[0]).toMatchObject({ trigger: expect.any(String), status: expect.any(String) });
    await expect(asUser(a.admin, 'SELECT app.catalog_sync_status()')).rejects.toSatisfy(hasCode('FA002'));
  });
});
