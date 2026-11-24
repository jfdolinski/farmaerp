import { Controller, Get, Inject, Param, UseGuards } from '@nestjs/common';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

/** Devolução no caixa: a venda pelo código do comprovante e o documento para a sangria. */
@Controller('terminals')
@UseGuards(TerminalGuard)
export class TerminalReturnsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('sales/:code')
  sale(@Param('code') code: string) {
    if (code.length > 30) throw new AppError('FA891');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_sale_for_return($1) AS result', [code]);
      return rows[0].result;
    });
  }

  @Get('returns/:code')
  document(@Param('code') code: string) {
    if (code.length > 30) throw new AppError('FA896');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_return($1) AS result', [code]);
      return rows[0].result;
    });
  }
}
