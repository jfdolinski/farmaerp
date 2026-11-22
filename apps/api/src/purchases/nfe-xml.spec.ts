import { accessKey, buildNfe, testCnpj } from '../../test/nfe-fixture.js';
import { InvalidNfeError, isValidAccessKey, readAuthorizedNfe } from './nfe-xml.js';

const refusal = (xml: string) => {
  try {
    readAuthorizedNfe(xml);
  } catch (error) {
    expect(error).toBeInstanceOf(InvalidNfeError);
    expect((error as InvalidNfeError).code).toBe('FA930');
    return (error as InvalidNfeError).reason;
  }
  throw new Error('a nota foi aceita');
};

describe('chave de acesso', () => {
  it('confere o dígito, inclusive com CNPJ alfanumérico', () => {
    const numeric = accessKey({ uf: '35', yymm: '2611', cnpj: testCnpj(), series: 1, number: 123, code: '12345678' });
    expect(isValidAccessKey(numeric)).toBe(true);
    const wrong = numeric.slice(0, 43) + String((Number(numeric[43]) + 1) % 10);
    expect(isValidAccessKey(wrong)).toBe(false);
    const alpha = accessKey({ uf: '35', yymm: '2611', cnpj: 'AB1C2D3E000171', series: 1, number: 1, code: '12345678' });
    expect(isValidAccessKey(alpha)).toBe(true);
    expect(isValidAccessKey(alpha.toLowerCase())).toBe(false);
    expect(isValidAccessKey(numeric.slice(1))).toBe(false);
  });
});

describe('nota autorizada', () => {
  it('lê os dados da nota, do protocolo e dos itens, com lote, Anvisa e PMC', () => {
    const { xml, key, emitterCnpj, destCnpj, number } = buildNfe({
      environment: 1,
      items: [
        { code: '0001', ean: '7891234567895', quantity: '3.0000', unitPrice: '12.3456789000', value: '37.04', st: '1.50',
          batches: [{ number: 'L1', quantity: '2.000', manufacturedOn: '2026-01-01', expiresOn: '2028-01-01' }, { number: 'L2', quantity: '1.000', expiresOn: '2028-06-01' }],
          anvisa: '1234567890123', pmc: '25.90' },
        { code: '0002' },
      ],
    });
    const data = readAuthorizedNfe(xml);
    expect(data).toMatchObject({
      accessKey: key, number, series: 1, environment: 1, purpose: 1, operationType: 1, destCnpj,
      protocolNumber: '135260000000001', issuedAt: '2026-11-20T10:00:00-03:00',
      emitter: { cnpj: emitterCnpj, legalName: 'DISTRIBUIDORA TESTE LTDA', state: 'SP', stateRegistration: '110042490114' },
      totals: { products: '58.04', invoice: '58.04', discount: '0.00' },
    });
    expect(data.items[0]).toMatchObject({
      number: 1, supplierCode: '0001', barcode: '7891234567895', quantity: '3.0000', unitPrice: '12.3456789000',
      productsValue: '37.04', st: '1.50', anvisaCode: '1234567890123', pmc: '25.90',
      batches: [
        { number: 'L1', quantity: '2.000', manufacturedOn: '2026-01-01', expiresOn: '2028-01-01' },
        { number: 'L2', quantity: '1.000', manufacturedOn: null, expiresOn: '2028-06-01' },
      ],
    });
    expect(data.items[1]).toMatchObject({ number: 2, supplierCode: '0002', barcode: null, batches: [], anvisaCode: null, pmc: null });
  });

  it('aceita autorizada fora do prazo (150)', () => {
    expect(readAuthorizedNfe(buildNfe({ status: '150' }).xml).accessKey).toHaveLength(44);
  });
});

describe('recusas', () => {
  it('conteúdo alterado depois da assinatura', () => {
    expect(refusal(buildNfe({ afterSign: (xml) => xml.replace('<qCom>2.0000</qCom>', '<qCom>20.0000</qCom>') }).xml)).toMatch(/assinatura/);
  });

  it('assinatura trocada', () => {
    expect(refusal(buildNfe({ afterSign: (xml) => xml.replace(/<SignatureValue>[^<]{10}/, '<SignatureValue>AAAAAAAAAA') }).xml)).toMatch(/assinatura/);
  });

  it('certificado ilegível no KeyInfo', () => {
    const other = buildNfe();
    const otherCert = /<X509Certificate>([^<]+)<\/X509Certificate>/.exec(other.xml)?.[1] ?? '';
    // Mesmo par de chaves no teste: troca por um certificado ilegível para provar que ele é lido.
    expect(otherCert).not.toBe('');
    expect(refusal(buildNfe({ afterSign: (xml) => xml.replace(/<X509Certificate>[^<]+<\/X509Certificate>/, '<X509Certificate>QUJD</X509Certificate>') }).xml)).toMatch(/certificado/);
  });

  it('bloco falso com o mesmo Id fora da parte assinada', () => {
    const { xml } = buildNfe();
    const id = /Id="(NFe\d+)"/.exec(xml)?.[1] ?? '';
    const injected = xml.replace('</nfeProc>', `<extra><infNFe Id="${id}"><ide><nNF>1</nNF></ide></infNFe></extra></nfeProc>`);
    expect(refusal(injected)).toMatch(/Id repetido/);
  });

  it('segunda NFe dentro do nfeProc', () => {
    const { xml } = buildNfe();
    const nfe = /<NFe[\s\S]*<\/NFe>/.exec(xml)?.[0] ?? '';
    expect(refusal(xml.replace('</NFe>', `</NFe>${nfe}`))).toMatch(/NFe: 2|Id repetido/);
  });

  it('referência que não aponta para a nota', () => {
    expect(refusal(buildNfe({ afterSign: (xml) => xml.replace(/URI="#NFe\d+"/, 'URI=""') }).xml)).toMatch(/referência/);
  });

  it('protocolo de outro conteúdo ou de outra nota', () => {
    expect(refusal(buildNfe({ protocolDigest: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=' }).xml)).toMatch(/outro conteúdo/);
    const otherKey = accessKey({ uf: '35', yymm: '2611', cnpj: testCnpj(), series: 1, number: 9, code: '12345678' });
    expect(refusal(buildNfe({ protocolKey: otherKey }).xml)).toMatch(/outra nota/);
  });

  it('nota não autorizada', () => {
    expect(refusal(buildNfe({ status: '110' }).xml)).toMatch(/não autorizada/);
  });

  it('chave que não bate com os dados assinados', () => {
    // Número da nota trocado antes de assinar: assinatura válida, mas a chave é de outra nota.
    expect(refusal(buildNfe({ beforeSign: (xml) => xml.replace(/<nNF>\d+<\/nNF>/, '<nNF>1</nNF>') }).xml)).toMatch(/chave não bate/);
  });

  it('DOCTYPE e entidades', () => {
    const { xml } = buildNfe();
    const withDoctype = xml.replace('<nfeProc', '<!DOCTYPE nfeProc [<!ENTITY x "y">]><nfeProc');
    expect(refusal(withDoctype)).toMatch(/DOCTYPE/);
  });

  it('XML malformado, raiz errada e arquivo grande', () => {
    expect(refusal('<nfeProc><NFe>')).toMatch(/malformado|raiz/);
    expect(refusal('<?xml version="1.0"?><outra xmlns="http://www.portalfiscal.inf.br/nfe"/>')).toMatch(/raiz/);
    expect(refusal(`<x>${'a'.repeat(5 * 1024 * 1024)}</x>`)).toMatch(/grande/);
  });

  it('nota sem protocolo', () => {
    const { xml } = buildNfe();
    expect(refusal(xml.replace(/<protNFe[\s\S]*<\/protNFe>/, ''))).toMatch(/protNFe/);
  });

  it('valores fora do formato', () => {
    expect(refusal(buildNfe({ items: [{ quantity: '2,0000' }] }).xml)).toMatch(/qCom/);
  });

  it('emitente sem CNPJ', () => {
    const { xml } = buildNfe({ beforeSign: (inf) => inf.replace(/<emit><CNPJ>\d+<\/CNPJ>/, '<emit><CPF>12345678909</CPF>') });
    expect(refusal(xml)).toMatch(/CNPJ|chave/);
  });
});
