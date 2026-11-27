import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { buildDanfe, buildNfe } from '../index.js';

// Certificado e chave só de teste (autoassinado, sem dados de ninguém), os mesmos do PDV.
const fixtures = new URL('../../../apps/pdv/test/fixtures/fiscal/', import.meta.url);
const key = readFileSync(new URL('test-key.pem', fixtures), 'utf8');
const cert = readFileSync(new URL('test-cert.pem', fixtures), 'utf8');

const devolution = {
  issuer: {
    cnpj: '11222333000181', stateRegistration: '110042490114', legalName: 'FARMACIA DEMONSTRACAO LTDA', tradeName: 'Farmácia Demonstração',
    street: 'Rua das Flores & Cia', number: '100', district: 'Centro', cityCode: '3550308', city: 'São Paulo', uf: 'SP',
    postalCode: '01001000', phone: '(11) 3333-4444', taxRegime: 1,
  },
  recipient: {
    cnpj: '44555666000199', name: 'DISTRIBUIDORA FORNECEDORA LTDA', ieIndicator: 1, stateRegistration: '9012345678',
    street: 'Rua XV de Novembro', number: '50', district: 'Centro', cityCode: '4106902', city: 'Curitiba', uf: 'PR', postalCode: '80020310',
  },
  items: [{
    code: '1', gtin: '7890000000017', description: 'Dipirona Sódica 500 mg', ncm: '30049099', cest: '1300100', unit: 'CX',
    quantityMilli: 2000, unitPriceCents: 1000, grossCents: 2000, discountCents: 100, freightCents: 50, insuranceCents: 20,
    otherCents: 30, ipiReturnedCents: 120, returnPercent: 50,
    tax: { cfop: '6202', origin: 0, icms_csosn: '500', pis_cst: '04', cofins_cst: '04' },
  }],
  series: 1, number: 78, emittedAt: '2026-11-27T16:00:00Z', environment: 2, numericCode: '11223344', appVersion: '0.3.0',
  operation: 'DEVOLUCAO DE COMPRA', purpose: 4, presence: 0, references: ['41261144555666000199550010000012341000012345'],
};

describe('motor fiscal em JavaScript (o mesmo do PDV)', () => {
  it('monta e assina a NF-e 55 de devolução', () => {
    const nfe = buildNfe(devolution, key, cert);
    expect(nfe.error).toBeUndefined();
    expect(nfe.accessKey).toMatch(/^35\d{4}11222333000181550010000000781\d{9}$/);
    expect(nfe.totalCents).toBe(2120);
    expect(nfe.xml).toContain('<mod>55</mod>');
    expect(nfe.xml).toContain('<finNFe>4</finNFe>');
    expect(nfe.xml).toContain('<refNFe>41261144555666000199550010000012341000012345</refNFe>');
    expect(nfe.xml).toContain('<vNF>21.20</vNF>');
    expect(nfe.xml).toContain('<Signature xmlns="http://www.w3.org/2000/09/xmldsig#">');
    // O mesmo dado dá a mesma nota (assinatura RSA determinística).
    expect(buildNfe(devolution, key, cert).xml).toBe(nfe.xml);
  });

  it('recusa com o código do catálogo; dado fora do formato também vira código', () => {
    expect(buildNfe({ ...devolution, references: [] }, key, cert).error).toEqual({ code: 'FA726', detail: 'Devolução sem a nota referenciada.' });
    expect(buildNfe({ ...devolution, items: [{ ...devolution.items[0], tax: { ...devolution.items[0].tax, cfop: '5202' } }] }, key, cert).error.code).toBe('FA723');
    expect(buildNfe({ issuer: {} }, key, cert).error.code).toBe('FA726');
  });

  it('gera o DANFE A4 em PDF', async () => {
    const pdf = await buildDanfe(buildNfe(devolution, key, cert).xml);
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    expect(pdf.length).toBeGreaterThan(3000);
  });

  it('roda isolado: não deixa nada nos globais da API', () => {
    buildNfe(devolution, key, cert);
    expect(globalThis.farmaerpFiscal).toBeUndefined();
    expect(globalThis.self).toBeUndefined();
  });
});
