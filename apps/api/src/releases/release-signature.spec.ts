import { generateKeyPairSync, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { acceptedKeys, releaseMessage, verifyRelease } from './release-signature.js';
import { UPDATE_PUBLIC_KEYS } from './update-keys.js';

const manifest = { app: 'pdv', platform: 'windows', version: '1.2.3', sha256: 'a'.repeat(64), size: 1234 };

function keyPair() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
  return { raw, signWith: (data: typeof manifest) => sign(null, releaseMessage(data), privateKey).toString('base64') };
}

describe('assinatura das versões', () => {
  it('as chaves da API são as de scripts/release/update-keys.json', () => {
    const file = JSON.parse(readFileSync(join(import.meta.dirname, '..', '..', '..', '..', 'scripts', 'release', 'update-keys.json'), 'utf8'));
    expect([...UPDATE_PUBLIC_KEYS]).toEqual(file.keys);
  });

  it('aceita a assinatura certa e recusa qualquer mudança', () => {
    const { raw, signWith } = keyPair();
    const signature = signWith(manifest);
    expect(verifyRelease(manifest, signature, [raw])).toBe(true);
    expect(verifyRelease({ ...manifest, version: '1.2.4' }, signature, [raw])).toBe(false);
    expect(verifyRelease({ ...manifest, size: 1235 }, signature, [raw])).toBe(false);
    expect(verifyRelease({ ...manifest, sha256: 'b'.repeat(64) }, signature, [raw])).toBe(false);
    expect(verifyRelease(manifest, signature, [keyPair().raw])).toBe(false);
    expect(verifyRelease(manifest, 'curta', [raw])).toBe(false);
    expect(verifyRelease(manifest, signature, ['não é chave'])).toBe(false);
  });

  it('a chave de teste só vale fora da produção', () => {
    const { raw } = keyPair();
    expect(acceptedKeys({ APP_ENV: 'development', UPDATE_TEST_PUBLIC_KEY: raw })).toContain(raw);
    expect(acceptedKeys({ APP_ENV: 'homologation', UPDATE_TEST_PUBLIC_KEY: raw })).toContain(raw);
    expect(acceptedKeys({ APP_ENV: 'production', UPDATE_TEST_PUBLIC_KEY: raw })).not.toContain(raw);
  });
});
