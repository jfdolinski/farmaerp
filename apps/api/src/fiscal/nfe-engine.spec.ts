import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';
import { join } from 'node:path';
import { buildNfe, type NfeInput } from '@farmaerp/fiscal-js';
import { SignedXml } from 'xml-crypto';
import { describe, expect, it } from 'vitest';

// A central emite a NF-e 55 com o motor do PDV compilado para JavaScript (@farmaerp/fiscal-js). Aqui a
// xml-crypto confere, de forma independente, a assinatura que esse motor faz dentro da API.
const fixtures = join(import.meta.dirname, '..', '..', '..', 'pdv', 'test', 'fixtures', 'fiscal');
const key = readFileSync(join(fixtures, 'test-key.pem'), 'utf8');
const cert = readFileSync(join(fixtures, 'test-cert.pem'), 'utf8');

const input: NfeInput = {
  issuer: {
    cnpj: '11222333000181', stateRegistration: '110042490114', legalName: 'FARMACIA DEMONSTRACAO LTDA',
    street: 'Rua das Flores', number: '100', district: 'Centro', cityCode: '3550308', city: 'São Paulo', uf: 'SP',
    postalCode: '01001000', taxRegime: 1,
  },
  recipient: {
    cnpj: '44555666000199', name: 'DISTRIBUIDORA FORNECEDORA LTDA', ieIndicator: 1, stateRegistration: '9012345678',
    street: 'Rua XV de Novembro', number: '50', district: 'Centro', cityCode: '4106902', city: 'Curitiba', uf: 'PR', postalCode: '80020310',
  },
  items: [{
    code: '1', description: 'Dipirona Sódica 500 mg', ncm: '30049099', unit: 'CX', quantityMilli: 1000, unitPriceCents: 1000,
    grossCents: 1000, tax: { cfop: '6202', origin: 0, icms_csosn: '500', pis_cst: '04', cofins_cst: '04' },
  }],
  series: 1, number: 5, emittedAt: '2026-11-27T16:00:00Z', environment: 2, numericCode: '11223344', appVersion: 'central',
  operation: 'DEVOLUCAO DE COMPRA', purpose: 4, presence: 0, references: ['41261144555666000199550010000012341000012345'],
};

function signatureOf(xml: string) {
  const certificate = /<X509Certificate>([^<]+)<\/X509Certificate>/.exec(xml)?.[1] ?? '';
  const verifier = new SignedXml({ publicCert: new X509Certificate(Buffer.from(certificate, 'base64')).toString() });
  verifier.loadSignature(xml.slice(xml.indexOf('<Signature '), xml.indexOf('</Signature>') + '</Signature>'.length));
  return verifier;
}

describe('NF-e 55 montada na central com o motor do PDV', () => {
  it('a xml-crypto confere a assinatura; mexer no conteúdo invalida', () => {
    const nfe = buildNfe(input, key, cert);
    if (nfe.error) throw new Error(nfe.error.detail);
    expect(signatureOf(nfe.xml).checkSignature(nfe.xml)).toBe(true);
    const tampered = nfe.xml.replace('<vNF>10.00</vNF>', '<vNF>1.00</vNF>');
    expect(tampered).not.toBe(nfe.xml);
    let valid: boolean;
    try {
      valid = signatureOf(tampered).checkSignature(tampered);
    } catch {
      valid = false;
    }
    expect(valid).toBe(false);
  });
});
