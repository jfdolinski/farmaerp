import { gunzipSync } from 'node:zlib';
import forge from 'node-forge';
import { XMLParser } from 'fast-xml-parser';
import { SignedXml } from 'xml-crypto';
import { AppError } from '../observability/app-error.js';
import { isValidAccessKey, MAX_XML_BYTES } from '../purchases/nfe-xml.js';

const NFE_NS = 'http://www.portalfiscal.inf.br/nfe';
const SOAP_NS = 'http://www.w3.org/2003/05/soap-envelope';
export const DIST_ACTION = 'http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe/nfeDistDFeInteresse';
export const EVENT_ACTION = 'http://www.portalfiscal.inf.br/nfe/wsdl/NFeRecepcaoEvento4/nfeRecepcaoEvento';
/** Ciência da operação: o destinatário sabe da nota; basta para a Sefaz liberar o XML completo. */
export const AWARENESS_EVENT = '210210';
export const CANCELLATION_EVENT = '110111';

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
  isArray: (name) => name === 'docZip' || name === 'retEvento',
});

/** Resposta da Sefaz fora do esperado: o motivo vai para o log, a tela recebe FA944. */
const fail = (reason: string): never => {
  throw new AppError('FA944', { cause: new Error(reason) });
};

function parse(xml: string): Node {
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) fail('DOCTYPE na resposta');
  try {
    return parser.parse(xml) as Node;
  } catch (error) {
    return fail(`XML malformado: ${(error as Error).message}`);
  }
}
const child = (node: unknown, name: string): Node | undefined => {
  const value = (node as Node | undefined)?.[name];
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Node) : undefined;
};
const text = (node: unknown, name: string): string | null => {
  const value = (node as Node | undefined)?.[name];
  if (typeof value === 'string') return value === '' ? null : value;
  if (value && typeof value === 'object' && typeof (value as Node)['#text'] === 'string') return (value as Node)['#text'] as string;
  return null;
};
const attr = (node: unknown, name: string): string => {
  const value = (node as Node | undefined)?.[`@_${name}`];
  return typeof value === 'string' ? value : '';
};
const escapeXml = (value: string) =>
  value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function envelope(body: string): string {
  return `<?xml version="1.0" encoding="utf-8"?><soap12:Envelope xmlns:soap12="${SOAP_NS}"><soap12:Body>${body}</soap12:Body></soap12:Envelope>`;
}

export interface DistQuery {
  environment: 1 | 2;
  ufCode: string;
  cnpj: string;
  /** Busca pelo último NSU, ou por uma chave de acesso. */
  lastNsu?: string;
  accessKey?: string;
}

/** Pedido à distribuição (distDFeInt 1.01), pelo NSU ou pela chave. */
export function distributionEnvelope(query: DistQuery): string {
  const search = query.accessKey
    ? `<consChNFe><chNFe>${escapeXml(query.accessKey)}</chNFe></consChNFe>`
    : `<distNSU><ultNSU>${escapeXml((query.lastNsu ?? '0').padStart(15, '0'))}</ultNSU></distNSU>`;
  return envelope(
    `<nfeDistDFeInteresse xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe"><nfeDadosMsg>` +
      `<distDFeInt xmlns="${NFE_NS}" versao="1.01"><tpAmb>${query.environment}</tpAmb><cUFAutor>${escapeXml(query.ufCode)}</cUFAutor>` +
      `<CNPJ>${escapeXml(query.cnpj)}</CNPJ>${search}</distDFeInt></nfeDadosMsg></nfeDistDFeInteresse>`,
  );
}

export interface DistDocument {
  nsu: string;
  schema: string;
  xml: string;
}

export interface DistResult {
  status: string;
  message: string;
  lastNsu: string | null;
  maxNsu: string | null;
  documents: DistDocument[];
  /** Documentos que não puderam ser abertos (grandes demais ou corrompidos), só para o log. */
  skipped: { nsu: string; reason: string }[];
}

const NSU = /^[0-9]{15}$/;
const SCHEMA = /^[A-Za-z]{1,30}_v[0-9]{1,2}\.[0-9]{2}$/;

/** Abre a resposta da distribuição. Cada documento vem compactado (gzip) em base64. */
export function parseDistribution(xml: string): DistResult {
  const root = parse(xml);
  const ret = child(child(child(child(root, 'Envelope'), 'Body'), 'nfeDistDFeInteresseResponse'), 'nfeDistDFeInteresseResult');
  const result = child(ret, 'retDistDFeInt') ?? fail('retDistDFeInt ausente');
  const status = text(result, 'cStat') ?? fail('cStat ausente');
  const lastNsu = text(result, 'ultNSU');
  const maxNsu = text(result, 'maxNSU');
  const documents: DistDocument[] = [];
  const skipped: { nsu: string; reason: string }[] = [];
  const zips = (child(result, 'loteDistDFeInt')?.docZip ?? []) as unknown[];
  for (const zip of zips) {
    const nsu = attr(zip, 'NSU');
    const schema = attr(zip, 'schema');
    const content = typeof zip === 'string' ? zip : text({ value: zip }, 'value');
    if (!NSU.test(nsu) || !SCHEMA.test(schema) || !content) {
      skipped.push({ nsu, reason: 'documento sem NSU, esquema ou conteúdo' });
      continue;
    }
    try {
      const raw = gunzipSync(Buffer.from(content, 'base64'), { maxOutputLength: MAX_XML_BYTES });
      documents.push({ nsu, schema, xml: raw.toString('utf8') });
    } catch (error) {
      skipped.push({ nsu, reason: `não abriu: ${(error as NodeJS.ErrnoException).code ?? (error as Error).message}` });
    }
  }
  return {
    status,
    message: text(result, 'xMotivo') ?? '',
    lastNsu: lastNsu && NSU.test(lastNsu) ? lastNsu : null,
    maxNsu: maxNsu && NSU.test(maxNsu) ? maxNsu : null,
    documents,
    skipped,
  };
}

export interface InvoiceSummary {
  accessKey: string;
  emitterDocument: string;
  emitterName: string;
  issuedAt: string;
  operationType: number;
  total: string;
  digest: string;
  protocolNumber: string | null;
  situation: number;
}

const DECIMAL = /^\d{1,13}(\.\d{1,2})?$/;
const INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:\d{2}|Z)$/;
const DIGEST = /^([A-Za-z0-9+/]{27}=|[A-Za-z0-9+/]{43}=)$/;

/** Resumo da nota (resNFe). Devolve null quando o documento não é um resumo válido. */
export function readSummary(xml: string): InvoiceSummary | null {
  const node = child(parse(xml), 'resNFe');
  if (!node) return null;
  const accessKey = text(node, 'chNFe') ?? '';
  const emitterDocument = text(node, 'CNPJ') ?? text(node, 'CPF') ?? '';
  const issuedAt = text(node, 'dhEmi') ?? '';
  const total = text(node, 'vNF') ?? '';
  const digest = text(node, 'digVal') ?? '';
  const situation = text(node, 'cSitNFe') ?? '';
  const operationType = text(node, 'tpNF') ?? '';
  const protocol = text(node, 'nProt');
  if (
    !isValidAccessKey(accessKey) || !/^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$/.test(emitterDocument) ||
    !INSTANT.test(issuedAt) || !DECIMAL.test(total) || !DIGEST.test(digest) || !/^[123]$/.test(situation) ||
    !/^[01]$/.test(operationType)
  ) {
    return null;
  }
  return {
    accessKey,
    emitterDocument,
    emitterName: (text(node, 'xNome') ?? '').slice(0, 150) || 'Emitente sem nome',
    issuedAt,
    operationType: Number(operationType),
    total,
    digest,
    protocolNumber: protocol && /^[0-9]{15}$/.test(protocol) ? protocol : null,
    situation: Number(situation),
  };
}

/** Evento de uma nota (resEvento ou procEventoNFe): a chave e o tipo. */
export function readEvent(xml: string): { accessKey: string; type: string } | null {
  const root = parse(xml);
  const node = child(root, 'resEvento') ?? child(child(child(root, 'procEventoNFe'), 'evento'), 'infEvento');
  if (!node) return null;
  const accessKey = text(node, 'chNFe') ?? '';
  const type = text(node, 'tpEvento') ?? '';
  return isValidAccessKey(accessKey) && /^[0-9]{6}$/.test(type) ? { accessKey, type } : null;
}

/** Chave privada e certificado em PEM, a partir do .pfx. Ficam só na memória. */
export function pemFromPfx(pfx: Buffer, passphrase: string): { key: string; cert: string } {
  try {
    const p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(forge.util.createBuffer(pfx.toString('binary'))), true, passphrase);
    const { pkcs8ShroudedKeyBag, keyBag, certBag } = forge.pki.oids;
    const keys = [...(p12.getBags({ bagType: pkcs8ShroudedKeyBag })[pkcs8ShroudedKeyBag] ?? []), ...(p12.getBags({ bagType: keyBag })[keyBag] ?? [])];
    const key = keys[0]?.key as forge.pki.rsa.PrivateKey | undefined;
    const cert = (p12.getBags({ bagType: certBag })[certBag] ?? [])
      .map((bag) => bag.cert)
      .find((candidate): candidate is forge.pki.Certificate => {
        const publicKey = candidate?.publicKey as forge.pki.rsa.PublicKey | undefined;
        return Boolean(key && publicKey?.n?.equals(key.n) && publicKey.e.equals(key.e));
      });
    if (!key || !cert) throw new Error('chave ou certificado ausente');
    return { key: forge.pki.privateKeyToPem(key), cert: forge.pki.certificateToPem(cert) };
  } catch (cause) {
    throw new AppError('FA912', { cause });
  }
}

/** Data e hora de Brasília, sem horário de verão, um minuto atrás: a Sefaz recusa evento no futuro. */
export function brasiliaNow(now = Date.now()): string {
  return `${new Date(now - 3 * 3_600_000 - 60_000).toISOString().slice(0, 19)}-03:00`;
}

export interface AwarenessRequest {
  environment: 1 | 2;
  cnpj: string;
  accessKey: string;
  at?: string;
}

/** Evento de ciência assinado (RSA-SHA1, C14N, envelopado), como pede o leiaute do evento 1.00. */
export function awarenessEnvelope(request: AwarenessRequest, pem: { key: string; cert: string }): string {
  const id = `ID${AWARENESS_EVENT}${request.accessKey}01`;
  const evento =
    `<evento xmlns="${NFE_NS}" versao="1.00"><infEvento Id="${id}"><cOrgao>91</cOrgao><tpAmb>${request.environment}</tpAmb>` +
    `<CNPJ>${escapeXml(request.cnpj)}</CNPJ><chNFe>${escapeXml(request.accessKey)}</chNFe><dhEvento>${request.at ?? brasiliaNow()}</dhEvento>` +
    `<tpEvento>${AWARENESS_EVENT}</tpEvento><nSeqEvento>1</nSeqEvento><verEvento>1.00</verEvento>` +
    `<detEvento versao="1.00"><descEvento>Ciencia da Operacao</descEvento></detEvento></infEvento></evento>`;
  const signer = new SignedXml({
    privateKey: pem.key,
    publicCert: pem.cert,
    signatureAlgorithm: 'http://www.w3.org/2000/09/xmldsig#rsa-sha1',
    canonicalizationAlgorithm: 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315',
  });
  signer.addReference({
    xpath: "//*[local-name(.)='infEvento']",
    digestAlgorithm: 'http://www.w3.org/2000/09/xmldsig#sha1',
    transforms: [
      'http://www.w3.org/2000/09/xmldsig#enveloped-signature',
      'http://www.w3.org/TR/2001/REC-xml-c14n-20010315',
    ],
  });
  signer.computeSignature(evento, { location: { reference: "//*[local-name(.)='infEvento']", action: 'after' } });
  const lot = String(Date.now()).slice(-15);
  return envelope(
    `<nfeDadosMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeRecepcaoEvento4">` +
      `<envEvento xmlns="${NFE_NS}" versao="1.00"><idLote>${lot}</idLote>${signer.getSignedXml()}</envEvento></nfeDadosMsg>`,
  );
}

export interface EventResult {
  /** 135 e 136: registrado. 573: já estava registrado. */
  registered: boolean;
  status: string;
  message: string;
  protocol: string | null;
}

export function parseEventResponse(xml: string): EventResult {
  const root = parse(xml);
  const ret = child(child(child(child(root, 'Envelope'), 'Body'), 'nfeResultMsg'), 'retEnvEvento') ?? fail('retEnvEvento ausente');
  const events = (ret.retEvento ?? []) as unknown[];
  const info = child(events[0], 'infEvento');
  if (!info) {
    return { registered: false, status: text(ret, 'cStat') ?? '', message: text(ret, 'xMotivo') ?? '', protocol: null };
  }
  const status = text(info, 'cStat') ?? '';
  const protocol = text(info, 'nProt');
  return {
    registered: ['135', '136', '573'].includes(status),
    status,
    message: text(info, 'xMotivo') ?? '',
    protocol: protocol && /^[0-9]{15}$/.test(protocol) ? protocol : null,
  };
}
