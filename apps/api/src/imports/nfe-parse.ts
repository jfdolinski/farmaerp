import { XMLParser } from 'fast-xml-parser';

/** Nota lida do XML, no formato que app.import_nfce espera. */
export interface ImportedNote {
  access_key: string;
  model: string;
  series: number;
  number: number;
  emitted_at: string;
  environment: string;
  /** tpNF: 0 entrada, 1 saída (NF-e). */
  operation: string;
  status_code: string;
  protocol: string | null;
  issuer: Record<string, string | null>;
  customer: { document: string; name: string | null } | null;
  /** Destinatário completo (NF-e): para achar a filial do cliente, o fornecedor ou o cliente. */
  dest: Record<string, string | null> | null;
  items: Record<string, unknown>[];
  payments: Record<string, unknown>[];
  subtotal: number;
  discount: number;
  total: number;
  change: number;
  xml: string;
}

/** O que uma entrada do arquivo contém. */
export type ParsedEntry =
  | { kind: 'note'; note: ImportedNote }
  | { kind: 'cancel'; accessKey: string; canceledAt: string | null }
  | { kind: 'other'; model: string | null; accessKey: string | null; reason: string }
  | { kind: 'invalid'; reason: string };

type Node = Record<string, unknown>;

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  removeNSPrefix: true,
  // Tudo como texto: CNPJ, CEP e códigos têm zeros à esquerda.
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true,
  isArray: (name) => name === 'det' || name === 'detPag' || name === 'rastro',
});

const obj = (value: unknown): Node | null => (value && typeof value === 'object' && !Array.isArray(value) ? (value as Node) : null);
const text = (node: Node | null, name: string): string | null => {
  const value = node?.[name];
  if (typeof value === 'string') return value.trim() === '' ? null : value.trim();
  if (typeof value === 'number') return String(value);
  return null;
};
const num = (node: Node | null, name: string): number | null => {
  const value = text(node, name);
  if (value === null) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
};
const list = (value: unknown): Node[] => (Array.isArray(value) ? value.map(obj).filter((n): n is Node => n !== null) : []);
/** Primeiro filho do grupo (ex.: ICMS > ICMS00, ICMSSN102...). */
const firstChild = (node: Node | null): Node | null => {
  if (!node) return null;
  for (const value of Object.values(node)) {
    const child = obj(value);
    if (child) return child;
  }
  return null;
};

/** Dados e endereço de uma parte da nota (emitente ou destinatário). */
function party(node: Node | null, address: Node | null): Record<string, string | null> {
  return {
    cnpj: text(node, 'CNPJ'),
    cpf: text(node, 'CPF'),
    name: text(node, 'xNome'),
    trade_name: text(node, 'xFant'),
    state_registration: text(node, 'IE'),
    crt: text(node, 'CRT'),
    street: text(address, 'xLgr'),
    number: text(address, 'nro'),
    complement: text(address, 'xCpl'),
    district: text(address, 'xBairro'),
    city_code: text(address, 'cMun'),
    city: text(address, 'xMun'),
    uf: text(address, 'UF'),
    postal_code: text(address, 'CEP'),
    phone: text(address, 'fone'),
  };
}

/** Tributação do item: ICMS (CST ou CSOSN), PIS, COFINS e o benefício fiscal. */
function itemTax(imposto: Node | null, prod: Node | null) {
  const icms = firstChild(obj(imposto?.ICMS));
  const pis = firstChild(obj(imposto?.PIS));
  const cofins = firstChild(obj(imposto?.COFINS));
  return {
    origin: num(icms, 'orig') ?? 0,
    icms_cst: text(icms, 'CST'),
    icms_csosn: text(icms, 'CSOSN'),
    icms_rate: num(icms, 'pICMS'),
    pis_cst: text(pis, 'CST'),
    pis_rate: num(pis, 'pPIS'),
    cofins_cst: text(cofins, 'CST'),
    cofins_rate: num(cofins, 'pCOFINS'),
    benefit_code: text(prod, 'cBenef'),
  };
}

/** Emitente: sempre com CNPJ (sem o campo de CPF). */
function issuerOf(emit: Node | null): Record<string, string | null> {
  const { cpf: _cpf, ...rest } = party(emit, obj(emit?.enderEmit));
  return rest;
}

function parseNote(nfe: Node, protocol: Node | null, xml: string): ParsedEntry {
  const inf = obj(nfe.infNFe);
  if (!inf) return { kind: 'invalid', reason: 'NF-e sem infNFe.' };
  const ide = obj(inf.ide);
  const model = text(ide, 'mod');
  const key = text(protocol, 'chNFe') ?? (typeof inf['@_Id'] === 'string' ? inf['@_Id'].replace(/^NFe/, '') : null);
  if (model !== '65' && model !== '55') {
    return { kind: 'other', model, accessKey: key, reason: `Modelo ${model ?? '?'}: entra numa próxima etapa da importação.` };
  }
  const emit = obj(inf.emit);
  const dest = obj(inf.dest);
  const total = obj(obj(inf.total)?.ICMSTot);
  const pag = obj(inf.pag);
  const document = text(dest, 'CPF') ?? text(dest, 'CNPJ');
  return {
    kind: 'note',
    note: {
      access_key: key ?? '',
      model,
      series: num(ide, 'serie') ?? 0,
      number: num(ide, 'nNF') ?? 0,
      emitted_at: text(ide, 'dhEmi') ?? '',
      environment: text(ide, 'tpAmb') ?? '',
      operation: text(ide, 'tpNF') ?? '1',
      status_code: text(protocol, 'cStat') ?? '',
      protocol: text(protocol, 'nProt'),
      issuer: issuerOf(emit),
      dest: model === '55' && dest ? party(dest, obj(dest.enderDest)) : null,
      customer: document ? { document, name: text(dest, 'xNome') } : null,
      items: list(inf.det).map((det) => {
        const prod = obj(det.prod);
        const med = obj(prod?.med);
        const gtin = text(prod, 'cEAN');
        const taxGtin = text(prod, 'cEANTrib');
        const imposto = obj(det.imposto);
        const icms = firstChild(obj(imposto?.ICMS));
        const ipi = obj(obj(imposto?.IPI)?.IPITrib);
        return {
          line: Number(det['@_nItem'] ?? 0),
          code: text(prod, 'cProd'),
          gtin: gtin && /^\d{8,14}$/.test(gtin) ? gtin : null,
          tax_gtin: taxGtin && /^\d{8,14}$/.test(taxGtin) ? taxGtin : null,
          name: text(prod, 'xProd'),
          ncm: text(prod, 'NCM'),
          cest: text(prod, 'CEST'),
          unit: text(prod, 'uCom'),
          quantity: num(prod, 'qCom'),
          unit_price: num(prod, 'vUnCom'),
          discount: num(prod, 'vDesc') ?? 0,
          products_value: num(prod, 'vProd') ?? 0,
          freight: num(prod, 'vFrete') ?? 0,
          insurance: num(prod, 'vSeg') ?? 0,
          other: num(prod, 'vOutro') ?? 0,
          ipi: num(ipi, 'vIPI') ?? 0,
          st: num(icms, 'vICMSST') ?? 0,
          fcp_st: num(icms, 'vFCPST') ?? 0,
          total: Math.round(((num(prod, 'vProd') ?? 0) - (num(prod, 'vDesc') ?? 0)) * 100) / 100,
          cfop: text(prod, 'CFOP'),
          tax: itemTax(imposto, prod),
          anvisa_code: text(med, 'cProdANVISA'),
          pmc: num(med, 'vPMC'),
          info: text(det, 'infAdProd'),
          // Lotes (rastro): só registro, sem saldo por lote.
          batches: list(prod?.rastro).map((batch) => ({
            number: text(batch, 'nLote'),
            quantity: num(batch, 'qLote'),
            manufactured_on: text(batch, 'dFab'),
            expires_on: text(batch, 'dVal'),
          })),
        };
      }),
      payments: list(pag?.detPag).map((payment) => {
        const card = obj(payment.card);
        return {
          type: text(payment, 'tPag'),
          description: text(payment, 'xPag'),
          amount: num(payment, 'vPag') ?? 0,
          card_brand: text(card, 'tBand'),
          authorization: text(card, 'cAut'),
        };
      }),
      subtotal: num(total, 'vProd') ?? 0,
      discount: num(total, 'vDesc') ?? 0,
      total: num(total, 'vNF') ?? 0,
      change: num(pag, 'vTroco') ?? 0,
      xml,
    },
  };
}

/** Lê uma entrada do arquivo: nota com protocolo, cancelamento, outro documento ou lixo. */
export function parseEntry(xml: string): ParsedEntry {
  let document: Node;
  try {
    document = parser.parse(xml) as Node;
  } catch {
    return { kind: 'invalid', reason: 'XML fora do formato.' };
  }
  const proc = obj(document.nfeProc);
  if (proc) {
    const nfe = obj(proc.NFe);
    if (!nfe) return { kind: 'invalid', reason: 'nfeProc sem a NF-e.' };
    return parseNote(nfe, obj(obj(proc.protNFe)?.infProt), xml);
  }
  const loose = obj(document.NFe);
  if (loose) {
    const parsed = parseNote(loose, null, xml);
    // Sem protocolo: não autorizada (o banco registra como ignorada).
    return parsed;
  }
  const event = obj(document.procEventoNFe) ?? document;
  const info = obj(obj(event.evento)?.infEvento);
  if (info) {
    const type = text(info, 'tpEvento');
    const result = obj(obj(event.retEvento)?.infEvento);
    const accepted = ['135', '136', '155'].includes(text(result, 'cStat') ?? '');
    if (type === '110111' && accepted) {
      return { kind: 'cancel', accessKey: text(info, 'chNFe') ?? '', canceledAt: text(info, 'dhEvento') };
    }
    return { kind: 'other', model: null, accessKey: text(info, 'chNFe'), reason: `Evento ${type ?? '?'} sem efeito na importação.` };
  }
  return { kind: 'invalid', reason: 'Arquivo que não é nota nem evento.' };
}
