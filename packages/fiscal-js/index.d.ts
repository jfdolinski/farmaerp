export interface NfeParty {
  cnpj?: string | null;
  cpf?: string | null;
  street: string;
  number: string;
  complement?: string | null;
  district: string;
  cityCode: string;
  city: string;
  uf: string;
  postalCode: string;
  phone?: string | null;
}

export interface NfeIssuer extends NfeParty {
  cnpj: string;
  stateRegistration: string;
  legalName: string;
  tradeName?: string | null;
  /** CRT: 1 Simples, 2 Simples excesso, 3 normal, 4 MEI. */
  taxRegime: number;
}

export interface NfeRecipient extends NfeParty {
  name: string;
  /** indIEDest: 1 contribuinte, 2 isento, 9 não contribuinte. */
  ieIndicator: 1 | 2 | 9;
  stateRegistration?: string | null;
  email?: string | null;
}

export interface NfeItem {
  code: string;
  gtin?: string | null;
  description: string;
  ncm: string;
  cest?: string | null;
  unit?: string;
  quantityMilli: number;
  unitPriceCents: number;
  grossCents: number;
  discountCents?: number;
  freightCents?: number;
  insuranceCents?: number;
  otherCents?: number;
  ipiReturnedCents?: number;
  returnPercent?: number | null;
  /** Tributação do item: cfop, origin, icms_cst ou icms_csosn, alíquotas, pis_cst, cofins_cst... */
  tax: Record<string, unknown>;
}

export interface NfeInput {
  issuer: NfeIssuer;
  recipient: NfeRecipient;
  items: NfeItem[];
  payments?: { type: string; cents: number; description?: string | null }[];
  series: number;
  number: number;
  /** Instante da emissão (ISO 8601). */
  emittedAt: string;
  environment: 1 | 2;
  numericCode: string;
  appVersion: string;
  operation: string;
  /** finNFe: 1 normal, 4 devolução. */
  purpose?: 1 | 4;
  presence?: number;
  finalConsumer?: boolean | null;
  references?: string[];
  freightMode?: number;
  additionalInfo?: string | null;
  ibsCbs?: boolean;
  /** tpEmis: 1 normal; 6 SVC-AN, 7 SVC-RS (contingência, com contingencyAt e contingencyReason). */
  emissionType?: 1 | 6 | 7;
  /** Hora da entrada em contingência (ISO 8601). */
  contingencyAt?: string;
  /** Motivo da contingência (15 a 256 caracteres). */
  contingencyReason?: string;
}

/** Sefaz Virtual de Contingência da UF: 6 SVC-AN, 7 SVC-RS; null se a UF não estiver na tabela. */
export function svcEmissionType(uf: string): 6 | 7 | null;

export type NfeResult =
  | { accessKey: string; xml: string; totalCents: number; error?: undefined }
  | { error: { code: string; detail: string } };

export function buildNfe(input: NfeInput, keyPem: string, certPem: string): NfeResult;
export function buildDanfe(xml: string): Promise<Buffer>;
