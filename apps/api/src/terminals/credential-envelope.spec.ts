import { createPrivateKey, createPublicKey, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { type CredentialEnvelope, envelopeContext, openForTerminal, sealForTerminal } from './credential-envelope.js';

const keyPair = () => {
  const seed = randomBytes(32);
  const privateKey = createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), seed]),
    format: 'der',
    type: 'pkcs8',
  });
  return { seed, publicKey: createPublicKey(privateKey).export({ format: 'jwk' }).x ?? '' };
};
const fails = (call: () => unknown) => {
  try {
    call();
  } catch {
    return true;
  }
  return false;
};

describe('entrega cifrada para o caixa', () => {
  const caixa = keyPair();
  const context = envelopeContext('terminal-1', 'cert:csc');

  it('só a chave do caixa abre, e cada entrega sai diferente', () => {
    const plain = Buffer.from('{"csc":"segredo"}');
    const first = sealForTerminal(plain, caixa.publicKey, context);
    const second = sealForTerminal(plain, caixa.publicKey, context);
    expect(first.epk).not.toBe(second.epk);
    expect(first.data).not.toContain('segredo');
    expect(openForTerminal(first, caixa.seed, context).toString()).toBe('{"csc":"segredo"}');
    expect(fails(() => openForTerminal(first, keyPair().seed, context))).toBe(true);
  });

  it('não serve para outro terminal, outra versão ou conteúdo alterado', () => {
    const envelope = sealForTerminal(Buffer.from('x'), caixa.publicKey, context);
    expect(fails(() => openForTerminal(envelope, caixa.seed, envelopeContext('terminal-2', 'cert:csc')))).toBe(true);
    expect(fails(() => openForTerminal(envelope, caixa.seed, envelopeContext('terminal-1', 'cert:outro')))).toBe(true);
    const data = Buffer.from(envelope.data, 'base64url');
    data[0] ^= 1;
    expect(fails(() => openForTerminal({ ...envelope, data: data.toString('base64url') }, caixa.seed, context))).toBe(true);
  });

  // A mesma entrega é aberta pelo PDV (apps/pdv/test/nfce_credentials_test.dart).
  it('a entrega de referência do PDV abre aqui com o mesmo formato', () => {
    const fixture = JSON.parse(readFileSync(
      join(import.meta.dirname, '..', '..', '..', 'pdv', 'test', 'fixtures', 'fiscal', 'entrega-certificado.json'),
      'utf8',
    )) as { seed: string; terminalId: string; credentialVersion: string; envelope: CredentialEnvelope };
    const plain = JSON.parse(openForTerminal(
      fixture.envelope,
      Buffer.from(fixture.seed, 'base64url'),
      envelopeContext(fixture.terminalId, fixture.credentialVersion),
    ).toString('utf8')) as Record<string, string>;
    expect(plain).toMatchObject({ credentialVersion: fixture.credentialVersion, cscId: '000001' });
    expect(plain.privateKey).toContain('BEGIN PRIVATE KEY');
  });
});
