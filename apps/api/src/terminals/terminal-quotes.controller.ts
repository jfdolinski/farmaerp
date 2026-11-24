import { Controller, Get, Inject, Param, UseGuards } from '@nestjs/common';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

/** Orçamentos da loja para o caixa: a lista dos pendentes e a busca pela plaquinha ou pelo cupom. */
@Controller('terminals/quotes')
@UseGuards(TerminalGuard)
export class TerminalQuotesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  open() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_open_quotes() AS result');
      return rows[0].result;
    });
  }

  /** Plaquinha (até 4 números) ou código do cupom (O1-000123). */
  @Get(':key')
  find(@Param('key') key: string) {
    if (typeof key !== 'string' || key.length > 30) throw new AppError('FA885');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_quote($1) AS result', [key]);
      return rows[0].result;
    });
  }
}
