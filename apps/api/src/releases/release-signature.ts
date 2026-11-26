import { createPublicKey, KeyObject, verify } from 'node:crypto';
import { appEnvironment } from '../config/environment.js';
import { UPDATE_PUBLIC_KEYS } from './update-keys.js';

export interface ReleaseManifest {
  app: string;
  platform: string;
  version: string;
  sha256: string;
  size: number;
}

/** Texto assinado (o mesmo de scripts/release/release-format.mjs e do PDV). */
export function releaseMessage(manifest: ReleaseManifest): Buffer {
  const { app, platform, version, sha256, size } = manifest;
  return Buffer.from(`farmaerp-release-v1\n${app}\n${platform}\n${version}\n${sha256}\n${size}`, 'utf8');
}

const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function publicKey(rawBase64: string): KeyObject | null {
  const raw = Buffer.from(rawBase64, 'base64');
  if (raw.length !== 32) return null;
  return createPublicKey({ key: Buffer.concat([SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
}

/**
 * Chaves aceitas: as de update-keys.json e, fora da produção, a de teste (UPDATE_TEST_PUBLIC_KEY),
 * usada pelos testes automáticos. Em produção a de teste é ignorada.
 */
export function acceptedKeys(env: NodeJS.ProcessEnv = process.env): string[] {
  const keys = [...UPDATE_PUBLIC_KEYS];
  if (appEnvironment(env) !== 'production' && env.UPDATE_TEST_PUBLIC_KEY) keys.push(env.UPDATE_TEST_PUBLIC_KEY);
  return keys;
}

export function verifyRelease(manifest: ReleaseManifest, signature: string, keys: string[] = acceptedKeys()): boolean {
  const signatureBytes = Buffer.from(signature, 'base64');
  if (signatureBytes.length !== 64) return false;
  return keys.some((raw) => {
    const key = publicKey(raw);
    return key !== null && verify(null, releaseMessage(manifest), key, signatureBytes);
  });
}
