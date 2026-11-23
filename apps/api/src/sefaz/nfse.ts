import { gunzipSync } from 'node:zlib';
import { XMLParser } from 'fast-xml-parser';
import { AppError } from '../observability/app-error.js';
import { MAX_XML_BYTES } from '../purchases/nfe-xml.js';

// NFS-e do padrão nacional pelo Ambiente de Dados Nacional (ADN). A estrutura segue o modelo da
// NFS-e autorizada publicado pela Receita Federal (gerador de DANFSe): NFSe/infNFSe, com a DPS
// dentro. Só o essencial é obrigatório; o resto fica vazio se não vier ou não estiver no formato.

/** Lotes de até 50 documentos por chamada. */
export const NFSE_BATCH_SIZE = 50;
const DOCUMENT_TYPES = new Set(['NFSE', 'EVENTO', 'DPS']);

/** Pedido por NSU: o ADN devolve os documentos com NSU maior que o informado. */
export function nfseDistributionUrl(base: string, lastNsu: string, cnpj: string): string {
  const nsu = String(BigInt(lastNsu || '0'));
  return `${base.replace(/\/$/, '')}/DFe/${nsu}?cnpjConsulta=${encodeURIComponent(cnpj)}&lote=true`;
}

export interface NfseDocument {
  nsu: string;
  type: 'NFSE' | 'EVENTO' | 'DPS';
  accessKey: string | null;
  xml: string;
}

export interface NfseDistribution {
  /** Situação do processamento, em maiúsculas e sem espaço, para guardar e mostrar. */
  status: string | null;
  /** Rejeitada pelo ADN (400 com REJEICAO): o motivo vem em message. */
  rejected: boolean;
  message: string;
  documents: NfseDocument[];
  skipped: { nsu: string; reason: string }[];
  /** Maior NSU recebido, já com 15 posições. */
  lastNsu: string | null;
}

type Json = Record<string, unknown>;

const fail = (reason: string): never => {
  throw new AppError('FA944', { cause: new Error(reason) });
};

/** Base64 normal ou de URL, com ou sem gzip. Limite de 5 MB aberto. */
export function decodeNfseXml(content: string): string {
  const raw = Buffer.from(content.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  const bytes = raw[0] === 0x1f && raw[1] === 0x8b ? gunzipSync(raw, { maxOutputLength: MAX_XML_BYTES }) : raw;
  if (bytes.length > MAX_XML_BYTES) throw new Error('XML grande demais');
  return bytes.toString('utf8');
}

const field = (item: Json, name: string): unknown => item[name] ?? item[name.charAt(0).toLowerCase() + name.slice(1)];
/** Campo de texto: qualquer outra forma conta como vazio. */
const textField = (item: Json, name: string): string => {
  const value = field(item, name);
  return typeof value === 'string' ? value : '';
};

/** Abre a resposta do ADN. 404 com corpo é "nada encontrado"; 400 com REJEICAO é recusa. */
export function parseNfseDistribution(httpStatus: number, body: string): NfseDistribution {
  if (httpStatus === 429 || httpStatus >= 500) fail(`HTTP ${httpStatus}`);
  if (httpStatus === 401 || httpStatus === 403) throw new AppError('FA948', { cause: new Error(`HTTP ${httpStatus}`) });
  let json: Json;
  try {
    json = JSON.parse(body) as Json;
  } catch {
    if (httpStatus === 404) return { status: 'NENHUM_DOCUMENTO_LOCALIZADO', rejected: false, message: '', documents: [], skipped: [], lastNsu: null };
    return fail(`resposta não é JSON (HTTP ${httpStatus})`);
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) fail('resposta fora do formato');
  const rawStatus = field(json, 'StatusProcessamento');
  const status = typeof rawStatus === 'string' ? rawStatus.toUpperCase().replace(/[^A-Z_]/g, '_').slice(0, 40) || null : null;
  const errors = (Array.isArray(field(json, 'Erros')) ? (field(json, 'Erros') as Json[]) : [])
    .map((error) => [field(error, 'Codigo'), field(error, 'Descricao'), field(error, 'Complemento')].filter((part) => typeof part === 'string' && part).join(' '))
    .filter(Boolean);
  const rejected = status === 'REJEICAO' || (httpStatus === 400);
  if (![200, 400, 404].includes(httpStatus)) fail(`HTTP ${httpStatus}`);

  const documents: NfseDocument[] = [];
  const skipped: { nsu: string; reason: string }[] = [];
  let highest: bigint | null = null;
  const lot = Array.isArray(field(json, 'LoteDFe')) ? (field(json, 'LoteDFe') as Json[]) : [];
  for (const item of lot) {
    const rawNsu = field(item, 'NSU');
    const nsuText = typeof rawNsu === 'number' || typeof rawNsu === 'string' ? String(rawNsu) : '';
    if (!/^[0-9]{1,15}$/.test(nsuText)) {
      skipped.push({ nsu: nsuText, reason: 'NSU fora do formato' });
      continue;
    }
    const nsu = nsuText.padStart(15, '0');
    if (highest === null || BigInt(nsuText) > highest) highest = BigInt(nsuText);
    const type = textField(item, 'TipoDocumento').toUpperCase();
    const key = textField(item, 'ChaveAcesso');
    const content = field(item, 'ArquivoXml');
    if (!DOCUMENT_TYPES.has(type) || typeof content !== 'string' || !content) {
      skipped.push({ nsu, reason: `tipo ${type || 'vazio'} ou sem arquivo` });
      continue;
    }
    try {
      documents.push({
        nsu,
        type: type as NfseDocument['type'],
        accessKey: /^[0-9]{50}$/.test(key) ? key : null,
        xml: decodeNfseXml(content),
      });
    } catch (error) {
      skipped.push({ nsu, reason: `não abriu: ${(error as NodeJS.ErrnoException).code ?? (error as Error).message}` });
    }
  }
  return {
    status,
    rejected,
    message: errors.join('; ').slice(0, 500),
    documents,
    skipped,
    lastNsu: highest === null ? null : String(highest).padStart(15, '0'),
  };
}

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

type Node = Record<string, unknown>;
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

/** Nota fora do formato: o motivo vai para o log. */
export class InvalidNfseError extends AppError {
  constructor(readonly reason: string) {
    super('FA931', { cause: new Error(reason) });
  }
}
const invalid = (reason: string): never => {
  throw new InvalidNfseError(reason);
};

const DECIMAL = /^\d{1,13}(\.\d{1,2})?$/;
const RATE = /^\d{1,3}(\.\d{1,4})?$/;
const INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:\d{2}|Z)$/;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const DOCUMENT = /^([0-9]{11}|[0-9A-Z]{12}[0-9]{2})$/;

const money = (node: unknown, name: string): string | null => {
  const value = text(node, name);
  return value !== null && DECIMAL.test(value) ? value : null;
};
const requiredMoney = (node: unknown, name: string): string => money(node, name) ?? invalid(`${name} ausente ou inválido`);
const code = (node: unknown, name: string, pattern: RegExp): string | null => {
  const value = text(node, name);
  return value !== null && pattern.test(value) ? value : null;
};
const documentOf = (node: unknown): string | null => {
  const value = text(node, 'CNPJ') ?? text(node, 'CPF');
  return value && DOCUMENT.test(value) ? value : null;
};

export interface ServiceInvoiceData {
  accessKey: string;
  number: string;
  environment: number;
  issuedAt: string;
  competence: string;
  processedAt: string | null;
  providerDocument: string | null;
  providerName: string;
  providerLocation: string | null;
  takerDocument: string | null;
  serviceCode: string | null;
  municipalCode: string | null;
  nbsCode: string | null;
  description: string;
  incidenceLocation: string | null;
  serviceValue: string;
  unconditionalDiscount: string | null;
  deductions: string | null;
  issBase: string | null;
  issRate: string | null;
  issValue: string | null;
  issWithholding: number | null;
  irrf: string | null;
  csll: string | null;
  socialSecurity: string | null;
  pis: string | null;
  cofins: string | null;
  pisCofinsWithholding: number | null;
  totalWithheld: string | null;
  netValue: string;
  replacesKey: string | null;
}

function parseXml(xml: string): Node {
  if (Buffer.byteLength(xml, 'utf8') > MAX_XML_BYTES) invalid('arquivo grande demais');
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) invalid('DOCTYPE no XML');
  try {
    return parser.parse(xml) as Node;
  } catch (error) {
    return invalid(`XML malformado: ${(error as Error).message}`);
  }
}

/** Lê a NFS-e autorizada (NFSe/infNFSe, com a DPS dentro). */
export function readServiceInvoice(xml: string): ServiceInvoiceData {
  const root = child(parseXml(xml), 'NFSe') ?? invalid('a raiz não é NFSe');
  const inf = child(root, 'infNFSe') ?? invalid('infNFSe ausente');
  const accessKey = /^NFS([0-9]{50})$/.exec(attr(inf, 'Id'))?.[1] ?? invalid('Id da infNFSe inválido');
  const number = text(inf, 'nNFSe');
  if (!number || !/^[0-9]{1,15}$/.test(number)) invalid('nNFSe inválido');
  const emit = child(inf, 'emit') ?? invalid('emit ausente');
  const totals = child(inf, 'valores') ?? invalid('valores ausente');
  const dps = child(child(inf, 'DPS'), 'infDPS') ?? invalid('DPS ausente');
  const serv = child(dps, 'serv');
  const cServ = child(serv, 'cServ');
  const values = child(dps, 'valores');
  const trib = child(values, 'trib');
  const tribMun = child(trib, 'tribMun');
  const tribFed = child(trib, 'tribFed');
  const pisCofins = child(tribFed, 'piscofins');

  const environment = text(dps, 'tpAmb');
  if (environment !== '1' && environment !== '2') invalid('tpAmb inválido');
  const issuedAt = text(dps, 'dhEmi');
  if (!issuedAt || !INSTANT.test(issuedAt)) invalid('dhEmi inválido');
  const competence = text(dps, 'dCompet');
  if (!competence || !DAY.test(competence)) invalid('dCompet inválido');
  const processedAt = text(inf, 'dhProc');
  const providerName = text(emit, 'xNome') ?? invalid('emitente sem nome');
  const description = text(cServ, 'xDescServ') ?? invalid('xDescServ ausente');
  const withholding = text(tribMun, 'tpRetISSQN');
  const pisCofinsWithholding = text(pisCofins, 'tpRetPisCofins');
  const replaces = text(child(dps, 'subst'), 'chSubstda');
  const rate = text(totals, 'pAliqAplic');

  return {
    accessKey,
    number: number as string,
    environment: Number(environment),
    issuedAt: issuedAt as string,
    competence: competence as string,
    processedAt: processedAt && INSTANT.test(processedAt) ? processedAt : null,
    providerDocument: documentOf(emit),
    providerName: providerName.slice(0, 300),
    providerLocation: text(inf, 'xLocEmi')?.slice(0, 150) ?? null,
    takerDocument: documentOf(child(dps, 'toma')),
    serviceCode: code(cServ, 'cTribNac', /^[0-9]{6}$/),
    municipalCode: text(cServ, 'cTribMun')?.slice(0, 20) ?? null,
    nbsCode: code(cServ, 'cNBS', /^[0-9]{9}$/),
    description: description.slice(0, 2000),
    incidenceLocation: text(inf, 'xLocIncid')?.slice(0, 150) ?? null,
    serviceValue: requiredMoney(child(values, 'vServPrest'), 'vServ'),
    unconditionalDiscount: money(child(values, 'vDescCondIncond'), 'vDescIncond'),
    deductions: money(totals, 'vCalcDR'),
    issBase: money(totals, 'vBC'),
    issRate: rate && RATE.test(rate) ? rate : null,
    issValue: money(totals, 'vISSQN'),
    issWithholding: withholding && /^[123]$/.test(withholding) ? Number(withholding) : null,
    irrf: money(tribFed, 'vRetIRRF'),
    csll: money(tribFed, 'vRetCSLL'),
    socialSecurity: money(tribFed, 'vRetCP'),
    pis: money(pisCofins, 'vPis'),
    cofins: money(pisCofins, 'vCofins'),
    pisCofinsWithholding: pisCofinsWithholding && /^[0-9]$/.test(pisCofinsWithholding) ? Number(pisCofinsWithholding) : null,
    totalWithheld: money(totals, 'vTotalRet'),
    netValue: requiredMoney(totals, 'vLiq'),
    replacesKey: replaces && /^[0-9]{50}$/.test(replaces) ? replaces : null,
  };
}

export interface ServiceInvoiceEvent {
  accessKey: string;
  kind: 'cancel' | 'replace' | 'other';
  substituteKey: string | null;
}

/** Evento da NFS-e: cancelamento (e101101) ou cancelamento por substituição (e105102). */
export function readServiceEvent(xml: string, fallbackKey: string | null): ServiceInvoiceEvent | null {
  parseXml(xml);
  const accessKey = /<(?:[A-Za-z0-9_]+:)?chNFSe>\s*([0-9]{50})\s*</.exec(xml)?.[1] ?? fallbackKey;
  if (!accessKey) return null;
  const substituteKey = /<(?:[A-Za-z0-9_]+:)?chSubstituta>\s*([0-9]{50})\s*</.exec(xml)?.[1] ?? null;
  const kind = /<(?:[A-Za-z0-9_]+:)?e105102[\s>]/.test(xml) ? 'replace' : /<(?:[A-Za-z0-9_]+:)?e101101[\s>]/.test(xml) ? 'cancel' : 'other';
  return { accessKey, kind, substituteKey };
}
