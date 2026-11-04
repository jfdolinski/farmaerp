import { Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import pg from 'pg';

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

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}
