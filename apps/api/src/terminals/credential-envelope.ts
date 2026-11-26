import {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  type KeyObject,
} from 'node:crypto';

/**
 * Envelope cifrado para um único caixa: X25519 (chave temporária da central com a chave do
 * caixa), HKDF-SHA256 e AES-256-GCM. Só quem tem a chave privada do caixa abre; o contexto
 * (terminal e versão do certificado) vai autenticado, então o envelope de um caixa ou de uma
 * versão não serve para outro.
 */
export const ENVELOPE_VERSION = 1;
const INFO = 'farmaerp-nfce-credentials-v1';
const NONCE_BYTES = 12;
const TAG_BYTES = 16;

export interface CredentialEnvelope {
  v: number;
  /** Chave pública temporária da central (base64url, 32 bytes). */
  epk: string;
  nonce: string;
  /** Conteúdo cifrado seguido da tag do GCM (base64url). */
  data: string;
}

/** Texto autenticado junto: o PDV monta igual com o que sabe de si. */
export const envelopeContext = (terminalId: string, credentialVersion: string) =>
  `${INFO}\n${terminalId}\n${credentialVersion}`;

const x25519Public = (raw: string): KeyObject =>
  createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: raw }, format: 'jwk' });

const rawPublic = (key: KeyObject): Buffer => Buffer.from(key.export({ format: 'jwk' }).x ?? '', 'base64url');

function derive(shared: Buffer, ephemeral: Buffer, recipient: Buffer): Buffer {
  return Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeral, recipient]), INFO, 32));
}

export function sealForTerminal(plain: Buffer, terminalKey: string, context: string): CredentialEnvelope {
  const recipient = x25519Public(terminalKey);
  const ephemeral = generateKeyPairSync('x25519');
  const shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: recipient });
  const epk = rawPublic(ephemeral.publicKey);
  const key = derive(shared, epk, Buffer.from(terminalKey, 'base64url'));
  const nonce = randomBytes(NONCE_BYTES);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.from(context, 'utf8'));
  const data = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
  return {
    v: ENVELOPE_VERSION,
    epk: epk.toString('base64url'),
    nonce: nonce.toString('base64url'),
    data: data.toString('base64url'),
  };
}

/** Abre o envelope com a semente da chave do caixa. Usado nos testes (o caixa abre em Dart). */
export function openForTerminal(envelope: CredentialEnvelope, seed: Buffer, context: string): Buffer {
  const privateKey = createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), seed]),
    format: 'der',
    type: 'pkcs8',
  });
  const own = rawPublic(createPublicKey(privateKey));
  const epk = Buffer.from(envelope.epk, 'base64url');
  const shared = diffieHellman({ privateKey, publicKey: x25519Public(envelope.epk) });
  const data = Buffer.from(envelope.data, 'base64url');
  const decipher = createDecipheriv('aes-256-gcm', derive(shared, epk, own), Buffer.from(envelope.nonce, 'base64url'), {
    authTagLength: TAG_BYTES,
  });
  decipher.setAAD(Buffer.from(context, 'utf8'));
  decipher.setAuthTag(data.subarray(data.length - TAG_BYTES));
  return Buffer.concat([decipher.update(data.subarray(0, data.length - TAG_BYTES)), decipher.final()]);
}
