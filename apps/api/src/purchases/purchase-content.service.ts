import { codeFromDbError } from '@farmaerp/error-catalog';
import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { v7 as uuidv7 } from 'uuid';
import { DatabaseService } from '../database.service.js';
import { AppLogger } from '../observability/app-logger.js';
import { runWithContext } from '../observability/request-context.js';
import { InvalidNfeError, readAuthorizedNfe } from './nfe-xml.js';

const TICK_MS = 60_000;
const BATCH = 20;
const BUDGET_MS = 20_000;
const WORKER = 'purchase_content';
/** Falhas passageiras (conexão, fila, tempo): a nota fica para a próxima rodada. */
const TRANSIENT = new Set(['FA001', 'FA008']);

interface PendingNote {
  id: string;
  xml: string;
}

export interface ContentRound {
  read: number;
  failed: number;
}

/**
 * Lê as notas de compra guardadas que ainda não têm os dados completos do XML (as recebidas antes
 * desta versão e as baixadas da Sefaz) e grava o conteúdo e as duplicatas. A nota cujo XML não
 * se lê fica marcada e sai da fila. PURCHASE_CONTENT_WORKER=off desliga.
 */
@Injectable()
export class PurchaseContentService implements OnApplicationBootstrap, OnModuleDestroy {
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  onApplicationBootstrap(): void {
    if (process.env.PURCHASE_CONTENT_WORKER === 'off') return;
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Uma rodada, com tempo limitado. Nunca lança. */
  async tick(budgetMs = BUDGET_MS): Promise<ContentRound | null> {
    if (this.running) return null;
    this.running = true;
    const round: ContentRound = { read: 0, failed: 0 };
    try {
      return await runWithContext({ traceId: uuidv7() }, async () => {
        const deadline = Date.now() + budgetMs;
        for (;;) {
          const pending = await this.database.withContext(
            async (client) => (await client.query<{ q: PendingNote[] }>('SELECT app.purchase_content_pending($1) AS q', [BATCH])).rows[0].q,
            { worker: WORKER },
          );
          for (const note of pending) {
            if (await this.readNote(note)) round.read += 1;
            else round.failed += 1;
          }
          if (pending.length < BATCH || Date.now() >= deadline) break;
        }
        if (round.read + round.failed > 0) this.logger.pino.info({ context: 'PurchaseContent', ...round }, 'notas de compra lidas');
        return round;
      });
    } catch (error) {
      this.logger.pino.error({ context: 'PurchaseContent', err: error }, 'falha na leitura das notas de compra');
      return round.read + round.failed > 0 ? round : null;
    } finally {
      this.running = false;
    }
  }

  /**
   * Grava o conteúdo da nota; XML que não se lê ou conteúdo recusado pelo banco marca a falha (senão a
   * nota voltaria em toda rodada). Falha passageira ou sem código do catálogo interrompe a rodada.
   */
  private async readNote(note: PendingNote): Promise<boolean> {
    let reason: string;
    try {
      const { detail } = readAuthorizedNfe(note.xml);
      await this.database.withContext(
        (client) =>
          client.query('SELECT app.store_purchase_content($1, $2::jsonb, $3::jsonb)', [
            note.id, JSON.stringify(detail.content), JSON.stringify(detail.installments),
          ]),
        { worker: WORKER },
      );
      return true;
    } catch (error) {
      const code = error instanceof InvalidNfeError ? null : codeFromDbError(error);
      if (error instanceof InvalidNfeError) reason = `XML não lido: ${error.reason}`;
      else if (code && !TRANSIENT.has(code)) reason = `Conteúdo recusado pelo banco (${code}).`;
      else throw error;
      this.logger.pino.warn({ context: 'PurchaseContent', invoiceId: note.id, err: error }, 'nota de compra sem leitura');
    }
    await this.database.withContext((client) => client.query('SELECT app.purchase_content_failed($1, $2)', [note.id, reason]), {
      worker: WORKER,
    });
    return false;
  }
}
