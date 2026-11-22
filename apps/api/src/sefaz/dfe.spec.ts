import { X509Certificate } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { SignedXml } from 'xml-crypto';
import { buildPfx } from '../../test/fiscal-pfx.js';
import { buildNfe } from '../../test/nfe-fixture.js';
import { AppError } from '../observability/app-error.js';
import {
  awarenessEnvelope,
  brasiliaNow,
  distributionEnvelope,
  parseDistribution,
  parseEventResponse,
  pemFromPfx,
  readEvent,
  readSummary,
} from './dfe.js';

const KEY = buildNfe({ destCnpj: '11222333000181' }).key;
const zip = (xml: string) => gzipSync(Buffer.from(xml, 'utf8')).toString('base64');
const summaryXml = (overrides: Record<string, string> = {}) => {
  const fields = {
    chNFe: KEY, CNPJ: '11444777000161', xNome: 'DISTRIBUIDORA RESUMO LTDA', IE: '110042490114', dhEmi: '2026-11-20T10:00:00-03:00',
    tpNF: '1', vNF: '150.75', digVal: 'abcdefghijklmnopqrstuvwxyz0=', dhRecbto: '2026-11-20T10:00:05-03:00', nProt: '135260000000001',
    cSitNFe: '1', ...overrides,
  };
  return `<resNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01">${Object.entries(fields).map(([k, v]) => `<${k}>${v}</${k}>`).join('')}</resNFe>`;
};
const distResponse = (body: string) =>
  `<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body>` +
  `<nfeDistDFeInteresseResponse xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe"><nfeDistDFeInteresseResult>` +
  `<retDistDFeInt xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01">${body}</retDistDFeInt>` +
  `</nfeDistDFeInteresseResult></nfeDistDFeInteresseResponse></soap:Body></soap:Envelope>`;
const expectCode = (fn: () => unknown, code: string) => {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe(code);
    return;
  }
  throw new Error('deveria ter falhado');
};

describe('pedido à distribuição', () => {
  it('pelo NSU, com zeros à esquerda, e pela chave', () => {
    const byNsu = distributionEnvelope({ environment: 2, ufCode: '35', cnpj: '11222333000181', lastNsu: '42' });
    expect(byNsu).toContain('<distDFeInt xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><tpAmb>2</tpAmb><cUFAutor>35</cUFAutor><CNPJ>11222333000181</CNPJ><distNSU><ultNSU>000000000000042</ultNSU></distNSU>');
    const byKey = distributionEnvelope({ environment: 1, ufCode: '41', cnpj: '11222333000181', accessKey: KEY });
    expect(byKey).toContain(`<consChNFe><chNFe>${KEY}</chNFe></consChNFe>`);
    expect(byKey).not.toContain('distNSU');
  });
});

describe('resposta da distribuição', () => {
  it('abre os documentos e separa os que não abrem', () => {
    const huge = gzipSync(Buffer.alloc(6 * 1024 * 1024, 32)).toString('base64');
    const parsed = parseDistribution(distResponse(
      '<tpAmb>2</tpAmb><cStat>138</cStat><xMotivo>Documento localizado</xMotivo><ultNSU>000000000000003</ultNSU><maxNSU>000000000000009</maxNSU>' +
      `<loteDistDFeInt><docZip NSU="000000000000001" schema="resNFe_v1.01">${zip(summaryXml())}</docZip>` +
      `<docZip NSU="000000000000002" schema="resNFe_v1.01">não é gzip</docZip>` +
      `<docZip NSU="000000000000003" schema="procNFe_v4.00">${huge}</docZip>` +
      `<docZip NSU="1" schema="resNFe_v1.01">${zip('<x/>')}</docZip></loteDistDFeInt>`,
    ));
    expect(parsed).toMatchObject({ status: '138', message: 'Documento localizado', lastNsu: '000000000000003', maxNsu: '000000000000009' });
    expect(parsed.documents).toEqual([{ nsu: '000000000000001', schema: 'resNFe_v1.01', xml: summaryXml() }]);
    expect(parsed.skipped.map((s) => s.nsu)).toEqual(['000000000000002', '000000000000003', '1']);
  });

  it('um documento só também é lista; sem documento, nada', () => {
    const one = parseDistribution(distResponse(`<cStat>138</cStat><ultNSU>000000000000001</ultNSU><maxNSU>000000000000001</maxNSU><loteDistDFeInt><docZip NSU="000000000000001" schema="resNFe_v1.01">${zip(summaryXml())}</docZip></loteDistDFeInt>`));
    expect(one.documents).toHaveLength(1);
    const none = parseDistribution(distResponse('<cStat>137</cStat><xMotivo>Nenhum documento localizado</xMotivo><ultNSU>000000000000009</ultNSU><maxNSU>000000000000009</maxNSU>'));
    expect(none).toMatchObject({ status: '137', documents: [], lastNsu: '000000000000009' });
  });

  it('recusa DOCTYPE e resposta sem o retorno', () => {
    expectCode(() => parseDistribution('<!DOCTYPE x [<!ENTITY a "b">]><x>&a;</x>'), 'FA944');
    expectCode(() => parseDistribution('<Envelope><Body/></Envelope>'), 'FA944');
  });
});

describe('documentos', () => {
  it('lê o resumo da nota e recusa o que não confere', () => {
    expect(readSummary(summaryXml())).toEqual({
      accessKey: KEY, emitterDocument: '11444777000161', emitterName: 'DISTRIBUIDORA RESUMO LTDA', issuedAt: '2026-11-20T10:00:00-03:00',
      operationType: 1, total: '150.75', digest: 'abcdefghijklmnopqrstuvwxyz0=', protocolNumber: '135260000000001', situation: 1,
    });
    expect(readSummary(summaryXml({ chNFe: `${KEY.slice(0, 43)}${(Number(KEY[43]) + 1) % 10}` }))).toBeNull();
    expect(readSummary(summaryXml({ cSitNFe: '4' }))).toBeNull();
    expect(readSummary(summaryXml({ digVal: 'curto=' }))).toBeNull();
    expect(readSummary(summaryXml({ vNF: '1,50' }))).toBeNull();
    expect(readSummary('<resEvento/>')).toBeNull();
  });

  it('lê o tipo do evento, resumido ou completo', () => {
    expect(readEvent(`<resEvento xmlns="http://www.portalfiscal.inf.br/nfe"><chNFe>${KEY}</chNFe><tpEvento>110111</tpEvento></resEvento>`))
      .toEqual({ accessKey: KEY, type: '110111' });
    expect(readEvent(`<procEventoNFe xmlns="http://www.portalfiscal.inf.br/nfe"><evento><infEvento><chNFe>${KEY}</chNFe><tpEvento>110110</tpEvento></infEvento></evento></procEventoNFe>`))
      .toEqual({ accessKey: KEY, type: '110110' });
    expect(readEvent('<resEvento><chNFe>123</chNFe><tpEvento>110111</tpEvento></resEvento>')).toBeNull();
  });
});

describe('ciência da operação', () => {
  const pfx = buildPfx();
  const pem = pemFromPfx(pfx, 'senha-do-teste');

  it('senha errada não abre o certificado', () => {
    expectCode(() => pemFromPfx(pfx, 'errada'), 'FA912');
  });

  it('o evento sai assinado, com o Id e os campos do leiaute', () => {
    const envelope = awarenessEnvelope({ environment: 2, cnpj: '11222333000181', accessKey: KEY, at: '2026-11-22T10:00:00-03:00' }, pem);
    expect(envelope).toContain(`<infEvento Id="ID210210${KEY}01"><cOrgao>91</cOrgao><tpAmb>2</tpAmb><CNPJ>11222333000181</CNPJ><chNFe>${KEY}</chNFe><dhEvento>2026-11-22T10:00:00-03:00</dhEvento><tpEvento>210210</tpEvento><nSeqEvento>1</nSeqEvento><verEvento>1.00</verEvento><detEvento versao="1.00"><descEvento>Ciencia da Operacao</descEvento></detEvento></infEvento>`);
    const doc = new DOMParser().parseFromString(envelope, 'text/xml');
    const evento = doc.getElementsByTagNameNS('http://www.portalfiscal.inf.br/nfe', 'evento')[0];
    const signature = evento.getElementsByTagNameNS('http://www.w3.org/2000/09/xmldsig#', 'Signature')[0];
    const certificate = /<X509Certificate>([^<]+)<\/X509Certificate>/.exec(envelope)?.[1] ?? '';
    expect(new X509Certificate(Buffer.from(certificate, 'base64')).toString()).toBe(new X509Certificate(pem.cert).toString());
    const verifier = new SignedXml({ publicCert: pem.cert });
    verifier.loadSignature(signature);
    const signedXml = new XMLSerializer().serializeToString(evento);
    expect(verifier.checkSignature(signedXml)).toBe(true);
    expect(verifier.checkSignature(signedXml.replace('<tpAmb>2</tpAmb>', '<tpAmb>1</tpAmb>'))).toBe(false);
  });

  it('a hora de Brasília fica um minuto atrás, sem milissegundos', () => {
    expect(brasiliaNow(Date.parse('2026-11-22T13:00:30Z'))).toBe('2026-11-22T09:59:30-03:00');
  });

  it('135, 136 e 573 contam como registrado', () => {
    const response = (status: string, motive = 'Evento registrado e vinculado a NF-e') =>
      `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeRecepcaoEvento4">` +
      `<retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.00"><cStat>128</cStat><retEvento versao="1.00"><infEvento>` +
      `<cStat>${status}</cStat><xMotivo>${motive}</xMotivo><nProt>891260000000001</nProt></infEvento></retEvento></retEnvEvento></nfeResultMsg></soap:Body></soap:Envelope>`;
    expect(parseEventResponse(response('135'))).toEqual({ registered: true, status: '135', message: 'Evento registrado e vinculado a NF-e', protocol: '891260000000001' });
    expect(parseEventResponse(response('573', 'Duplicidade de evento')).registered).toBe(true);
    expect(parseEventResponse(response('650', 'Evento de Ciencia da Operacao para NF-e Cancelada'))).toMatchObject({ registered: false, status: '650' });
    const lotRejected = '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeResultMsg><retEnvEvento><cStat>215</cStat><xMotivo>Falha no schema XML</xMotivo></retEnvEvento></nfeResultMsg></soap:Body></soap:Envelope>';
    expect(parseEventResponse(lotRejected)).toEqual({ registered: false, status: '215', message: 'Falha no schema XML', protocol: null });
  });
});
