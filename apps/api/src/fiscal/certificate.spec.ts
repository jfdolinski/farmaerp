import { readCertificate } from './certificate.js';
import { buildPfx } from '../../test/fiscal-pfx.js';

const code = (call: () => unknown) => {
  try {
    call();
  } catch (error) {
    return (error as { code?: string }).code;
  }
  return null;
};

describe('leitura do certificado A1', () => {
  it('lê titular, CNPJ do nome, validade e impressão digital', () => {
    const info = readCertificate(buildPfx(), 'senha-do-teste');
    expect(info.subjectName).toBe('EMPRESA TESTE:11222333000181');
    expect(info.cnpj).toBe('11222333000181');
    expect(new Date(info.validTo).getTime()).toBeGreaterThan(Date.now());
    expect(info.fingerprint).toMatch(/^[0-9a-f]{64}$/);
  });

  it('abre arquivo protegido com AES-256', () => {
    const pfx = buildPfx({ algorithm: 'aes256' });
    expect(readCertificate(pfx, 'senha-do-teste').cnpj).toBe('11222333000181');
  });

  it('lê o CNPJ do OID da ICP-Brasil quando o nome não traz', () => {
    const pfx = buildPfx({ commonName: 'EMPRESA TESTE', sanCnpj: '11222333000181' });
    expect(readCertificate(pfx, 'senha-do-teste').cnpj).toBe('11222333000181');
  });

  it('senha errada e arquivo que não é certificado dão FA912', () => {
    expect(code(() => readCertificate(buildPfx(), 'errada'))).toBe('FA912');
    expect(code(() => readCertificate(Buffer.from('não é certificado'), 'x'))).toBe('FA912');
  });

  it('certificado sem CNPJ dá FA913', () => {
    expect(code(() => readCertificate(buildPfx({ commonName: 'PESSOA FÍSICA' }), 'senha-do-teste'))).toBe('FA913');
  });
});
