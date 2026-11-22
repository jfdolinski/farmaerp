import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import pg from 'pg';
import { currentContext } from './observability/request-context.js';

export type DbClient = Pick<pg.PoolClient, 'query'>;

@Injectable()
export class DatabaseService implements OnModuleDestroy {
  private readonly logger = new Logger(DatabaseService.name);

  // Sempre conecta como farmaerp_app, que está sujeito à Row Level Security.
  private readonly pool = new pg.Pool({
    host: process.env.DB_HOST ?? '127.0.0.1',
    port: Number(process.env.DB_PORT ?? 5432),
    database: process.env.DB_NAME ?? 'farmaerp',
    user: 'farmaerp_app',
    password: process.env.FARMAERP_APP_PASSWORD,
    connectionTimeoutMillis: 3000,
  });

  constructor() {
    // Sem este tratamento, a queda de uma conexão ociosa encerraria a API inteira.
    this.pool.on('error', (error) => {
      this.logger.error('Conexão ociosa com o banco foi perdida', error);
    });
  }

  async ping(): Promise<void> {
    await this.pool.query('SELECT 1');
  }

  /**
   * Executa uma transação com o usuário e o ID de rastreio da requisição.
   * O contexto usa set_config local, que termina com a transação: é seguro com pool.
   * Sem usuário autenticado, a RLS não libera nenhuma linha.
   */
  async withContext<T>(
    fn: (client: DbClient) => Promise<T>,
    options: { userId?: string; worker?: string } = {},
  ): Promise<T> {
    const context = currentContext();
    // A rotina de fundo roda sem usuário: o contexto dela libera só as funções feitas para ela.
    const userId = options.worker ? '' : (options.userId ?? context?.userId ?? '');
    const worker = options.worker ?? '';
    const terminalId = context?.terminalId ?? '';
    const traceId = context?.traceId ?? '';

    const client = await this.pool.connect();
    let releaseError: Error | undefined;
    try {
      await client.query('BEGIN');
      await client.query(
        `SELECT set_config('app.user_id', $1, true),
                set_config('app.trace_id', $2, true),
                set_config('app.terminal_id', $3, true),
                set_config('application_name', $4, true),
                set_config('app.worker', $5, true)`,
        [userId, traceId, terminalId, traceId ? `api:${traceId}` : 'api', worker],
      );
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      try {
        await client.query('ROLLBACK');
      } catch (rollbackError) {
        // Conexão quebrada não pode voltar para o pool.
        releaseError = rollbackError as Error;
      }
      throw error;
    } finally {
      client.release(releaseError);
    }
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}
