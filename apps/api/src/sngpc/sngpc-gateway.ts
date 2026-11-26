import { appEnvironment } from '../config/environment.js';
import { AppError } from '../observability/app-error.js';

// Conversa com o SNGPC.
// CONTRATO PROVISÓRIO: envio por POST {SNGPC_URL}/envios (usuário, senha, CNPJ e o arquivo em
// base64) devolvendo o protocolo, e consulta por GET {SNGPC_URL}/envios/{protocolo}. É o contrato da
// Anvisa falsa dos testes. Ajuste aqui quando houver a documentação oficial da API nova.

export interface SngpcCredential {
  username: string;
  password: string;
}

export type SngpcResult = { state: 'processing' } | { state: 'accepted' } | { state: 'rejected'; reason: string };

export interface SngpcGateway {
  send(credential: SngpcCredential, cnpj: string, xml: string, sha256: string): Promise<string>;
  status(credential: SngpcCredential, protocol: string): Promise<SngpcResult>;
}

/**
 * O envio real só liga com SNGPC_LIVE=true e SNGPC_URL. Fora do desenvolvimento, o endereço precisa
 * ser HTTPS. Desligado, a rotina monta as remessas e espera.
 */
export function sngpcEndpoint(env: NodeJS.ProcessEnv = process.env): string | null {
  if (env.SNGPC_LIVE !== 'true' || !env.SNGPC_URL) return null;
  const url = env.SNGPC_URL.replace(/\/$/, '');
  if (appEnvironment(env) !== 'development' && !url.startsWith('https://')) return null;
  return url;
}

function basic(credential: SngpcCredential): string {
  return `Basic ${Buffer.from(`${credential.username}:${credential.password}`, 'utf8').toString('base64')}`;
}

async function call(url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(30_000) });
  } catch (cause) {
    throw new AppError('FA721', { cause });
  }
}

export class HttpSngpcGateway implements SngpcGateway {
  constructor(private readonly baseUrl: string) {}

  async send(credential: SngpcCredential, cnpj: string, xml: string, sha256: string): Promise<string> {
    const response = await call(`${this.baseUrl}/envios`, {
      method: 'POST',
      headers: { Authorization: basic(credential), 'Content-Type': 'application/json' },
      body: JSON.stringify({ cnpj, arquivo: Buffer.from(xml, 'utf8').toString('base64'), hash: sha256 }),
    });
    if (response.status === 401 || response.status === 403) throw new AppError('FA722');
    const body = (await response.json().catch(() => ({}))) as { protocolo?: unknown };
    if (!response.ok || typeof body.protocolo !== 'string' || body.protocolo.length === 0 || body.protocolo.length > 100) {
      throw new AppError('FA721', { cause: new Error(`Envio respondeu ${response.status}.`) });
    }
    return body.protocolo;
  }

  async status(credential: SngpcCredential, protocol: string): Promise<SngpcResult> {
    const response = await call(`${this.baseUrl}/envios/${encodeURIComponent(protocol)}`, {
      method: 'GET',
      headers: { Authorization: basic(credential) },
    });
    if (response.status === 401 || response.status === 403) throw new AppError('FA722');
    const body = (await response.json().catch(() => ({}))) as { situacao?: unknown; motivo?: unknown };
    if (!response.ok) throw new AppError('FA721', { cause: new Error(`Consulta respondeu ${response.status}.`) });
    if (body.situacao === 'aceito') return { state: 'accepted' };
    if (body.situacao === 'recusado') {
      return { state: 'rejected', reason: typeof body.motivo === 'string' && body.motivo.trim() ? body.motivo.trim() : 'Recusada sem motivo informado.' };
    }
    return { state: 'processing' };
  }
}
