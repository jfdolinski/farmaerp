import { createHash } from 'node:crypto';

/**
 * Ligação com o Catálogo externo (catalogo-produtos). O endereço vem do ambiente (CATALOG_URL); a
 * chave é a de cada filial (cadastrada em Fiscal, cifrada no banco). Sem o endereço, a ligação fica
 * desligada. A chave nunca vai para o log nem para a URL.
 */
export interface CatalogConfig {
  url: string;
  key: string;
}

export function catalogUrl(env: NodeJS.ProcessEnv = process.env): string | null {
  const url = env.CATALOG_URL?.trim().replace(/\/+$/, '');
  return url && /^https?:\/\/[^\s/]+$/.test(url) ? url : null;
}

/** Formato da chave da empresa no Catálogo. */
export const CATALOG_KEY = /^cat_[A-Za-z0-9_-]{8,200}$/;

/** Item como sai do Catálogo (só os campos usados aqui). */
export interface ExternalItem {
  id?: unknown;
  name?: unknown;
  brand?: unknown;
  manufacturer?: unknown;
  anvisa_registry?: unknown;
  med_controlled?: unknown;
  ncm?: unknown;
  cest?: unknown;
  actives?: unknown;
  barcodes?: unknown;
  images?: unknown;
  pending?: unknown;
  active?: unknown;
  tax_origin?: unknown;
  category?: unknown;
}

/** Item no formato que o banco grava (app.catalog_sync_apply). */
export interface MappedItem {
  sourceKey: string;
  name: string;
  manufacturer: string | null;
  /** Marca do produto (o Catálogo guarda à parte do fabricante). */
  brand: string | null;
  /** Departamento: o Catálogo manda como "category". */
  department: string | null;
  activeIngredient: string | null;
  msRegistration: string | null;
  controlledClass: string | null;
  ncm: string | null;
  cest: string | null;
  barcodes: string[];
  pending: boolean;
  images: string[];
  /** Origem do produto para a tributação (0 a 8), como o Catálogo guarda. */
  origin: string | null;
  hash: string;
}

const MAX_IMAGES = 5;
const text = (value: unknown): string | null => {
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  const clean = String(value).trim();
  return clean === '' ? null : clean;
};
const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);
const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : {};

/**
 * Converte o item do Catálogo. Fica de fora a imagem padrão (o FarmaERP mostra a dele) e o que não é
 * endereço do próprio Catálogo. Sem id ou sem nome, o item é ignorado (null).
 */
export function mapItem(item: ExternalItem, baseUrl: string): MappedItem | null {
  const id = typeof item.id === 'number' || (typeof item.id === 'string' && /^\d+$/.test(item.id)) ? String(item.id) : null;
  const name = text(item.name);
  if (!id || !name) return null;
  const actives = list(item.actives)
    .map((active) => {
      if (typeof active === 'string') return text(active);
      const entry = record(active);
      return [text(entry.name), text(entry.concentration)].filter(Boolean).join(' ') || null;
    })
    .filter((value): value is string => value !== null);
  const barcodes = list(item.barcodes)
    .map((code) => text(typeof code === 'string' ? code : record(code).code))
    .filter((code): code is string => code !== null);
  const images = list(item.images)
    .map((image) => (typeof image === 'string' ? { url: image, placeholder: false } : record(image)))
    .filter((image) => image.placeholder !== true)
    .map((image) => text(image.url))
    .filter((url): url is string => url !== null && url.startsWith(`${baseUrl}/files/`))
    .slice(0, MAX_IMAGES);
  const mapped = {
    sourceKey: `catalogo:${id}`,
    name,
    manufacturer: text(item.manufacturer),
    brand: text(item.brand),
    department: text(item.category),
    activeIngredient: actives.length ? actives.join(' + ') : null,
    msRegistration: text(item.anvisa_registry),
    controlledClass: text(item.med_controlled),
    ncm: text(item.ncm),
    cest: text(item.cest),
    barcodes: [...new Set(barcodes)],
    pending: item.pending === true,
    images,
    origin: text(item.tax_origin),
  };
  return { ...mapped, hash: createHash('sha256').update(JSON.stringify(mapped)).digest('hex') };
}

export type Fetcher = (url: string, init: RequestInit) => Promise<Response>;

const ORIGIN = 'FarmaERP';
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

/**
 * Falha ao falar com o Catálogo. A mensagem é a que aparece na Plataforma (clara, sem a chave); o
 * detalhe técnico vai só para o log, na causa.
 */
export class CatalogUnavailable extends Error {}

function refused(status: number): CatalogUnavailable {
  if (status === 401) return new CatalogUnavailable('O Catálogo recusou a chave de acesso. Confira a CATALOG_API_KEY da API.');
  if (status === 403) return new CatalogUnavailable('A empresa do FarmaERP está suspensa ou cancelada no Catálogo.');
  return new CatalogUnavailable(`O Catálogo respondeu com erro (${status}).`);
}
const offFormat = () => new CatalogUnavailable('O Catálogo respondeu fora do formato esperado.');

export class CatalogClient {
  constructor(
    private readonly config: CatalogConfig,
    private readonly fetcher: Fetcher = fetch,
  ) {}

  get baseUrl(): string {
    return this.config.url;
  }

  private headers(extra: Record<string, string> = {}): Record<string, string> {
    return { 'X-Api-Key': this.config.key, 'X-Origem': ORIGIN, Accept: 'application/json', ...extra };
  }

  private async call(path: string, init: RequestInit, timeoutMs: number): Promise<Response> {
    try {
      return await this.fetcher(`${this.config.url}${path}`, { ...init, signal: AbortSignal.timeout(timeoutMs) });
    } catch (error) {
      throw new CatalogUnavailable('O Catálogo não respondeu.', { cause: error });
    }
  }

  /** Catálogo completo. Com a ETag da última cópia, o Catálogo responde 304 quando nada mudou. */
  async catalog(etag: string | null): Promise<{ unchanged: true } | { unchanged: false; etag: string | null; items: ExternalItem[] }> {
    const response = await this.call('/api/v1/catalog.json', { headers: this.headers(etag ? { 'If-None-Match': etag } : {}) }, 180_000);
    if (response.status === 304) return { unchanged: true };
    if (!response.ok) throw refused(response.status);
    const body = record(await response.json().catch(() => null));
    if (!Array.isArray(body.items)) throw offFormat();
    return { unchanged: false, etag: response.headers.get('etag'), items: body.items as ExternalItem[] };
  }

  /**
   * Confere a chave numa rota leve do Catálogo (conta uma consulta). Chave recusada: 'refused';
   * empresa suspensa: 'suspended'; sem resposta: lança CatalogUnavailable.
   */
  async verify(): Promise<'ok' | 'refused' | 'suspended'> {
    const response = await this.call('/api/v1/categories', { headers: this.headers() }, 10_000);
    if (response.status === 401) return 'refused';
    if (response.status === 403) return 'suspended';
    if (!response.ok) throw refused(response.status);
    return 'ok';
  }

  /**
   * Tributação do item num estado (rota que não cadastra código desconhecido). Item que não está
   * mais lá: null. Os valores vêm como o Catálogo guarda (cfop, cst_icms, icms_rate...).
   */
  async tax(externalId: string, uf: string): Promise<Record<string, unknown> | null> {
    const path = `/api/v1/products/${encodeURIComponent(externalId)}/tax?uf=${encodeURIComponent(uf)}`;
    const response = await this.call(path, { headers: this.headers() }, 15_000);
    if (response.status === 404) return null;
    if (!response.ok) throw refused(response.status);
    const body = record(await response.json().catch(() => null));
    const values = record(body.values);
    return values;
  }

  /** Um código de barras. Desconhecido lá vira cadastro pendente; código inválido ou inativo: null. */
  async barcode(code: string): Promise<ExternalItem | null> {
    const response = await this.call(`/api/v1/barcodes/${encodeURIComponent(code)}`, { headers: this.headers() }, 10_000);
    if (response.status === 404) return null;
    if (!response.ok) throw refused(response.status);
    const body = await response.json().catch(() => null);
    if (body === null || typeof body !== 'object') throw offFormat();
    return body as ExternalItem;
  }

  /** Arquivo de imagem, só do próprio Catálogo e de até 5 MB. */
  async image(url: string): Promise<Buffer> {
    if (!url.startsWith(`${this.config.url}/files/`)) throw new CatalogUnavailable('Imagem fora do endereço do Catálogo.');
    const response = await this.call(url.slice(this.config.url.length), { headers: { 'X-Origem': ORIGIN } }, 30_000);
    if (!response.ok) throw refused(response.status);
    const declared = Number(response.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > MAX_IMAGE_BYTES) throw new CatalogUnavailable('Imagem do Catálogo acima de 5 MB.');
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > MAX_IMAGE_BYTES) throw new CatalogUnavailable('Imagem do Catálogo acima de 5 MB.');
    return buffer;
  }
}
