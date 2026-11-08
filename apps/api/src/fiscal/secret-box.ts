import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { AppError } from '../observability/app-error.js';

const VERSION = 1;
const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = 1 + IV_BYTES + TAG_BYTES;

/**
 * Chave de 32 bytes em base64. Lida a cada uso, para a falta dela não impedir a API de subir:
 * só as operações de certificado e CSC ficam indisponíveis (FA915). O valor nunca vai para o log.
 */
function encryptionKey(): Buffer {
  const key = Buffer.from(process.env.FISCAL_ENCRYPTION_KEY ?? '', 'base64');
  if (key.length !== KEY_BYTES) {
    throw new AppError('FA915');
  }
  return key;
}

/**
 * AES-256-GCM com o contexto autenticado: o conteúdo de uma empresa ou filial, copiado para
 * outra linha do banco, não abre.
 * Formato: versão (1 byte) + IV (12) + tag (16) + conteúdo.
 */
export function seal(plain: Buffer, context: string): Buffer {
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv('aes-256-gcm', encryptionKey(), iv);
  cipher.setAAD(Buffer.from(context, 'utf8'));
  const content = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([Buffer.from([VERSION]), iv, cipher.getAuthTag(), content]);
}

export function open(sealed: Buffer, context: string): Buffer {
  if (sealed.length < HEADER_BYTES || sealed[0] !== VERSION) {
    throw new AppError('FA915');
  }
  const decipher = createDecipheriv(
    'aes-256-gcm',
    encryptionKey(),
    sealed.subarray(1, 1 + IV_BYTES),
    { authTagLength: TAG_BYTES },
  );
  decipher.setAAD(Buffer.from(context, 'utf8'));
  decipher.setAuthTag(sealed.subarray(1 + IV_BYTES, HEADER_BYTES));
  try {
    return Buffer.concat([decipher.update(sealed.subarray(HEADER_BYTES)), decipher.final()]);
  } catch (cause) {
    throw new AppError('FA915', { cause });
  }
}
