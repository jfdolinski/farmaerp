import { XMLParser } from 'fast-xml-parser';
import { SignedXml } from 'xml-crypto';
import { AppError } from '../observability/app-error.js';

/**
 * Serviços da NFC-e na Sefaz da UF, chamados pela central: consulta pela chave, autorização (o
 * reenvio da nota que o caixa assinou), cancelamento (evento 110111) e inutilização de numeração.
 * Mensagens no leiaute 4.00 (eventos 1.00), SOAP 1.2. A resposta original fica guardada.
 */

export const NFE_NS = 'http://www.portalfiscal.inf.br/nfe';
const SOAP_NS = 'http://www.w3.org/2003/05/soap-envelope';
const WSDL = 'http://www.portalfiscal.inf.br/nfe/wsdl';

export const ACTIONS = {
  authorization: `${WSDL}/NFeAutorizacao4/nfeAutorizacaoLote`,
  status: `${WSDL}/NFeConsultaProtocolo4/nfeConsultaNF`,
  event: `${WSDL}/NFeRecepcaoEvento4/nfeRecepcaoEvento`,
  voiding: `${WSDL}/NFeInutilizacao4/nfeInutilizacaoNF`,
} as const;

export type NfceService = keyof typeof ACTIONS;

/** Código IBGE da UF (cUF, cOrgao). */
export const UF_CODES: Record<string, string> = {
  RO: '11', AC: '12', AM: '13', RR: '14', PA: '15', AP: '16', TO: '17', MA: '21', PI: '22', CE: '23', RN: '24', PB: '25',
  PE: '26', AL: '27', SE: '28', BA: '29', MG: '31', ES: '32', RJ: '33', SP: '35', PR: '41', SC: '42', RS: '43', MS: '50',
  MT: '51', GO: '52', DF: '53',
};

type Urls = Record<NfceService, string>;
const svrs = (host: string): Urls => ({
  authorization: `https://${host}/ws/NfeAutorizacao/NFeAutorizacao4.asmx`,
  status: `https://${host}/ws/NfeConsulta/NfeConsulta4.asmx`,
  event: `https://${host}/ws/recepcaoevento/recepcaoevento4.asmx`,
  voiding: `https://${host}/ws/nfeinutilizacao/nfeinutilizacao4.asmx`,
});
const sp = (host: string): Urls => ({
  authorization: `https://${host}/ws/NFeAutorizacao4.asmx`,
  status: `https://${host}/ws/NFeConsultaProtocolo4.asmx`,
  event: `https://${host}/ws/NFeRecepcaoEvento4.asmx`,
  voiding: `https://${host}/ws/NFeInutilizacao4.asmx`,
});
const servicePath = (base: string): Urls => ({
  authorization: `${base}/NFeAutorizacao4`,
  status: `${base}/NFeConsultaProtocolo4`,
  event: `${base}/NFeRecepcaoEvento4`,
  voiding: `${base}/NFeInutilizacao4`,
});

/**
 * Endereços da NFC-e por UF ([homologação, produção]). Os mesmos estados que o caixa atende.
 * CONFERIR com o portal de cada UF antes de produção.
 */
const URLS: Record<string, [Urls, Urls]> = {
  SP: [sp('homologacao.nfce.fazenda.sp.gov.br'), sp('nfce.fazenda.sp.gov.br')],
  PR: [servicePath('https://homologacao.nfce.sefa.pr.gov.br/nfce'), servicePath('https://nfce.sefa.pr.gov.br/nfce')],
  MG: [servicePath('https://hnfce.fazenda.mg.gov.br/nfce/services'), servicePath('https://nfce.fazenda.mg.gov.br/nfce/services')],
  RS: [svrs('nfce-homologacao.svrs.rs.gov.br'), svrs('nfce.svrs.rs.gov.br')],
  SC: [svrs('nfce-homologacao.svrs.rs.gov.br'), svrs('nfce.svrs.rs.gov.br')],
};

/**
 * Endereço do serviço na UF. Fora da produção, os testes apontam tudo para um servidor falso
 * (SEFAZ_NFCE_URL, com o nome do serviço no fim). Null: UF não atendida.
 */
export function nfceUrl(uf: string, environment: 1 | 2, service: NfceService, env: NodeJS.ProcessEnv = process.env): string | null {
  if (environment === 2 && env.SEFAZ_NFCE_URL) return `${env.SEFAZ_NFCE_URL.replace(/\/$/, '')}/${service}`;
  const urls = URLS[uf];
  return urls ? urls[environment === 1 ? 1 : 0][service] : null;
}

type Node = Record<string, unknown>;
const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  removeNSPrefix: true,
  parseTagValue: false,
  parseAttributeValue: false,
  processEntities: false,
  htmlEntities: false,
  trimValues: true,
});

const unavailable = (reason: string): never => {
  throw new AppError('FA944', { cause: new Error(reason) });
};

function parse(xml: string): Node {
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) unavailable('DOCTYPE na resposta');
  try {
    return parser.parse(xml) as Node;
  } catch (error) {
    return unavailable(`XML malformado: ${(error as Error).message}`);
  }
}

/** Primeiro elemento com o nome, em qualquer profundidade. */
function find(node: unknown, name: string): Node | undefined {
  if (!node || typeof node !== 'object') return undefined;
  for (const [key, value] of Object.entries(node as Node)) {
    if (key === name && value && typeof value === 'object') return (Array.isArray(value) ? value[0] : value) as Node;
  }
  for (const value of Object.values(node as Node)) {
    const found = find(Array.isArray(value) ? value[0] : value, name);
    if (found) return found;
  }
  return undefined;
}
const text = (node: Node | undefined, name: string): string => {
  const value = node?.[name];
  if (typeof value === 'string') return value.trim();
  if (value && typeof value === 'object' && typeof (value as Node)['#text'] === 'string') return ((value as Node)['#text'] as string).trim();
  return '';
};
const escapeXml = (value: string) =>
  value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');

/** Recorta um elemento da resposta como veio (a Sefaz assina alguns), sem prefixo de namespace. */
function cut(xml: string, name: string): string | null {
  const start = xml.search(new RegExp(`<(\\w+:)?${name}[\\s>]`));
  if (start < 0) return null;
  const end = new RegExp(`</(\\w+:)?${name}>`).exec(xml.slice(start));
  if (!end) return null;
  return xml.slice(start, start + end.index + end[0].length).replace(/(<\/?)\w+:/g, '$1');
}

function envelope(service: string, body: string): string {
  return `<?xml version="1.0" encoding="utf-8"?><soap12:Envelope xmlns:soap12="${SOAP_NS}"><soap12:Body>`
    + `<nfeDadosMsg xmlns="${WSDL}/${service}">${body}</nfeDadosMsg></soap12:Body></soap12:Envelope>`;
}

/** Assinatura do elemento com Id (RSA-SHA1, C14N, envelopada), como pede o leiaute. */
function sign(xml: string, element: string, pem: { key: string; cert: string }): string {
  const signer = new SignedXml({
    privateKey: pem.key,
    publicCert: pem.cert,
    signatureAlgorithm: 'http://www.w3.org/2000/09/xmldsig#rsa-sha1',
    canonicalizationAlgorithm: 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315',
  });
  signer.addReference({
    xpath: `//*[local-name(.)='${element}']`,
    digestAlgorithm: 'http://www.w3.org/2000/09/xmldsig#sha1',
    transforms: ['http://www.w3.org/2000/09/xmldsig#enveloped-signature', 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'],
  });
  signer.computeSignature(xml, { location: { reference: `//*[local-name(.)='${element}']`, action: 'after' } });
  return signer.getSignedXml();
}

// ----- Consulta pela chave -----

export function statusEnvelope(accessKey: string, environment: 1 | 2): string {
  return envelope('NFeConsultaProtocolo4',
    `<consSitNFe xmlns="${NFE_NS}" versao="4.00"><tpAmb>${environment}</tpAmb><xServ>CONSULTAR</xServ><chNFe>${escapeXml(accessKey)}</chNFe></consSitNFe>`);
}

export type StatusResult =
  | { kind: 'authorized'; status: string; reason: string; protocol: string; authorizedAt: string; protNFe: string }
  | { kind: 'canceled'; status: string; reason: string; protocol: string | null; authorizedAt: string | null; protNFe: string | null; cancelEvent: string | null }
  | { kind: 'not_found'; status: string; reason: string }
  | { kind: 'unavailable'; status: string; reason: string }
  | { kind: 'other'; status: string; reason: string };

/**
 * Situação da nota: 100/150 autorizada (com o protNFe); 101/151/155 cancelada; 217 não consta
 * (nunca chegou); 108/109 serviço parado; o resto (ex.: denegada, chave inválida) vai como está.
 */
export function parseStatus(xml: string): StatusResult {
  const root = parse(xml);
  const ret = find(root, 'retConsSitNFe') ?? unavailable('retConsSitNFe ausente');
  const status = text(ret, 'cStat');
  const reason = text(ret, 'xMotivo');
  const prot = find(ret, 'infProt');
  const protocol = text(prot, 'nProt') || null;
  const authorizedAt = text(prot, 'dhRecbto') || null;
  if (status === '100' || status === '150') {
    const protNFe = cut(xml, 'protNFe');
    if (!protNFe || !protocol || !authorizedAt) return unavailable('autorizada sem o protocolo');
    return { kind: 'authorized', status, reason, protocol, authorizedAt, protNFe };
  }
  if (['101', '151', '155'].includes(status)) {
    return { kind: 'canceled', status, reason, protocol, authorizedAt, protNFe: cut(xml, 'protNFe'), cancelEvent: cut(xml, 'procEventoNFe') };
  }
  if (status === '217') return { kind: 'not_found', status, reason };
  if (status === '108' || status === '109') return { kind: 'unavailable', status, reason };
  return { kind: 'other', status, reason };
}

// ----- Autorização (reenvio da nota assinada no caixa) -----

export function authorizationEnvelope(signedNfe: string, batchId: string): string {
  const nfe = signedNfe.replace(/^<\?xml[^>]*\?>\s*/, '');
  return envelope('NFeAutorizacao4', `<enviNFe xmlns="${NFE_NS}" versao="4.00"><idLote>${batchId}</idLote><indSinc>1</indSinc>${nfe}</enviNFe>`);
}

export type AuthorizationResult =
  | { kind: 'authorized'; status: string; reason: string; protocol: string; authorizedAt: string; procXml: string }
  | { kind: 'duplicate'; status: string; reason: string }
  | { kind: 'rejected'; status: string; reason: string }
  | { kind: 'unavailable'; status: string; reason: string };

/** 104 traz o protocolo: 100/150 autoriza. 204/539: a nota já está lá (consultar). 108/109: parado. */
export function parseAuthorization(xml: string, signedNfe: string): AuthorizationResult {
  const root = parse(xml);
  const batch = find(root, 'retEnviNFe') ?? unavailable('retEnviNFe ausente');
  const batchStatus = text(batch, 'cStat');
  const batchReason = text(batch, 'xMotivo');
  if (batchStatus === '108' || batchStatus === '109') return { kind: 'unavailable', status: batchStatus, reason: batchReason };
  if (batchStatus !== '104') return { kind: 'rejected', status: batchStatus, reason: batchReason };
  const prot = find(batch, 'infProt');
  const status = text(prot, 'cStat');
  const reason = text(prot, 'xMotivo');
  if (status === '204' || status === '539') return { kind: 'duplicate', status, reason };
  if (status !== '100' && status !== '150') return { kind: 'rejected', status, reason };
  const protNFe = cut(xml, 'protNFe');
  if (!protNFe) return unavailable('autorizada sem o protocolo');
  const nfe = signedNfe.replace(/^<\?xml[^>]*\?>\s*/, '');
  return {
    kind: 'authorized', status, reason, protocol: text(prot, 'nProt'), authorizedAt: text(prot, 'dhRecbto'),
    procXml: `<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="${NFE_NS}" versao="4.00">${nfe}${protNFe}</nfeProc>`,
  };
}

/** Junta a nota assinada e o protocolo da consulta (nota que chegou, mas a resposta se perdeu). */
export function procFromStatus(signedNfe: string, protNFe: string): string {
  const nfe = signedNfe.replace(/^<\?xml[^>]*\?>\s*/, '');
  return `<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="${NFE_NS}" versao="4.00">${nfe}${protNFe}</nfeProc>`;
}

// ----- Cancelamento (evento 110111) -----

export interface CancellationRequest {
  environment: 1 | 2;
  uf: string;
  cnpj: string;
  accessKey: string;
  protocol: string;
  reason: string;
  /** dhEvento com fuso (Brasília). */
  at: string;
}

export function cancellationEnvelope(request: CancellationRequest, pem: { key: string; cert: string }): { envelope: string; event: string } {
  const id = `ID110111${request.accessKey}01`;
  const event =
    `<evento xmlns="${NFE_NS}" versao="1.00"><infEvento Id="${id}"><cOrgao>${UF_CODES[request.uf] ?? ''}</cOrgao>`
    + `<tpAmb>${request.environment}</tpAmb><CNPJ>${escapeXml(request.cnpj)}</CNPJ><chNFe>${escapeXml(request.accessKey)}</chNFe>`
    + `<dhEvento>${request.at}</dhEvento><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento><verEvento>1.00</verEvento>`
    + `<detEvento versao="1.00"><descEvento>Cancelamento</descEvento><nProt>${escapeXml(request.protocol)}</nProt>`
    + `<xJust>${escapeXml(request.reason)}</xJust></detEvento></infEvento></evento>`;
  const signed = sign(event, 'infEvento', pem);
  const lot = String(Date.now()).slice(-15);
  return {
    event: signed,
    envelope: envelope('NFeRecepcaoEvento4', `<envEvento xmlns="${NFE_NS}" versao="1.00"><idLote>${lot}</idLote>${signed}</envEvento>`),
  };
}

export type EventResult =
  | { kind: 'registered'; status: string; reason: string; protocol: string; registeredAt: string; procXml: string }
  | { kind: 'refused'; status: string; reason: string }
  | { kind: 'unavailable'; status: string; reason: string };

/** 135 registrado; 155 registrado fora do prazo; 573 já registrado antes. O resto recusa. */
export function parseEvent(xml: string, signedEvent: string): EventResult {
  const root = parse(xml);
  const lot = find(root, 'retEnvEvento') ?? unavailable('retEnvEvento ausente');
  const lotStatus = text(lot, 'cStat');
  if (lotStatus === '108' || lotStatus === '109') return { kind: 'unavailable', status: lotStatus, reason: text(lot, 'xMotivo') };
  const info = find(find(lot, 'retEvento'), 'infEvento');
  if (!info) return { kind: 'refused', status: lotStatus, reason: text(lot, 'xMotivo') };
  const status = text(info, 'cStat');
  const reason = text(info, 'xMotivo');
  if (!['135', '155', '573'].includes(status)) return { kind: 'refused', status, reason };
  const retEvento = cut(xml, 'retEvento') ?? '';
  return {
    kind: 'registered', status, reason, protocol: text(info, 'nProt'), registeredAt: text(info, 'dhRegEvento'),
    procXml: `<?xml version="1.0" encoding="UTF-8"?><procEventoNFe xmlns="${NFE_NS}" versao="1.00">${signedEvent}${retEvento}</procEventoNFe>`,
  };
}

// ----- Inutilização de numeração -----

export interface VoidingRequest {
  environment: 1 | 2;
  uf: string;
  cnpj: string;
  /** Ano da numeração (dois dígitos). */
  year: string;
  series: number;
  first: number;
  last: number;
  reason: string;
}

export function voidingEnvelope(request: VoidingRequest, pem: { key: string; cert: string }): { envelope: string; message: string } {
  const uf = UF_CODES[request.uf] ?? '';
  const id = `ID${uf}${request.year}${request.cnpj}65${String(request.series).padStart(3, '0')}`
    + `${String(request.first).padStart(9, '0')}${String(request.last).padStart(9, '0')}`;
  const message =
    `<inutNFe xmlns="${NFE_NS}" versao="4.00"><infInut Id="${id}"><tpAmb>${request.environment}</tpAmb><xServ>INUTILIZAR</xServ>`
    + `<cUF>${uf}</cUF><ano>${request.year}</ano><CNPJ>${escapeXml(request.cnpj)}</CNPJ><mod>65</mod><serie>${request.series}</serie>`
    + `<nNFIni>${request.first}</nNFIni><nNFFin>${request.last}</nNFFin><xJust>${escapeXml(request.reason)}</xJust></infInut></inutNFe>`;
  const signed = sign(message, 'infInut', pem);
  return { message: signed, envelope: envelope('NFeInutilizacao4', signed) };
}

export type VoidingResult =
  | { kind: 'voided'; status: string; reason: string; protocol: string; voidedAt: string; procXml: string }
  | { kind: 'refused'; status: string; reason: string }
  | { kind: 'unavailable'; status: string; reason: string };

/** 102: inutilização homologada. 108/109: parado. O resto recusa (ex.: 563 já inutilizada). */
export function parseVoiding(xml: string, signedMessage: string): VoidingResult {
  const root = parse(xml);
  const ret = find(root, 'retInutNFe') ?? unavailable('retInutNFe ausente');
  const info = find(ret, 'infInut') ?? ret;
  const status = text(info, 'cStat');
  const reason = text(info, 'xMotivo');
  if (status === '108' || status === '109') return { kind: 'unavailable', status, reason };
  if (status !== '102') return { kind: 'refused', status, reason };
  const retInut = cut(xml, 'retInutNFe') ?? '';
  return {
    kind: 'voided', status, reason, protocol: text(info, 'nProt'), voidedAt: text(info, 'dhRecbto'),
    procXml: `<?xml version="1.0" encoding="UTF-8"?><ProcInutNFe xmlns="${NFE_NS}" versao="4.00">${signedMessage}${retInut}</ProcInutNFe>`,
  };
}
