import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { v7 as uuidv7 } from 'uuid';
import { DatabaseService } from '../database.service.js';
import { AppLogger } from '../observability/app-logger.js';
import { runWithContext } from '../observability/request-context.js';

const TICK_MS = 60 * 60_000;

/**
 * Curva ABC de clientes: de hora em hora roda as curvas que venceram em cada filial (cada curva tem o
 * seu intervalo). Na primeira rodada, a filial sem parâmetros calcula as três com os padrões.
 * ABC_WORKER=off desliga.
 */
@Injectable()
export class AbcService implements OnApplicationBootstrap, OnModuleDestroy {
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  onApplicationBootstrap(): void {
    if (process.env.ABC_WORKER === 'off') return;
    // Primeira rodada logo depois de subir; depois, de hora em hora.
    setTimeout(() => void this.tick(), 30_000).unref();
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Uma rodada. Nunca lança. */
  async tick(): Promise<{ runs: number; changed: number } | null> {
    if (this.running) return null;
    this.running = true;
    try {
      return await runWithContext({ traceId: uuidv7() }, async () => {
        const result = await this.database.withContext(
          async (client) => (await client.query<{ r: { runs: number; changed: number } }>('SELECT app.abc_run_due(now()) AS r')).rows[0].r,
          { worker: 'abc' },
        );
        if (result.runs > 0) this.logger.pino.info({ context: 'AbcService', ...result }, 'curva ABC recalculada');
        return result;
      });
    } catch (error) {
      this.logger.pino.error({ context: 'AbcService', err: error }, 'falha no recálculo da curva ABC');
      return null;
    } finally {
      this.running = false;
    }
  }
}
