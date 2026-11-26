import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { v7 as uuidv7 } from 'uuid';
import { DatabaseService, DbClient } from '../database.service.js';
import { getError } from '@farmaerp/error-catalog';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { runWithContext } from '../observability/request-context.js';
import { brasiliaNow, pemFromPfx } from '../sefaz/dfe.js';
import {
  ACTIONS,
  authorizationEnvelope,
  cancellationEnvelope,
  nfceUrl,
  NfceService,
  parseAuthorization,
  parseEvent,
  parseStatus,
  parseVoiding,
  procFromStatus,
  statusEnvelope,
  voidingEnvelope,
} from '../sefaz/nfce-sefaz.js';
import { sefazEndpoints, sefazEnvironment } from '../sefaz/sefaz-config.js';
import { ClientCertificate, postSoap } from '../sefaz/soap.js';
import { open } from './secret-box.js';

/** O reenvio automático roda de hora em hora (o banco limita a 30 notas por grupo por rodada). */
const TICK_MS = 60 * 60 * 1000;

interface Sealed {
  company_id: string;
  encrypted_pfx: Buffer | null;
  encrypted_password: Buffer | null;
  state: string | null;
}

export interface DocumentContext extends Sealed {
  id: string;
  branch_id: string;
  sale_id: string;
  status: string;
  access_key: string;
  environment: number;
  protocol: string | null;
  xml: string;
  authorized_at: Date | null;
  cnpj: string;
}

/** Resultado para o banco (app.fiscal_resend_result) e para a tela. */
export type ResendOutcome =
  | { kind: 'authorized'; protocol: string; authorized_at: string; xml: string; status_code: string; reason: string }
  | { kind: 'rejected'; status_code: string; reason: string }
  | { kind: 'unavailable'; reason: string }
  | { kind: 'canceled'; reason: string; protocol: string | null; xml: string | null };

const codeOf = (error: unknown) => (error instanceof AppError ? error.code : 'FA944');

/** Falhas que não se resolvem sozinhas (certificado, UF, ambiente): aviso, fora do lote. */
const BLOCKING = new Set(['FA943', 'FA753', 'FA754']);
export function failureResult(error: unknown): { kind: 'blocked' | 'unavailable'; reason: string } {
  const code = codeOf(error);
  if (!BLOCKING.has(code)) return { kind: 'unavailable', reason: `Falha ${code}.` };
  return { kind: 'blocked', reason: `${getError(code).message} (${code})` };
}

/**
 * NFC-e na Sefaz da UF pela central: consulta, reenvio (automático e pelo botão), cancelamento e
 * inutilização. O certificado da filial só é aberto na memória, para a chamada.
 */
@Injectable()
export class NfceActionsService implements OnApplicationBootstrap, OnModuleDestroy {
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  onApplicationBootstrap(): void {
    if (process.env.FISCAL_WORKER === 'off') return;
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private certificate(row: Sealed): ClientCertificate {
    if (!row.encrypted_pfx || !row.encrypted_password) throw new AppError('FA943');
    const context = `certificate:${row.company_id}`;
    return { pfx: open(row.encrypted_pfx, context), passphrase: open(row.encrypted_password, context).toString('utf8') };
  }

  /** A central só fala com o ambiente da Sefaz que é o dela (a homologação nunca chama a produção). */
  private url(state: string | null, environment: number, service: NfceService): string {
    if (environment !== sefazEnvironment()) throw new AppError('FA753', { cause: new Error('ambiente da nota diferente do da central') });
    const url = state ? nfceUrl(state, environment as 1 | 2, service) : null;
    if (!url) throw new AppError('FA754', { cause: new Error(`UF ${state ?? '?'} sem serviço da NFC-e`) });
    return url;
  }

  private call(context: Sealed & { environment: number }, service: NfceService, envelope: string, certificate: ClientCertificate) {
    return postSoap(this.url(context.state, context.environment, service), ACTIONS[service], envelope, certificate, sefazEndpoints().ca);
  }

  /**
   * Consulta e, se a nota não está na Sefaz, envia. Duplicidade na resposta: consulta de novo.
   * Falha de rede vira "sem Sefaz" (tenta depois).
   */
  async settle(context: DocumentContext): Promise<ResendOutcome> {
    const certificate = this.certificate(context);
    try {
      const status = parseStatus(await this.call(context, 'status', statusEnvelope(context.access_key, context.environment as 1 | 2), certificate));
      if (status.kind === 'authorized') {
        return { kind: 'authorized', protocol: status.protocol, authorized_at: status.authorizedAt, xml: procFromStatus(context.xml, status.protNFe), status_code: status.status, reason: status.reason };
      }
      if (status.kind === 'canceled') return { kind: 'canceled', reason: status.reason, protocol: status.protocol, xml: status.cancelEvent };
      if (status.kind === 'unavailable') return { kind: 'unavailable', reason: `${status.status} ${status.reason}` };
      if (status.kind === 'other') return { kind: 'rejected', status_code: status.status, reason: status.reason };
      const batch = String(Date.now()).slice(-15).padStart(15, '0');
      const sent = parseAuthorization(await this.call(context, 'authorization', authorizationEnvelope(context.xml, batch), certificate), context.xml);
      if (sent.kind === 'authorized') {
        return { kind: 'authorized', protocol: sent.protocol, authorized_at: sent.authorizedAt, xml: sent.procXml, status_code: sent.status, reason: sent.reason };
      }
      if (sent.kind === 'duplicate') {
        const again = parseStatus(await this.call(context, 'status', statusEnvelope(context.access_key, context.environment as 1 | 2), certificate));
        if (again.kind === 'authorized') {
          return { kind: 'authorized', protocol: again.protocol, authorized_at: again.authorizedAt, xml: procFromStatus(context.xml, again.protNFe), status_code: again.status, reason: again.reason };
        }
        return { kind: 'unavailable', reason: `${sent.status} ${sent.reason}` };
      }
      if (sent.kind === 'unavailable') return { kind: 'unavailable', reason: `${sent.status} ${sent.reason}` };
      return { kind: 'rejected', status_code: sent.status, reason: sent.reason };
    } catch (error) {
      if (codeOf(error) === 'FA944') return { kind: 'unavailable', reason: 'Sem resposta da Sefaz.' };
      throw error;
    }
  }

  /** Grava o resultado. Nota que a Sefaz já mostra cancelada: só pela tela (precisa de quem cancelou). */
  private async record(client: DbClient, id: string, outcome: ResendOutcome): Promise<void> {
    const result = outcome.kind === 'canceled'
      ? { kind: 'unavailable', reason: 'A Sefaz mostra a nota cancelada: consulte pela tela de notas fiscais.' }
      : outcome;
    await client.query('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [id, JSON.stringify(result)]);
  }

  /** Rodada do reenvio automático: lote de até 30 notas por grupo. Nunca lança. */
  async tick(): Promise<number> {
    if (this.running) return 0;
    this.running = true;
    let done = 0;
    try {
      await runWithContext({ traceId: uuidv7() }, async () => {
        const ids = await this.database.withContext(
          async (client) => (await client.query<{ id: string }>('SELECT * FROM app.claim_fiscal_resend(30) AS id')).rows.map((row) => row.id),
          { worker: 'fiscal' },
        );
        for (const id of ids) {
          try {
            const context = await this.database.withContext(
              async (client) => (await client.query<DocumentContext>("SELECT * FROM app.fiscal_action_context($1, 'resend')", [id])).rows[0],
              { worker: 'fiscal' },
            );
            const outcome = await this.settle(context);
            await this.database.withContext((client) => this.record(client, id, outcome), { worker: 'fiscal' });
            done += 1;
          } catch (error) {
            // Falha que não se resolve sozinha vira aviso e sai do lote; o resto tenta na próxima hora.
            this.logger.pino.warn({ context: 'NfceActionsService', documentId: id, code: codeOf(error), err: error }, 'reenvio da NFC-e não concluído');
            await this.database
              .withContext((client) => client.query('SELECT app.fiscal_resend_result_checked($1, $2::jsonb)', [id, JSON.stringify(failureResult(error))]), { worker: 'fiscal' })
              .catch(() => undefined);
          }
        }
        if (ids.length > 0) this.logger.pino.info({ context: 'NfceActionsService', claimed: ids.length, done }, 'reenvio das NFC-e paradas');
      });
    } catch (error) {
      this.logger.pino.error({ context: 'NfceActionsService', err: error }, 'falha na rodada do reenvio das NFC-e');
    } finally {
      this.running = false;
    }
    return done;
  }

  /** Consulta (botão): grava o que a Sefaz disser; cancelada fora daqui é registrada como cancelada. */
  async consult(id: string): Promise<{ status: string }> {
    const context = await this.database.withContext(
      async (client) => (await client.query<DocumentContext>("SELECT * FROM app.fiscal_action_context($1, 'consult')", [id])).rows[0],
    );
    const certificate = this.certificate(context);
    const status = parseStatus(await this.call(context, 'status', statusEnvelope(context.access_key, context.environment as 1 | 2), certificate));
    return this.database.withContext(async (client) => {
      if (status.kind === 'authorized') {
        await client.query('SELECT app.fiscal_consult_result($1, $2::jsonb)', [id, JSON.stringify({
          kind: 'authorized', protocol: status.protocol, authorized_at: status.authorizedAt, xml: procFromStatus(context.xml, status.protNFe),
          status_code: status.status, reason: status.reason,
        })]);
        return { status: 'authorized' };
      }
      if (status.kind === 'canceled' && status.cancelEvent && status.cancelProtocol) {
        await client.query('SELECT app.fiscal_consult_canceled($1, $2::jsonb)', [id, JSON.stringify({
          reason: 'Cancelamento registrado na Sefaz (consulta pela chave).', protocol: status.cancelProtocol, status_code: status.status,
          xml: status.cancelEvent, registered_at: status.cancelRegisteredAt ?? new Date().toISOString(),
        })]);
        return { status: 'canceled' };
      }
      return { status: status.kind === 'not_found' ? 'not_found' : context.status };
    });
  }

  /** Reenvio pelo botão (também a nota recusada antes). */
  async resend(id: string): Promise<{ status: string }> {
    const context = await this.database.withContext(
      async (client) => (await client.query<DocumentContext>("SELECT * FROM app.fiscal_action_context($1, 'resend')", [id])).rows[0],
    );
    const outcome = await this.settle(context);
    await this.database.withContext((client) => this.record(client, id, outcome));
    return { status: outcome.kind };
  }

  /** Cancela na Sefaz e, registrado, desfaz a venda. */
  async cancel(id: string, reason: string): Promise<Record<string, unknown>> {
    const context = await this.database.withContext(
      async (client) => (await client.query<DocumentContext>("SELECT * FROM app.fiscal_action_context($1, 'cancel')", [id])).rows[0],
    );
    const result = await this.sendCancel(context, reason);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ r: Record<string, unknown> }>('SELECT app.fiscal_cancel_register($1, $2::jsonb) AS r', [id, JSON.stringify({
        reason, protocol: result.protocol, status_code: result.status, xml: result.xml, registered_at: result.registeredAt,
      })]);
      return { ...rows[0].r, sefaz: result.sefaz };
    });
  }

  /**
   * Cancelamento pedido pelo caixa (supervisor conferido no caixa pelo PIN e aqui pela permissão).
   * Nota já cancelada (o caixa não viu a resposta e pediu de novo) responde que já está feito.
   */
  async cancelForTerminal(id: string, supervisorId: string, reason: string): Promise<Record<string, unknown>> {
    const context = await this.database.withContext(
      async (client) => (await client.query<DocumentContext>('SELECT * FROM app.terminal_cancel_context($1, $2)', [id, supervisorId])).rows[0],
    );
    if (context.status === 'canceled') return { already: true };
    const result = await this.sendCancel(context, reason);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ r: Record<string, unknown> }>('SELECT app.terminal_cancel_register($1, $2, $3::jsonb) AS r', [id, supervisorId, JSON.stringify({
        reason, protocol: result.protocol, status_code: result.status, xml: result.xml, registered_at: result.registeredAt,
      })]);
      return { ...rows[0].r, sefaz: result.sefaz };
    });
  }

  /**
   * Envia o evento de cancelamento. 573 (um pedido anterior já tinha chegado, por exemplo quando a
   * resposta não voltou a tempo) consulta a chave e usa o evento que a Sefaz guardou, com o protocolo
   * do cancelamento.
   */
  private async sendCancel(context: DocumentContext, reason: string): Promise<{ protocol: string; status: string; xml: string; registeredAt: string; sefaz: string }> {
    const certificate = this.certificate(context);
    const { envelope, event } = cancellationEnvelope({
      environment: context.environment as 1 | 2, uf: context.state ?? '', cnpj: context.cnpj, accessKey: context.access_key,
      protocol: context.protocol ?? '', reason, at: brasiliaNow(),
    }, pemFromPfx(certificate.pfx, certificate.passphrase));
    const result = parseEvent(await this.call(context, 'event', envelope, certificate), event);
    if (result.kind === 'unavailable') throw new AppError('FA944', { cause: new Error(`${result.status} ${result.reason}`) });
    if (result.kind === 'refused') {
      throw new AppError('FA754', { cause: new Error(`${result.status} ${result.reason}`), detail: `Sefaz ${result.status}: ${result.reason}`.slice(0, 300) });
    }
    if (result.kind === 'registered') {
      return {
        protocol: result.protocol, status: result.status, xml: result.procXml,
        registeredAt: result.registeredAt || new Date().toISOString(), sefaz: `${result.status} ${result.reason}`,
      };
    }
    const status = parseStatus(await this.call(context, 'status', statusEnvelope(context.access_key, context.environment as 1 | 2), certificate));
    if (status.kind === 'canceled' && status.cancelEvent && status.cancelProtocol) {
      return {
        protocol: status.cancelProtocol, status: status.status, xml: status.cancelEvent,
        registeredAt: status.cancelRegisteredAt ?? new Date().toISOString(), sefaz: `${result.status} ${result.reason}`,
      };
    }
    if (status.kind === 'unavailable') throw new AppError('FA944', { cause: new Error(`${status.status} ${status.reason}`) });
    throw new AppError('FA754', {
      cause: new Error(`${result.status} ${result.reason}; consulta ${status.status} ${status.reason}`),
      detail: `Sefaz ${result.status}: ${result.reason}`.slice(0, 300),
    });
  }

  /** Inutiliza a faixa na Sefaz e registra. */
  async void(branchId: string, series: number, first: number, last: number, reason: string): Promise<{ id: string; protocol: string }> {
    const context = await this.database.withContext(
      async (client) => (await client.query<Sealed & { environment: number; cnpj: string }>(
        'SELECT * FROM app.fiscal_void_context($1, $2, $3, $4)', [branchId, series, first, last],
      )).rows[0],
    );
    const certificate = this.certificate(context);
    const year = brasiliaNow().slice(2, 4);
    const { envelope, message } = voidingEnvelope({
      environment: context.environment as 1 | 2, uf: context.state ?? '', cnpj: context.cnpj, year, series, first, last, reason,
    }, pemFromPfx(certificate.pfx, certificate.passphrase));
    const result = parseVoiding(await this.call(context, 'voiding', envelope, certificate), message);
    if (result.kind === 'unavailable') throw new AppError('FA944', { cause: new Error(`${result.status} ${result.reason}`) });
    if (result.kind === 'refused') {
      throw new AppError('FA754', { cause: new Error(`${result.status} ${result.reason}`), detail: `Sefaz ${result.status}: ${result.reason}`.slice(0, 300) });
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.fiscal_void_register($1, $2, $3, $4, $5, $6::jsonb) AS id', [
        branchId, series, first, last, reason,
        JSON.stringify({ protocol: result.protocol, xml: result.procXml, voided_at: result.voidedAt || new Date().toISOString(), environment: context.environment }),
      ]);
      return { id: rows[0].id, protocol: result.protocol };
    });
  }
}
