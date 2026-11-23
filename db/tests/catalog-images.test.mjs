import { randomBytes } from 'node:crypto';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  checkPreparedImage, prepareCatalogImages, prepareItemImages, sourceFormat, webpSize,
} from '../scripts/catalog-images.mjs';
import { importCatalog } from '../scripts/lib.mjs';
import { appPool, closePools, connectionConfig, createFixtures, hasCode, ownerPool } from './helpers.mjs';

let a;
let dir;
const ownerConfig = connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD);

/** Imagem gerada no teste: um retângulo de uma cor, no formato e tamanho pedidos. */
const picture = (width, height, color, format = 'png') =>
  sharp({ create: { width, height, channels: 3, background: color } })[format]().toBuffer();

beforeAll(async () => {
  ({ a } = await createFixtures());
  dir = await mkdtemp(join(tmpdir(), 'imagens-catalogo-'));
  await writeFile(join(dir, 'grande.png'), await picture(1600, 1200, '#3366aa'));
  await writeFile(join(dir, 'alta.jpg'), await picture(300, 900, '#aa6633', 'jpeg'));
  await writeFile(join(dir, 'pequena.webp'), await picture(120, 80, '#33aa66', 'webp'));
  await writeFile(join(dir, 'texto.png'), 'não é imagem');
  await writeFile(join(dir, 'enorme.png'), Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), randomBytes(5 * 1024 * 1024)]));
});
afterAll(closePools);

const sourceKey = () => `img-${randomBytes(6).toString('hex')}`;
const item = (key, images) => ({ sourceKey: key, name: `Produto com imagem ${key}`, ...(images === undefined ? {} : { images }) });
const imagesOf = (key) => ownerPool.query(
  `SELECT i.sha256, i.sort_order, i.is_main, i.width, i.height, i.deleted_at IS NOT NULL AS gone
     FROM catalog_product_image i JOIN catalog_product cp ON cp.id = i.catalog_product_id
    WHERE cp.source_key = $1 ORDER BY i.deleted_at NULLS FIRST, i.sort_order`, [key],
).then((r) => r.rows);

describe('preparo das imagens', () => {
  it('reconhece o formato pelos bytes e lê o tamanho do WebP', async () => {
    expect(sourceFormat(await picture(4, 4, '#000', 'jpeg'))).toBe('jpeg');
    expect(sourceFormat(await picture(4, 4, '#000', 'png'))).toBe('png');
    expect(sourceFormat(await picture(4, 4, '#000', 'webp'))).toBe('webp');
    expect(sourceFormat(Buffer.from('GIF89a'))).toBeNull();
    expect(webpSize(await picture(321, 123, '#123456', 'webp'))).toEqual({ width: 321, height: 123 });
    expect(webpSize(await sharp({ create: { width: 50, height: 70, channels: 4, background: '#12345680' } }).webp({ lossless: true }).toBuffer())).toEqual({ width: 50, height: 70 });
    expect(webpSize(await sharp({ create: { width: 60, height: 40, channels: 4, background: '#12345680' } }).webp().toBuffer())).toEqual({ width: 60, height: 40 });
    expect(webpSize(Buffer.from('RIFF....WEBPVP8 '))).toBeNull();
  });

  it('reduz para até 800 e 200 px, sem aumentar a pequena, e guarda o SHA-256 do original', async () => {
    const [big, tall, small] = await prepareItemImages(
      [{ file: 'grande.png' }, { file: 'alta.jpg', main: true }, { file: join(dir, 'pequena.webp') }], dir, sharp,
    );
    expect([big.width, big.height]).toEqual([800, 600]);
    expect(webpSize(Buffer.from(big.thumb, 'base64'))).toEqual({ width: 200, height: 150 });
    expect([tall.width, tall.height, tall.main]).toEqual([267, 800, true]);
    expect([small.width, small.height]).toEqual([120, 80]);
    expect(big.sha256).toMatch(/^[0-9a-f]{64}$/);
    for (const image of [big, tall, small]) expect(() => checkPreparedImage(image)).not.toThrow();
  });

  it('recusa arquivo que não é imagem, grande demais, sem caminho ou listas grandes', async () => {
    await expect(prepareItemImages([{ file: 'texto.png' }], dir, sharp)).rejects.toThrow('não é JPEG, PNG nem WebP');
    await expect(prepareItemImages([{ file: 'enorme.png' }], dir, sharp)).rejects.toThrow('passa de 5 MB');
    await expect(prepareItemImages([{}], dir, sharp)).rejects.toThrow('sem o campo "file"');
    await expect(prepareItemImages(Array.from({ length: 21 }, () => ({ file: 'grande.png' })), dir, sharp)).rejects.toThrow('até 20');
    await expect(prepareCatalogImages([item('x', [{ file: 'texto.png' }])], dir)).rejects.toThrow('Item 1 (x)');
  });

  it('a conferência antes do banco recusa o que não bate', async () => {
    const [image] = await prepareItemImages([{ file: 'grande.png' }], dir, sharp);
    expect(() => checkPreparedImage({ ...image, width: 799 })).toThrow('dimensões');
    expect(() => checkPreparedImage({ ...image, sha256: 'x' })).toThrow('SHA-256');
    expect(() => checkPreparedImage({ ...image, full: Buffer.from('não é webp').toString('base64') })).toThrow('não é WebP');
    expect(() => checkPreparedImage({ ...image, thumb: image.full })).toThrow('miniatura');
  });
});

describe('importação com imagens', () => {
  it('grava, reconhece a mesma imagem, troca a principal e retira a que saiu', async () => {
    const key = sourceKey();
    const prepared = await prepareCatalogImages([item(key, [{ file: 'grande.png' }, { file: 'alta.jpg', main: true }])], dir);
    await importCatalog(ownerConfig, prepared);
    const first = await imagesOf(key);
    expect(first.map((r) => [r.sort_order, r.is_main, r.width, r.gone])).toEqual([[1, false, 800, false], [2, true, 267, false]]);

    // Mesma lista de novo: nada muda. Sem o campo "images": as imagens ficam.
    await importCatalog(ownerConfig, prepared);
    await importCatalog(ownerConfig, [item(key)]);
    expect(await imagesOf(key)).toEqual(first);

    // Ordem nova, principal sem marca (a primeira) e a grande retirada.
    const [, tall] = prepared[0].images;
    const [small] = await prepareItemImages([{ file: 'pequena.webp' }], dir, sharp);
    await importCatalog(ownerConfig, [item(key, [{ ...tall, main: false }, small])]);
    const second = await imagesOf(key);
    expect(second.map((r) => [r.sha256, r.sort_order, r.is_main, r.gone])).toEqual([
      [tall.sha256, 1, true, false], [small.sha256, 2, false, false], [first[0].sha256, 1, false, true],
    ]);
    // A principal volta para a primeira: a antiga deixa de ser antes.
    await importCatalog(ownerConfig, [item(key, [{ ...tall, main: false }, { ...small, main: true }])]);
    await importCatalog(ownerConfig, [item(key, [{ ...tall, main: true }, small])]);
    expect((await imagesOf(key)).filter((r) => !r.gone).map((r) => [r.sha256, r.is_main])).toEqual([[tall.sha256, true], [small.sha256, false]]);
    // Lista vazia retira todas.
    await importCatalog(ownerConfig, [item(key, [])]);
    expect((await imagesOf(key)).every((r) => r.gone)).toBe(true);
  });

  it('um item com imagem ruim desfaz o arquivo inteiro', async () => {
    const good = sourceKey();
    const bad = sourceKey();
    const [image] = await prepareItemImages([{ file: 'grande.png' }], dir, sharp);
    await expect(importCatalog(ownerConfig, [item(good, [image]), item(bad, [{ ...image, height: 1 }])])).rejects.toThrow('Item 2');
    expect((await ownerPool.query('SELECT 1 FROM catalog_product WHERE source_key = $1', [good])).rows).toEqual([]);
    await expect(importCatalog(ownerConfig, [item(bad, [image, image])])).rejects.toThrow('Item 1');
  });
});

describe('regras no banco', () => {
  it('lista com repetição ou acima de 20, ou WebP falso, é recusada', async () => {
    const key = sourceKey();
    await importCatalog(ownerConfig, [item(key)]);
    const [image] = await prepareItemImages([{ file: 'grande.png' }], dir, sharp);
    const client = await ownerPool.connect();
    try {
      await client.query('BEGIN');
      const set = (images) => client.query('SELECT app.set_catalog_product_images($1, $2::jsonb)', [key, JSON.stringify(images)]);
      const many = Array.from({ length: 21 }, (_, index) => ({ ...image, sha256: index.toString(16).padStart(64, '0') }));
      const riff = (kind, size = 64) => {
        const buffer = Buffer.alloc(size);
        buffer.write('RIFF', 0, 'ascii');
        buffer.write(kind, 8, 'ascii');
        return buffer.toString('base64');
      };
      for (const images of [
        [image, image], many,
        [{ ...image, full: Buffer.from('PNG falso que não é WebP').toString('base64') }],
        [{ ...image, full: riff('AVI ') }],
        [{ ...image, full: riff('WEBP', 1024 * 1024 + 1) }],
        [{ ...image, thumb: riff('WEBP', 256 * 1024 + 1) }],
        [{ ...image, width: 801 }],
      ]) {
        await client.query('SAVEPOINT s');
        await expect(set(images)).rejects.toSatisfy(hasCode('FA955'));
        await client.query('ROLLBACK TO s');
      }
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.set_catalog_product_images($1, $2::jsonb)', ['nao-existe', '[]'])).rejects.toSatisfy(hasCode('FA004'));
      await client.query('ROLLBACK TO s');
      await set([image]);
      await client.query('SAVEPOINT s');
      await expect(client.query("UPDATE catalog_product_image SET width = 10 WHERE sha256 = $1", [image.sha256])).rejects.toSatisfy(hasCode('FA104'));
      await client.query('ROLLBACK TO s');
      const copy = (sha, main) => client.query(
        `INSERT INTO catalog_product_image (catalog_product_id, sort_order, is_main, sha256, width, height, full_webp, thumb_webp)
         SELECT catalog_product_id, 2, $2, $1, width, height, full_webp, thumb_webp FROM catalog_product_image WHERE sha256 = $3 AND deleted_at IS NULL`,
        [sha, main, image.sha256],
      );
      for (const [sha, main] of [[image.sha256, false], ['f'.repeat(64), true]]) {
        await client.query('SAVEPOINT s');
        await expect(copy(sha, main)).rejects.toSatisfy(hasCode('FA955'));
        await client.query('ROLLBACK TO s');
      }
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('usuário logado lê as imagens e o conteúdo; sem login, nada; a API não grava', async () => {
    const key = sourceKey();
    const prepared = await prepareCatalogImages([item(key, [{ file: 'grande.png', main: true }, { file: 'pequena.webp' }])], dir);
    await importCatalog(ownerConfig, prepared);
    const { rows: [{ id: catalogId }] } = await ownerPool.query('SELECT id FROM catalog_product WHERE source_key = $1', [key]);
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [a.oneBranchUser.id]);
      const { rows } = await client.query('SELECT * FROM app.catalog_images($1)', [[catalogId]]);
      expect(rows.map((r) => [r.sort_order, r.is_main, r.width])).toEqual([[1, true, 800], [2, false, 120]]);
      const content = (id, size) => client.query('SELECT * FROM app.catalog_image_content($1, $2)', [id, size]).then((r) => r.rows[0]);
      const full = await content(rows[0].id, 'full');
      const thumb = await content(rows[0].id, 'thumb');
      expect(webpSize(full.content)).toEqual({ width: 800, height: 600 });
      expect(webpSize(thumb.content)).toEqual({ width: 200, height: 150 });
      expect(full.sha256).toBe(prepared[0].images[0].sha256);
      expect(await content(rows[0].id, 'original')).toBeUndefined();
      expect((await client.query('SELECT count(*)::int AS n FROM v_catalog_product_image WHERE catalog_product_id = $1', [catalogId])).rows[0].n).toBe(2);
      await ownerPool.query('UPDATE catalog_product_image SET deleted_at = now() WHERE id = $1', [rows[1].id]);
      expect(await content(rows[1].id, 'thumb')).toBeUndefined();
      await client.query('SAVEPOINT s');
      await expect(client.query('SELECT app.set_catalog_product_images($1, $2::jsonb)', [key, '[]'])).rejects.toThrow(/permission denied/);
      await client.query('ROLLBACK TO s');
      await client.query(`SELECT set_config('app.user_id', '', true)`);
      expect((await client.query('SELECT * FROM app.catalog_images($1)', [[catalogId]])).rows).toEqual([]);
      expect(await content(rows[0].id, 'full')).toBeUndefined();
      expect((await client.query('SELECT 1 FROM v_catalog_product_image')).rows).toEqual([]);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });
});
