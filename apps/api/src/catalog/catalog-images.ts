import { createHash } from 'node:crypto';
import sharp from 'sharp';

/** Imagem no formato que o banco guarda (o mesmo da importação do Catálogo). */
export interface PreparedImage {
  sha256: string;
  width: number;
  height: number;
  full: string;
  thumb: string;
  main?: true;
}

const FULL_SIZE = 800;
const THUMB_SIZE = 200;

/**
 * Converte uma imagem do Catálogo em WebP de até 800 px e de até 200 px, sem metadados. O SHA-256 é
 * do arquivo original, para a mesma imagem não entrar duas vezes.
 */
export async function prepareImage(source: Buffer, main: boolean): Promise<PreparedImage> {
  const pipeline = () => sharp(source, { limitInputPixels: 50_000_000 }).rotate();
  const full = await pipeline()
    .resize({ width: FULL_SIZE, height: FULL_SIZE, fit: 'inside', withoutEnlargement: true })
    .webp({ quality: 82 })
    .toBuffer({ resolveWithObject: true });
  const thumb = await pipeline()
    .resize({ width: THUMB_SIZE, height: THUMB_SIZE, fit: 'inside', withoutEnlargement: true })
    .webp({ quality: 78 })
    .toBuffer();
  return {
    sha256: createHash('sha256').update(source).digest('hex'),
    width: full.info.width,
    height: full.info.height,
    full: full.data.toString('base64'),
    thumb: thumb.toString('base64'),
    ...(main ? { main: true as const } : {}),
  };
}
