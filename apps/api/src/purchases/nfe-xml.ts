import { X509Certificate, createHash } from 'node:crypto';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { XMLParser } from 'fast-xml-parser';
import { SignedXml } from 'xml-crypto';
import { AppError } from '../observability/app-error.js';

const NFE_NS = 'http://www.portalfiscal.inf.br/nfe';
const DSIG_NS = 'http://www.w3.org/2000/09/xmldsig#';
const MAX_ITEMS = 990;
export const MAX_XML_BYTES = 5 * 1024 * 1024;

// A NF-e usa RSA com SHA-1; o SHA-256 fica aceito para quando a Sefaz migrar.
const SIGNATURE_METHODS = new Set([
  'http://www.w3.org/2000/09/xmldsig#rsa-sha1',
  'http://www.w3.org/2001/04/xmldsig-more#rsa-sha256',
]);
const DIGEST_METHODS = new Set(['http://www.w3.org/2000/09/xmldsig#sha1', 'http://www.w3.org/2001/04/xmlenc#sha256']);
const TRANSFORMS = new Set([
  'http://www.w3.org/2000/09/xmldsig#enveloped-signature',
  'http://www.w3.org/TR/2001/REC-xml-c14n-20010315',
]);
// 100: autorizada. 150: autorizada fora do prazo.
const AUTHORIZED = new Set(['100', '150']);

export interface ParsedBatch {
  number: string;
  quantity: string;
  manufacturedOn: string | null;
  expiresOn: string;
}

export interface ParsedItem {
  number: number;
  supplierCode: string;
  barcode: string | null;
  taxBarcode: string | null;
  description: string;
  ncm: string | null;
  cest: string | null;
  cfop: string;
  unit: string;
  quantity: string;
  unitPrice: string;
  productsValue: string;
  discount: string;
  freight: string;
  insurance: string;
  other: string;
  ipi: string;
  st: string;
  fcpSt: string;
  anvisaCode: string | null;
  pmc: string | null;
  batches: ParsedBatch[];
}

export interface ParsedInvoice {
  accessKey: string;
  series: number;
  number: number;
  issuedAt: string;
  operationType: number;
  purpose: number;
  environment: number;
  protocolNumber: string;
  authorizedAt: string;
  destCnpj: string;
  emitter: {
    cnpj: string;
    legalName: string;
    tradeName: string | null;
    stateRegistration: string | null;
    phone: string | null;
    postalCode: string | null;
    street: string | null;
    streetNumber: string | null;
    complement: string | null;
    district: string | null;
    city: string | null;
    cityCode: string | null;
    state: string | null;
  };
  totals: Record<'products' | 'discount' | 'freight' | 'insurance' | 'other' | 'ipi' | 'st' | 'invoice', string>;
  items: ParsedItem[];
}

/** Motivo técnico da recusa: vai para o log, nunca para a tela. */
export class InvalidNfeError extends AppError {
  constructor(readonly reason: string) {
    super('FA930', { cause: new Error(reason) });
  }
}

const fail = (reason: string): never => {
  throw new InvalidNfeError(reason);
};

/** Módulo 11 com pesos de 2 a 9, da direita para a esquerda; letras valem o código ASCII menos 48. */
export function isValidAccessKey(key: string): boolean {
  if (!/^[0-9]{6}[0-9A-Z]{12}[0-9]{26}$/.test(key)) return false;
  let total = 0;
  let weight = 2;
  for (let i = 42; i >= 0; i -= 1) {
    total += (key.charCodeAt(i) - 48) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const remainder = total % 11;
  return Number(key[43]) === (remainder < 2 ? 0 : 11 - remainder);
}

type Node = Record<string, unknown>;

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  removeNSPrefix: true,
  // Tudo como texto: números e códigos com zero à esquerda chegam ao banco do jeito que vieram.
  parseTagValue: false,
  parseAttributeValue: false,
  processEntities: false,
  htmlEntities: false,
  trimValues: true,
  isArray: (name) => name === 'det' || name === 'rastro',
});

const child = (node: unknown, name: string): Node | undefined => {
  const value = (node as Node | undefined)?.[name];
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Node) : undefined;
};
const text = (node: unknown, name: string): string | null => {
  const value = (node as Node | undefined)?.[name];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') return fail(`${name} não é texto`);
  return value === '' ? null : value;
};
const required = (node: unknown, name: string): string => text(node, name) ?? fail(`${name} ausente`);
/** Atributo só como texto: qualquer outra forma é recusada como vazia. */
const attr = (node: unknown, name: string): string => {
  const value = (node as Node | undefined)?.[`@_${name}`];
  return typeof value === 'string' ? value : '';
};
const serialize = (node: Element) => new XMLSerializer().serializeToString(node);
const DECIMAL = /^\d{1,15}(\.\d{1,10})?$/;
const decimal = (node: unknown, name: string, fallback: string | null = '0'): string => {
  const value = text(node, name);
  if (value === null) return fallback ?? fail(`${name} ausente`);
  return DECIMAL.test(value) ? value : fail(`${name} inválido`);
};
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const day = (node: unknown, name: string): string | null => {
  const value = text(node, name);
  if (value === null) return null;
  return DAY.test(value) ? value : fail(`${name} inválido`);
};
const INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?([+-]\d{2}:\d{2}|Z)$/;
const instant = (node: unknown, name: string): string => {
  const value = required(node, name);
  return INSTANT.test(value) && !Number.isNaN(Date.parse(value)) ? value : fail(`${name} inválido`);
};
/** "SEM GTIN" e valores fora do padrão viram vazio: o item só não se liga pelo código de barras. */
const barcode = (value: string | null) => (value && /^[0-9A-Za-z]{1,30}$/.test(value) ? value : null);

function elementChildren(node: { childNodes?: unknown }, ns: string, localName: string) {
  const result: Element[] = [];
  const nodes = (node.childNodes ?? []) as ArrayLike<Element>;
  for (let i = 0; i < nodes.length; i += 1) {
    const candidate = nodes[i];
    if (candidate.nodeType === 1 && candidate.namespaceURI === ns && candidate.localName === localName) {
      result.push(candidate);
    }
  }
  return result;
}
const only = (elements: Element[], what: string): Element =>
  elements.length === 1 ? elements[0] : fail(`${what}: ${elements.length} encontrados`);

/** Valor das alíquotas de ST da nota (vICMSST e vFCPST), venha de qual grupo de ICMS vier. */
function icmsGroup(tax: Node | undefined): Node | undefined {
  const icms = child(tax, 'ICMS');
  if (!icms) return undefined;
  const groups = Object.values(icms).filter((value) => value && typeof value === 'object');
  return groups.length === 1 ? (groups[0] as Node) : undefined;
}

function parseItem(det: Node): ParsedItem {
  const number = Number(attr(det, 'nItem'));
  if (!Number.isInteger(number) || number < 1 || number > MAX_ITEMS) fail('nItem inválido');
  const prod = child(det, 'prod') ?? fail('prod ausente');
  const tax = child(det, 'imposto');
  const icms = icmsGroup(tax);
  const ipi = child(child(tax, 'IPI'), 'IPITrib');
  const med = child(prod, 'med');
  const rastro = ((prod as Node).rastro as Node[] | undefined) ?? [];
  return {
    number,
    supplierCode: required(prod, 'cProd'),
    barcode: barcode(text(prod, 'cEAN')),
    taxBarcode: barcode(text(prod, 'cEANTrib')),
    description: required(prod, 'xProd'),
    ncm: text(prod, 'NCM'),
    cest: text(prod, 'CEST'),
    cfop: required(prod, 'CFOP'),
    unit: required(prod, 'uCom'),
    quantity: decimal(prod, 'qCom', null),
    unitPrice: decimal(prod, 'vUnCom', null),
    productsValue: decimal(prod, 'vProd', null),
    discount: decimal(prod, 'vDesc'),
    freight: decimal(prod, 'vFrete'),
    insurance: decimal(prod, 'vSeg'),
    other: decimal(prod, 'vOutro'),
    ipi: decimal(ipi, 'vIPI'),
    st: decimal(icms, 'vICMSST'),
    fcpSt: decimal(icms, 'vFCPST'),
    anvisaCode: text(med, 'cProdANVISA'),
    pmc: med ? decimal(med, 'vPMC', null) : null,
    batches: rastro.map((batch) => ({
      number: required(batch, 'nLote'),
      quantity: decimal(batch, 'qLote', null),
      manufacturedOn: day(batch, 'dFab'),
      expiresOn: day(batch, 'dVal') ?? fail('dVal ausente'),
    })),
  };
}

/**
 * Confere a NF-e autorizada e devolve os dados para o banco. Os dados saem só do trecho que a
 * assinatura cobre, já canonizado pela própria verificação: um bloco falso posto fora dele é ignorado.
 */
export function readAuthorizedNfe(xml: string): ParsedInvoice {
  if (Buffer.byteLength(xml, 'utf8') > MAX_XML_BYTES) fail('arquivo grande demais');
  // DOCTYPE abre a porta para entidades externas e expansão de texto: a NF-e não usa.
  if (/<!DOCTYPE|<!ENTITY/i.test(xml)) fail('DOCTYPE no XML');

  const doc = new DOMParser({
    errorHandler: {
      warning: () => undefined,
      error: (message: string) => fail(`XML malformado: ${message}`),
      fatalError: (message: string) => fail(`XML malformado: ${message}`),
    },
  }).parseFromString(xml, 'text/xml');
  const root = doc.documentElement;
  if (!root || root.namespaceURI !== NFE_NS || root.localName !== 'nfeProc') fail('a raiz não é nfeProc');

  const nfe = only(elementChildren(root, NFE_NS, 'NFe'), 'NFe');
  const infNfe = only(elementChildren(nfe, NFE_NS, 'infNFe'), 'infNFe');
  const signatureNode = only(elementChildren(nfe, DSIG_NS, 'Signature'), 'Signature');
  const protNfe = only(elementChildren(root, NFE_NS, 'protNFe'), 'protNFe');

  const id = infNfe.getAttribute('Id') ?? '';
  const key = /^NFe([0-9A-Z]{44})$/.exec(id)?.[1] ?? fail('Id da infNFe inválido');
  if (!isValidAccessKey(key)) fail('dígito da chave');
  // Outro elemento com o mesmo Id faria a referência apontar para o lugar errado.
  const sameId = xml.split(`"${id}"`).length - 1 + xml.split(`'${id}'`).length - 1;
  if (sameId !== 1) fail('Id repetido');

  const signature = parser.parse(serialize(signatureNode)) as Node;
  const signedInfo = child(child(signature, 'Signature'), 'SignedInfo') ?? fail('SignedInfo ausente');
  if (Array.isArray((signedInfo as Node).Reference)) fail('mais de uma referência');
  const reference = child(signedInfo, 'Reference') ?? fail('Reference ausente');
  if (attr(reference, 'URI') !== `#${id}`) fail('a referência não aponta para a nota');
  const signatureMethod = attr(child(signedInfo, 'SignatureMethod'), 'Algorithm');
  if (!SIGNATURE_METHODS.has(signatureMethod)) fail('algoritmo de assinatura');
  const digestMethod = attr(child(reference, 'DigestMethod'), 'Algorithm');
  if (!DIGEST_METHODS.has(digestMethod)) fail('algoritmo de resumo');
  const transforms = (child(reference, 'Transforms')?.Transform ?? []) as Node | Node[];
  for (const transform of Array.isArray(transforms) ? transforms : [transforms]) {
    if (!TRANSFORMS.has(attr(transform, 'Algorithm'))) fail('transformação não aceita');
  }
  const digestValue = required(reference, 'DigestValue');
  const certificateText = (
    text(child(child(child(signature, 'Signature'), 'KeyInfo'), 'X509Data'), 'X509Certificate') ?? ''
  ).replace(/\s+/g, '');
  if (!certificateText) fail('certificado ausente');
  let publicCert: string;
  try {
    publicCert = new X509Certificate(Buffer.from(certificateText, 'base64')).toString();
  } catch {
    return fail('certificado ilegível');
  }

  const verifier = new SignedXml({ publicCert });
  verifier.loadSignature(signatureNode);
  let valid = false;
  try {
    valid = verifier.checkSignature(xml);
  } catch (error) {
    fail(`assinatura: ${(error as Error).message}`);
  }
  if (!valid) fail('assinatura inválida');
  const signed = verifier.getSignedReferences();
  if (signed.length !== 1) fail('trecho assinado');

  const content = parser.parse(signed[0]) as Node;
  const inf = child(content, 'infNFe') ?? fail('o trecho assinado não é a infNFe');
  if (attr(inf, 'Id') !== id) fail('o trecho assinado é de outra nota');
  const ide = child(inf, 'ide') ?? fail('ide ausente');
  const emit = child(inf, 'emit') ?? fail('emit ausente');
  const address = child(emit, 'enderEmit');
  const dest = child(inf, 'dest') ?? fail('dest ausente');
  const totals = child(child(inf, 'total'), 'ICMSTot') ?? fail('ICMSTot ausente');
  const dets = ((inf as Node).det as Node[] | undefined) ?? [];
  if (dets.length === 0 || dets.length > MAX_ITEMS) fail('quantidade de itens');

  if (required(ide, 'mod') !== '55') fail('modelo diferente de 55');
  const emitterCnpj = text(emit, 'CNPJ') ?? fail('emitente sem CNPJ');
  const destCnpj = text(dest, 'CNPJ') ?? fail('destinatário sem CNPJ');
  const series = required(ide, 'serie');
  const number = required(ide, 'nNF');
  const issuedAt = instant(ide, 'dhEmi');
  if (!/^\d{1,3}$/.test(series) || !/^\d{1,9}$/.test(number)) fail('série ou número');
  // A chave repete dados da nota: se não batem, a chave é de outra.
  const expected =
    required(ide, 'cUF') + issuedAt.slice(2, 4) + issuedAt.slice(5, 7) + emitterCnpj + '55' +
    series.padStart(3, '0') + number.padStart(9, '0') + required(ide, 'tpEmis') + required(ide, 'cNF');
  if (key.slice(0, 43) !== expected) fail('a chave não bate com a nota');

  const protocol = parser.parse(serialize(protNfe)) as Node;
  const infProt = child(child(protocol, 'protNFe'), 'infProt') ?? fail('infProt ausente');
  if (required(infProt, 'chNFe') !== key) fail('protocolo de outra nota');
  if (!AUTHORIZED.has(required(infProt, 'cStat'))) fail('nota não autorizada');
  // O digVal do protocolo é o resumo que a Sefaz recebeu: amarra o protocolo a este conteúdo.
  if (required(infProt, 'digVal') !== digestValue) fail('protocolo de outro conteúdo');
  const environment = required(ide, 'tpAmb');
  if (required(infProt, 'tpAmb') !== environment || !/^[12]$/.test(environment)) fail('ambiente');
  const protocolNumber = required(infProt, 'nProt');
  if (!/^\d{15}$/.test(protocolNumber)) fail('número do protocolo');

  const operationType = required(ide, 'tpNF');
  const purpose = required(ide, 'finNFe');
  if (!/^[01]$/.test(operationType) || !/^[1-4]$/.test(purpose)) fail('tipo ou finalidade');

  return {
    accessKey: key,
    series: Number(series),
    number: Number(number),
    issuedAt,
    operationType: Number(operationType),
    purpose: Number(purpose),
    environment: Number(environment),
    protocolNumber,
    authorizedAt: instant(infProt, 'dhRecbto'),
    destCnpj,
    emitter: {
      cnpj: emitterCnpj,
      legalName: required(emit, 'xNome'),
      tradeName: text(emit, 'xFant'),
      stateRegistration: text(emit, 'IE'),
      phone: text(address, 'fone'),
      postalCode: text(address, 'CEP'),
      street: text(address, 'xLgr'),
      streetNumber: text(address, 'nro'),
      complement: text(address, 'xCpl'),
      district: text(address, 'xBairro'),
      city: text(address, 'xMun'),
      cityCode: text(address, 'cMun'),
      state: text(address, 'UF'),
    },
    totals: {
      products: decimal(totals, 'vProd', null),
      discount: decimal(totals, 'vDesc'),
      freight: decimal(totals, 'vFrete'),
      insurance: decimal(totals, 'vSeg'),
      other: decimal(totals, 'vOutro'),
      ipi: decimal(totals, 'vIPI'),
      st: decimal(totals, 'vST'),
      invoice: decimal(totals, 'vNF', null),
    },
    items: dets.map(parseItem),
  };
}

export const sha256 = (xml: string) => createHash('sha256').update(xml, 'utf8').digest('hex');
