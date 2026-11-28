import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { SignedXml } from 'xml-crypto';
import { describe, expect, it } from 'vitest';
import { buildPfx } from '../../test/fiscal-pfx.js';
import { AppError } from '../observability/app-error.js';
import { pemFromPfx } from './dfe.js';
import {
  authorizationEnvelope,
  cancellationEnvelope,
  CORRECTION_CONDITIONS,
  correctionEnvelope,
  correctionFromStatus,
  nfceUrl,
  parseAuthorization,
  parseEvent,
  parseStatus,
  parseVoiding,
  procFromStatus,
  statusEnvelope,
  voidingEnvelope,
} from './nfce-sefaz.js';

const KEY = '35261111222333000181650040000000421000000019';
const NS = 'http://www.portalfiscal.inf.br/nfe';
const SIGNED = `<?xml version="1.0" encoding="UTF-8"?><NFe xmlns="${NS}"><infNFe Id="NFe${KEY}" versao="4.00"><ide/></infNFe></NFe>`;
const soap = (inner: string) =>
  `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeResultMsg>${inner}</nfeResultMsg></soap:Body></soap:Envelope>`;
const prot = (status: string) =>
  `<protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><chNFe>${KEY}</chNFe><dhRecbto>2026-11-26T10:00:01-03:00</dhRecbto>`
  + `<nProt>135260000000777</nProt><digVal>abc=</digVal><cStat>${status}</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>`;
const expectCode = (fn: () => unknown, code: string) => {
  try {
    fn();
  } catch (error) {
    expect((error as AppError).code).toBe(code);
    return;
  }
  throw new Error('não lançou');
};

/** Confere a assinatura do elemento com Id dentro do XML. */
function verify(xml: string, element: string, cert: string): boolean {
  const doc = new DOMParser().parseFromString(xml, 'text/xml');
  const target = doc.getElementsByTagNameNS(NS, element)[0];
  const signature = target.getElementsByTagNameNS('http://www.w3.org/2000/09/xmldsig#', 'Signature')[0];
  const verifier = new SignedXml({ publicCert: cert });
  verifier.loadSignature(signature);
  return verifier.checkSignature(new XMLSerializer().serializeToString(target));
}

describe('endereços da NFC-e por UF', () => {
  it('homologação e produção de cada UF; RS e SC na SVRS; UF não atendida é null', () => {
    expect(nfceUrl('SP', 2, 'status', {})).toBe('https://homologacao.nfce.fazenda.sp.gov.br/ws/NFeConsultaProtocolo4.asmx');
    expect(nfceUrl('SP', 1, 'voiding', {})).toBe('https://nfce.fazenda.sp.gov.br/ws/NFeInutilizacao4.asmx');
    expect(nfceUrl('SC', 1, 'event', {})).toBe('https://nfce.svrs.rs.gov.br/ws/recepcaoevento/recepcaoevento4.asmx');
    expect(nfceUrl('PR', 2, 'authorization', {})).toBe('https://homologacao.nfce.sefa.pr.gov.br/nfce/NFeAutorizacao4');
    expect(nfceUrl('AM', 1, 'status', {})).toBeNull();
  });

  it('o servidor falso só vale fora da produção', () => {
    const env = { SEFAZ_NFCE_URL: 'https://127.0.0.1:9999/' };
    expect(nfceUrl('SP', 2, 'event', env)).toBe('https://127.0.0.1:9999/event');
    expect(nfceUrl('SP', 1, 'event', env)).toBe('https://nfce.fazenda.sp.gov.br/ws/NFeRecepcaoEvento4.asmx');
  });
});

describe('consulta pela chave', () => {
  it('monta o pedido', () => {
    expect(statusEnvelope(KEY, 2)).toContain(`<consSitNFe xmlns="${NS}" versao="4.00"><tpAmb>2</tpAmb><xServ>CONSULTAR</xServ><chNFe>${KEY}</chNFe></consSitNFe>`);
    expect(statusEnvelope(KEY, 2)).toContain('wsdl/NFeConsultaProtocolo4');
  });

  it('autorizada traz o protocolo como veio; cancelada, não consta, parada e outras', () => {
    const authorized = parseStatus(soap(`<retConsSitNFe versao="4.00"><cStat>100</cStat><xMotivo>Autorizado</xMotivo>${prot('100')}</retConsSitNFe>`));
    expect(authorized).toMatchObject({ kind: 'authorized', protocol: '135260000000777', authorizedAt: '2026-11-26T10:00:01-03:00' });
    expect(authorized.kind === 'authorized' && authorized.protNFe).toMatch(/^<protNFe versao="4.00"><infProt>.*<\/protNFe>$/);
    expect(parseStatus(soap('<retConsSitNFe><cStat>101</cStat><xMotivo>Cancelamento homologado</xMotivo></retConsSitNFe>'))).toMatchObject({ kind: 'canceled' });
    expect(parseStatus(soap('<retConsSitNFe><cStat>217</cStat><xMotivo>NF-e nao consta</xMotivo></retConsSitNFe>'))).toMatchObject({ kind: 'not_found', status: '217' });
    expect(parseStatus(soap('<retConsSitNFe><cStat>109</cStat><xMotivo>Paralisado</xMotivo></retConsSitNFe>'))).toMatchObject({ kind: 'unavailable' });
    expect(parseStatus(soap('<retConsSitNFe><cStat>110</cStat><xMotivo>Denegado</xMotivo></retConsSitNFe>'))).toMatchObject({ kind: 'other', status: '110' });
    expectCode(() => parseStatus('<x>'), 'FA944');
    expectCode(() => parseStatus(soap('<outra/>')), 'FA944');
    expectCode(() => parseStatus(soap('<retConsSitNFe><cStat>100</cStat></retConsSitNFe>')), 'FA944');
  });

  it('cancelada: o protocolo e a hora vêm do evento de cancelamento, não da autorização', () => {
    const proc = (type: string, protocol: string, at: string) => '<procEventoNFe versao="1.00"><evento versao="1.00"><infEvento Id="x">'
      + `<tpEvento>${type}</tpEvento><detEvento versao="1.00"><nProt>135260000000777</nProt></detEvento></infEvento></evento>`
      + `<retEvento versao="1.00"><infEvento><tpEvento>${type}</tpEvento><cStat>135</cStat><nProt>${protocol}</nProt><dhRegEvento>${at}</dhRegEvento></infEvento></retEvento></procEventoNFe>`;
    // Carta de correção antes, o cancelamento depois.
    const canceled = parseStatus(soap(`<retConsSitNFe versao="4.00"><cStat>101</cStat><xMotivo>Cancelamento homologado</xMotivo>${prot('100')}`
      + `${proc('110110', '135260000000111', '2026-11-26T10:05:00-03:00')}${proc('110111', '135260000000888', '2026-11-26T10:10:05-03:00')}</retConsSitNFe>`));
    expect(canceled).toMatchObject({ kind: 'canceled', protocol: '135260000000777', cancelProtocol: '135260000000888', cancelRegisteredAt: '2026-11-26T10:10:05-03:00' });
    expect(canceled.kind === 'canceled' && canceled.cancelEvent).toMatch(/^<procEventoNFe versao="1.00">.*<tpEvento>110111<\/tpEvento>.*<\/procEventoNFe>$/);
    expect(canceled.kind === 'canceled' && canceled.cancelEvent).not.toContain('110110');
    // Sem o evento (ou sem protocolo nele), nada para registrar.
    expect(parseStatus(soap('<retConsSitNFe><cStat>101</cStat><xMotivo>Cancelamento homologado</xMotivo></retConsSitNFe>')))
      .toMatchObject({ kind: 'canceled', cancelEvent: null, cancelProtocol: null, cancelRegisteredAt: null });
    expect(parseStatus(soap(`<retConsSitNFe><cStat>101</cStat><xMotivo>Cancelamento homologado</xMotivo>${proc('110111', '', '2026-11-26T10:10:05-03:00')}</retConsSitNFe>`)))
      .toMatchObject({ kind: 'canceled', cancelEvent: null, cancelProtocol: null });
  });

  it('junta a nota assinada e o protocolo da consulta no nfeProc', () => {
    const proc = procFromStatus(SIGNED, prot('100'));
    expect(proc).toBe(`<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="${NS}" versao="4.00"><NFe xmlns="${NS}"><infNFe Id="NFe${KEY}" versao="4.00"><ide/></infNFe></NFe>${prot('100')}</nfeProc>`);
  });
});

describe('reenvio da nota', () => {
  it('lote síncrono com a nota sem a declaração XML', () => {
    const envelope = authorizationEnvelope(SIGNED, '000000000000123');
    expect(envelope).toContain(`<enviNFe xmlns="${NS}" versao="4.00"><idLote>000000000000123</idLote><indSinc>1</indSinc><NFe xmlns`);
    expect(envelope.match(/<\?xml/g)).toHaveLength(1);
  });

  it('104 com 100 autoriza; 204 é duplicidade; 108 parado; rejeição', () => {
    const ok = parseAuthorization(soap(`<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo>${prot('100')}</retEnviNFe>`), SIGNED);
    expect(ok).toMatchObject({ kind: 'authorized', protocol: '135260000000777' });
    expect(ok.kind === 'authorized' && ok.procXml).toContain('</NFe><protNFe');
    expect(parseAuthorization(soap(`<retEnviNFe><cStat>104</cStat>${prot('204').replace('Autorizado o uso da NF-e', 'Duplicidade')}</retEnviNFe>`), SIGNED))
      .toMatchObject({ kind: 'duplicate', status: '204' });
    // 539: mesmo número com outra chave (a outra vem no motivo): recusa, não é a mesma nota.
    expect(parseAuthorization(soap(`<retEnviNFe><cStat>104</cStat>${prot('539').replace('Autorizado o uso da NF-e', 'Duplicidade de NF-e com diferenca na Chave de Acesso [chNFe: 35261111222333000181650040000000429999999999]')}</retEnviNFe>`), SIGNED))
      .toMatchObject({ kind: 'rejected', status: '539', reason: expect.stringContaining('chNFe: 3526') });
    expect(parseAuthorization(soap('<retEnviNFe><cStat>108</cStat><xMotivo>Paralisado</xMotivo></retEnviNFe>'), SIGNED)).toMatchObject({ kind: 'unavailable' });
    expect(parseAuthorization(soap(`<retEnviNFe><cStat>104</cStat>${prot('778')}</retEnviNFe>`), SIGNED)).toMatchObject({ kind: 'rejected', status: '778' });
    expect(parseAuthorization(soap('<retEnviNFe><cStat>225</cStat><xMotivo>Schema</xMotivo></retEnviNFe>'), SIGNED)).toMatchObject({ kind: 'rejected', status: '225' });
  });
});

describe('cancelamento', () => {
  const pem = pemFromPfx(buildPfx(), 'senha-do-teste');
  const request = {
    environment: 2 as const, uf: 'SP', cnpj: '11222333000181', accessKey: KEY, protocol: '135260000000777',
    reason: 'Cliente desistiu da compra <&>', at: '2026-11-26T10:10:00-03:00',
  };

  it('o evento sai assinado, com o órgão da UF, o protocolo e o motivo escapado', () => {
    const { envelope, event } = cancellationEnvelope(request, pem);
    expect(event).toContain(`<infEvento Id="ID110111${KEY}01"><cOrgao>35</cOrgao><tpAmb>2</tpAmb><CNPJ>11222333000181</CNPJ><chNFe>${KEY}</chNFe><dhEvento>2026-11-26T10:10:00-03:00</dhEvento><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento><verEvento>1.00</verEvento><detEvento versao="1.00"><descEvento>Cancelamento</descEvento><nProt>135260000000777</nProt><xJust>Cliente desistiu da compra &lt;&amp;&gt;</xJust></detEvento></infEvento>`);
    expect(envelope).toContain('wsdl/NFeRecepcaoEvento4');
    expect(verify(envelope, 'evento', pem.cert)).toBe(true);
    expect(verify(envelope.replace('<tpAmb>2</tpAmb>', '<tpAmb>1</tpAmb>'), 'evento', pem.cert)).toBe(false);
  });

  it('135 e 155 registram, com o procEventoNFe; 573 e registro sem protocolo vão para consulta; o resto recusa', () => {
    const { event } = cancellationEnvelope(request, pem);
    const answer = (status: string, protocol = '135260000000888') => soap(
      `<retEnvEvento versao="1.00"><cStat>128</cStat><xMotivo>Lote processado</xMotivo><retEvento versao="1.00"><infEvento>`
      + `<cStat>${status}</cStat><xMotivo>Motivo ${status}</xMotivo><nProt>${protocol}</nProt><dhRegEvento>2026-11-26T10:10:05-03:00</dhRegEvento></infEvento></retEvento></retEnvEvento>`);
    const done = parseEvent(answer('135'), event);
    expect(done).toMatchObject({ kind: 'registered', protocol: '135260000000888', registeredAt: '2026-11-26T10:10:05-03:00' });
    expect(done.kind === 'registered' && done.procXml).toMatch(/<procEventoNFe xmlns="[^"]+" versao="1.00"><evento .*<\/evento><retEvento versao="1.00">.*<\/retEvento><\/procEventoNFe>$/);
    expect(parseEvent(answer('155'), event)).toMatchObject({ kind: 'registered' });
    expect(parseEvent(answer('573', ''), event)).toEqual({ kind: 'duplicate', status: '573', reason: 'Motivo 573' });
    expect(parseEvent(answer('573'), event)).toMatchObject({ kind: 'duplicate' });
    expect(parseEvent(answer('135', ''), event)).toMatchObject({ kind: 'duplicate', status: '135' });
    expect(parseEvent(answer('135', '1352600'), event)).toMatchObject({ kind: 'duplicate' });
    expect(parseEvent(answer('501'), event)).toMatchObject({ kind: 'refused', status: '501', reason: 'Motivo 501' });
    expect(parseEvent(soap('<retEnvEvento><cStat>108</cStat><xMotivo>Parado</xMotivo></retEnvEvento>'), event)).toMatchObject({ kind: 'unavailable' });
    expect(parseEvent(soap('<retEnvEvento><cStat>489</cStat><xMotivo>CNPJ invalido</xMotivo></retEnvEvento>'), event)).toMatchObject({ kind: 'refused', status: '489' });
  });
});

describe('carta de correção', () => {
  const pem = pemFromPfx(buildPfx(), 'senha-do-teste');
  const KEY55 = '35261111222333000181550010000000421000000019';
  const request = {
    environment: 2 as const, uf: 'SP', cnpj: '11222333000181', accessKey: KEY55, sequence: 3,
    text: 'Endereço: Rua <A> & "B"', at: '2026-11-28T10:10:00-03:00',
  };

  it('evento 110110 assinado: Id com a sequência em dois dígitos, texto escapado e a condição de uso do leiaute', () => {
    const { envelope, event } = correctionEnvelope(request, pem);
    expect(event).toContain(`<infEvento Id="ID110110${KEY55}03"><cOrgao>35</cOrgao><tpAmb>2</tpAmb><CNPJ>11222333000181</CNPJ><chNFe>${KEY55}</chNFe><dhEvento>2026-11-28T10:10:00-03:00</dhEvento><tpEvento>110110</tpEvento><nSeqEvento>3</nSeqEvento><verEvento>1.00</verEvento><detEvento versao="1.00"><descEvento>Carta de Correcao</descEvento><xCorrecao>Endereço: Rua &lt;A&gt; &amp; "B"</xCorrecao><xCondUso>${CORRECTION_CONDITIONS}</xCondUso></detEvento></infEvento>`);
    expect(CORRECTION_CONDITIONS).toMatch(/^A Carta de Correcao e disciplinada pelo paragrafo 1o-A do art\. 7o do Convenio S\/N, de 15 de dezembro de 1970 .* III - a data de emissao ou de saida\.$/);
    expect(CORRECTION_CONDITIONS).not.toMatch(/[^\x20-\x7e]/);
    expect(envelope).toContain('wsdl/NFeRecepcaoEvento4');
    expect(verify(envelope, 'evento', pem.cert)).toBe(true);
    expect(correctionEnvelope({ ...request, sequence: 12 }, pem).event).toContain(`Id="ID110110${KEY55}12"`);
  });

  it('136 (registrada sem vínculo) registra como a 135', () => {
    const { event } = correctionEnvelope(request, pem);
    const answer = soap('<retEnvEvento versao="1.00"><cStat>128</cStat><xMotivo>Lote</xMotivo><retEvento versao="1.00"><infEvento><cStat>136</cStat>'
      + '<xMotivo>Evento registrado, mas nao vinculado a NF-e</xMotivo><nProt>135260000000888</nProt><dhRegEvento>2026-11-28T10:10:05-03:00</dhRegEvento></infEvento></retEvento></retEnvEvento>');
    expect(parseEvent(answer, event)).toMatchObject({ kind: 'registered', status: '136', protocol: '135260000000888' });
  });

  it('na consulta pela chave, acha a carta registrada com a sequência pedida (com o texto) e ignora as outras', () => {
    const proc = (type: string, sequence: number, status: string, protocol: string, text: string) =>
      `<procEventoNFe versao="1.00"><evento versao="1.00"><infEvento Id="ID${type}${KEY55}0${sequence}"><tpEvento>${type}</tpEvento>`
      + `<nSeqEvento>${sequence}</nSeqEvento><detEvento versao="1.00"><xCorrecao>${text}</xCorrecao></detEvento></infEvento></evento>`
      + `<retEvento versao="1.00"><infEvento><cStat>${status}</cStat><xMotivo>Registrado</xMotivo><nProt>${protocol}</nProt>`
      + '<dhRegEvento>2026-11-28T10:00:02-03:00</dhRegEvento></infEvento></retEvento></procEventoNFe>';
    const answer = soap(`<retConsSitNFe versao="4.00"><cStat>100</cStat>${prot('100')}${proc('110111', 2, '135', '135260000000700', '')}`
      + `${proc('110110', 1, '135', '135260000000701', 'Primeira')}${proc('110110', 2, '573', '', 'Recusada')}${proc('110110', 2, '136', '135260000000702', 'Rua &amp; fundos')}</retConsSitNFe>`);
    expect(correctionFromStatus(answer, 2)).toMatchObject({ protocol: '135260000000702', status: '136', text: 'Rua & fundos', registeredAt: '2026-11-28T10:00:02-03:00' });
    expect(correctionFromStatus(answer, 2)!.xml).toMatch(/^<\?xml version="1.0" encoding="UTF-8"\?><procEventoNFe/);
    expect(correctionFromStatus(answer, 1)).toMatchObject({ protocol: '135260000000701', text: 'Primeira' });
    expect(correctionFromStatus(answer, 3)).toBeNull();
  });
});

describe('inutilização', () => {
  const pem = pemFromPfx(buildPfx(), 'senha-do-teste');
  const request = { environment: 2 as const, uf: 'SP', cnpj: '11222333000181', year: '26', series: 4, first: 10, last: 12, reason: 'Numeros pulados no caixa 4' };

  it('pedido assinado com o Id do leiaute (UF, ano, CNPJ, modelo, série e faixa)', () => {
    const { envelope, message } = voidingEnvelope(request, pem);
    expect(message).toContain('<infInut Id="ID35261122233300018165004000000010000000012"><tpAmb>2</tpAmb><xServ>INUTILIZAR</xServ><cUF>35</cUF><ano>26</ano><CNPJ>11222333000181</CNPJ><mod>65</mod><serie>4</serie><nNFIni>10</nNFIni><nNFFin>12</nNFFin><xJust>Numeros pulados no caixa 4</xJust></infInut>');
    expect(envelope).toContain('wsdl/NFeInutilizacao4');
    expect(verify(envelope, 'inutNFe', pem.cert)).toBe(true);
  });

  it('102 inutiliza, com o ProcInutNFe; 563 e outras recusam; 109 parado', () => {
    const { message } = voidingEnvelope(request, pem);
    const answer = (status: string) => soap(
      `<retInutNFe versao="4.00"><infInut><tpAmb>2</tpAmb><cStat>${status}</cStat><xMotivo>Motivo ${status}</xMotivo>`
      + `<nProt>135260000000999</nProt><dhRecbto>2026-11-26T11:00:00-03:00</dhRecbto></infInut></retInutNFe>`);
    const done = parseVoiding(answer('102'), message);
    expect(done).toMatchObject({ kind: 'voided', protocol: '135260000000999', voidedAt: '2026-11-26T11:00:00-03:00' });
    expect(done.kind === 'voided' && done.procXml).toContain('</inutNFe><retInutNFe');
    expect(parseVoiding(answer('563'), message)).toMatchObject({ kind: 'refused', status: '563' });
    expect(parseVoiding(answer('109'), message)).toMatchObject({ kind: 'unavailable' });
  });
});
