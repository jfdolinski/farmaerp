import { AppError } from '../observability/app-error.js';

/**
 * Só os dados do cadastro saem daqui. As respostas trazem também sócios, com nome e parte do CPF,
 * e isso nunca é repassado nem gravado em log.
 */
export interface CnpjData {
  source: 'brasilapi' | 'receitaws' | 'cnpja';
  legalName: string | null;
  tradeName: string | null;
  active: boolean;
  statusText: string | null;
  postalCode: string | null;
  street: string | null;
  streetNumber: string | null;
  complement: string | null;
  district: string | null;
  city: string | null;
  cityCode: string | null;
  state: string | null;
  phone: string | null;
  email: string | null;
}

type Fetcher = (url: string, init: RequestInit) => Promise<Response>;
type Json = Record<string, unknown>;

const TIMEOUT_MS = 5_000;
// Os serviços recusam chamada sem identificação. Nome genérico do sistema, sem dado de ninguém.
const HEADERS = { 'User-Agent': 'FarmaERP/1.0', Accept: 'application/json' };

const text = (value: unknown): string | null => {
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  const clean = String(value).trim();
  return clean === '' ? null : clean;
};
const digits = (value: unknown): string | null => {
  const clean = text(value)?.replace(/\D/g, '') ?? '';
  return clean === '' ? null : clean;
};
const record = (value: unknown): Json =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Json) : {};

/** Não achou: os outros serviços não vão achar, mas uma falha de rede não prova nada. */
class NotFound extends Error {}

function fromBrasilApi(body: Json): CnpjData {
  const status = text(body.descricao_situacao_cadastral);
  const street = [text(body.descricao_tipo_de_logradouro), text(body.logradouro)].filter(Boolean).join(' ');
  return {
    source: 'brasilapi',
    legalName: text(body.razao_social),
    tradeName: text(body.nome_fantasia),
    active: status?.toUpperCase() === 'ATIVA',
    statusText: status,
    postalCode: digits(body.cep),
    street: street === '' ? null : street,
    streetNumber: text(body.numero),
    complement: text(body.complemento),
    district: text(body.bairro),
    city: text(body.municipio),
    cityCode: digits(body.codigo_municipio_ibge),
    state: text(body.uf),
    phone: digits(body.ddd_telefone_1),
    email: text(body.email)?.toLowerCase() ?? null,
  };
}

function fromReceitaWs(body: Json): CnpjData {
  if (body.status === 'ERROR') {
    throw new NotFound();
  }
  const status = text(body.situacao);
  return {
    source: 'receitaws',
    legalName: text(body.nome),
    tradeName: text(body.fantasia),
    active: status?.toUpperCase() === 'ATIVA',
    statusText: status,
    postalCode: digits(body.cep),
    street: text(body.logradouro),
    streetNumber: text(body.numero),
    complement: text(body.complemento),
    district: text(body.bairro),
    city: text(body.municipio),
    // Este serviço não traz o código IBGE.
    cityCode: null,
    state: text(body.uf),
    phone: digits(text(body.telefone)?.split('/')[0]),
    email: text(body.email)?.toLowerCase() ?? null,
  };
}

function fromCnpja(body: Json): CnpjData {
  const status = record(body.status);
  const address = record(body.address);
  const company = record(body.company);
  const phones = Array.isArray(body.phones) ? body.phones.map(record) : [];
  const emails = Array.isArray(body.emails) ? body.emails.map(record) : [];
  const statusText = text(status.text);
  return {
    source: 'cnpja',
    legalName: text(company.name),
    tradeName: text(body.alias),
    active: status.id === 2 || statusText?.toUpperCase() === 'ATIVA',
    statusText,
    postalCode: digits(address.zip),
    street: text(address.street),
    streetNumber: text(address.number),
    complement: text(address.details),
    district: text(address.district),
    city: text(address.city),
    cityCode: digits(address.municipality),
    state: text(address.state),
    phone: phones[0] ? digits(`${text(phones[0].area) ?? ''}${text(phones[0].number) ?? ''}`) : null,
    email: text(emails[0]?.address)?.toLowerCase() ?? null,
  };
}

const PROVIDERS: { url: (cnpj: string) => string; parse: (body: Json) => CnpjData }[] = [
  { url: (cnpj) => `https://brasilapi.com.br/api/cnpj/v1/${cnpj}`, parse: fromBrasilApi },
  { url: (cnpj) => `https://receitaws.com.br/v1/cnpj/${cnpj}`, parse: fromReceitaWs },
  { url: (cnpj) => `https://open.cnpja.com/office/${cnpj}`, parse: fromCnpja },
];

/**
 * Consulta em cascata: o primeiro que responder com a empresa vence. Se todos disserem que não
 * existe, é FA907; se algum falhou por rede ou limite, é FA906, porque a empresa pode existir.
 */
export async function lookupCnpj(cnpj: string, fetcher: Fetcher = fetch): Promise<CnpjData> {
  let unavailable = false;
  for (const provider of PROVIDERS) {
    try {
      const response = await fetcher(provider.url(cnpj), {
        headers: HEADERS,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (response.status === 404) {
        continue;
      }
      if (!response.ok) {
        unavailable = true;
        continue;
      }
      const data = provider.parse(record(await response.json()));
      if (!data.legalName) {
        unavailable = true;
        continue;
      }
      return data;
    } catch (error) {
      if (!(error instanceof NotFound)) {
        unavailable = true;
      }
    }
  }
  throw new AppError(unavailable ? 'FA906' : 'FA907');
}
