// Imagens do Catálogo: preparo (converte para WebP com a sharp) e conferência do que vai para o
// banco. O preparo só roda onde as dependências de desenvolvimento estão instaladas; a importação
// de um arquivo já preparado roda em qualquer lugar, inclusive no servidor.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';

export const MAX_SOURCE_BYTES = 5 * 1024 * 1024;
export const MAX_IMAGES = 20;
const FULL_SIZE = 800;
const THUMB_SIZE = 200;
const MAX_FULL_BYTES = 1024 * 1024;
const MAX_THUMB_BYTES = 256 * 1024;

/** Formato pelos primeiros bytes, e não pela extensão. */
export function sourceFormat(buffer) {
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'jpeg';
  if (buffer.length >= 8 && buffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'png';
  if (isWebp(buffer)) return 'webp';
  return null;
}

function isWebp(buffer) {
  return buffer.length >= 16 && buffer.toString('ascii', 0, 4) === 'RIFF' && buffer.toString('ascii', 8, 12) === 'WEBP';
}

/** Largura e altura lidas do cabeçalho do WebP (VP8, VP8L ou VP8X). */
export function webpSize(buffer) {
  if (!isWebp(buffer) || buffer.length < 30) return null;
  const chunk = buffer.toString('ascii', 12, 16);
  if (chunk === 'VP8 ') {
    if (buffer[23] !== 0x9d || buffer[24] !== 0x01 || buffer[25] !== 0x2a) return null;
    return { width: buffer.readUInt16LE(26) & 0x3fff, height: buffer.readUInt16LE(28) & 0x3fff };
  }
  if (chunk === 'VP8L') {
    if (buffer[20] !== 0x2f) return null;
    const bits = buffer.readUInt32LE(21);
    return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 };
  }
  if (chunk === 'VP8X') {
    return { width: buffer.readUIntLE(24, 3) + 1, height: buffer.readUIntLE(27, 3) + 1 };
  }
  return null;
}

async function loadSharp() {
  try {
    return (await import('sharp')).default;
  } catch {
    throw new Error(
      'As imagens deste arquivo ainda não foram preparadas, e a sharp não está instalada aqui. ' +
        'Prepare o arquivo onde o projeto está completo (npm run catalog:prepare-images) e importe o resultado.',
    );
  }
}

/**
 * Converte as imagens de um item ({ file, main }) para o formato que vai ao banco: WebP de até
 * 800 px e de até 200 px, sem metadados, com o SHA-256 do arquivo original para a importação
 * reconhecer a mesma imagem.
 */
export async function prepareItemImages(images, baseDir, sharp) {
  if (!Array.isArray(images) || images.length > MAX_IMAGES) {
    throw new Error(`A lista de imagens precisa ter até ${MAX_IMAGES} arquivos.`);
  }
  const prepared = [];
  for (const image of images) {
    if (image && typeof image.full === 'string') {
      prepared.push(image);
      continue;
    }
    if (!image || typeof image.file !== 'string' || image.file.trim() === '') {
      throw new Error('Imagem sem o campo "file".');
    }
    const path = isAbsolute(image.file) ? image.file : join(baseDir, image.file);
    const source = await readFile(path);
    if (source.length > MAX_SOURCE_BYTES) throw new Error(`${image.file}: passa de 5 MB.`);
    if (!sourceFormat(source)) throw new Error(`${image.file}: não é JPEG, PNG nem WebP.`);
    const pipeline = () => sharp(source, { limitInputPixels: 50_000_000 }).rotate();
    const full = await pipeline()
      .resize({ width: FULL_SIZE, height: FULL_SIZE, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 82 })
      .toBuffer({ resolveWithObject: true });
    const thumb = await pipeline()
      .resize({ width: THUMB_SIZE, height: THUMB_SIZE, fit: 'inside', withoutEnlargement: true })
      .webp({ quality: 78 })
      .toBuffer();
    prepared.push({
      sha256: createHash('sha256').update(source).digest('hex'),
      width: full.info.width,
      height: full.info.height,
      full: full.data.toString('base64'),
      thumb: thumb.toString('base64'),
      ...(image.main ? { main: true } : {}),
    });
  }
  return prepared;
}

/** Prepara todas as imagens de uma lista de itens que ainda trazem arquivos. */
export async function prepareCatalogImages(items, baseDir) {
  const needs = items.some((item) => Array.isArray(item?.images) && item.images.some((image) => typeof image?.full !== 'string'));
  if (!needs) return items;
  const sharp = await loadSharp();
  const result = [];
  for (const [index, item] of items.entries()) {
    if (!Array.isArray(item?.images)) {
      result.push(item);
      continue;
    }
    try {
      result.push({ ...item, images: await prepareItemImages(item.images, baseDir, sharp) });
    } catch (error) {
      throw new Error(`Item ${index + 1} (${item?.sourceKey ?? 'sem sourceKey'}): ${error.message}`, { cause: error });
    }
  }
  return result;
}

/** Confere a imagem já preparada antes de mandar ao banco. */
export function checkPreparedImage(image) {
  const fail = (reason) => {
    throw new Error(`Imagem inválida: ${reason}.`);
  };
  if (!image || typeof image !== 'object') fail('formato');
  if (typeof image.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(image.sha256)) fail('SHA-256');
  const full = Buffer.from(String(image.full ?? ''), 'base64');
  const thumb = Buffer.from(String(image.thumb ?? ''), 'base64');
  if (full.length > MAX_FULL_BYTES || thumb.length > MAX_THUMB_BYTES) fail('tamanho do arquivo');
  const fullSize = webpSize(full);
  const thumbSize = webpSize(thumb);
  if (!fullSize || !thumbSize) fail('não é WebP');
  if (fullSize.width > FULL_SIZE || fullSize.height > FULL_SIZE) fail('versão grande acima de 800 px');
  if (thumbSize.width > THUMB_SIZE || thumbSize.height > THUMB_SIZE) fail('miniatura acima de 200 px');
  if (fullSize.width !== image.width || fullSize.height !== image.height) fail('dimensões não batem com o arquivo');
}
