// Formato da assinatura das versões, o mesmo na API (release-signature.ts) e no PDV
// (update_signature.dart). Mudar aqui exige mudar lá, e o PDV antigo deixa de aceitar.
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';

/** Texto assinado: app, sistema, versão, resumo e tamanho do arquivo. */
export function releaseMessage({ app, platform, version, sha256, size }) {
  return Buffer.from(`farmaerp-release-v1\n${app}\n${platform}\n${version}\n${sha256}\n${size}`, 'utf8');
}

export async function fileDigest(path) {
  const hash = createHash('sha256');
  await new Promise((resolve, reject) => {
    createReadStream(path).on('data', (chunk) => hash.update(chunk)).on('end', resolve).on('error', reject);
  });
  return { sha256: hash.digest('hex'), size: (await stat(path)).size };
}

/** Chave privada em base64 (PKCS#8 DER), como fica no segredo do GitHub. */
export function signRelease(manifest, privateKeyBase64) {
  const key = createPrivateKey({ key: Buffer.from(privateKeyBase64, 'base64'), format: 'der', type: 'pkcs8' });
  return sign(null, releaseMessage(manifest), key).toString('base64');
}

/** Chave pública em base64 dos 32 bytes (o que vai em update-keys.json). */
export function publicKeyFromRaw(rawBase64) {
  const prefix = Buffer.from('302a300506032b6570032100', 'hex');
  return createPublicKey({ key: Buffer.concat([prefix, Buffer.from(rawBase64, 'base64')]), format: 'der', type: 'spki' });
}

export function verifyRelease(manifest, signature, rawPublicKeys) {
  return rawPublicKeys.some((raw) => verify(null, releaseMessage(manifest), publicKeyFromRaw(raw), Buffer.from(signature, 'base64')));
}
