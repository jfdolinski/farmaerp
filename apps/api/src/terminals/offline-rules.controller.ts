import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

/** Minutos: inteiro, ou vazio quando o terminal volta ao tempo da filial. */
function minutes(rawBody: unknown, allowEmpty: boolean): number | null {
  const value = asBody(rawBody).minutes;
  if ((value === null || value === undefined || value === '') && allowEmpty) return null;
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new AppError('FA976');
  return value;
}

/** Tempo sem internet para a venda sem estoque, por filial e por terminal. */
@Controller('admin')
@UseGuards(SessionGuard)
export class OfflineRulesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Post('branches/:id/offline-minutes')
  @HttpCode(200)
  async branch(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const value = minutes(rawBody, false);
    await this.database.withContext((client) => client.query('SELECT app.set_branch_offline_minutes($1, $2)', [branchId, value]));
    return { status: 'ok' };
  }

  @Post('terminals/:id/offline-minutes')
  @HttpCode(200)
  async terminal(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const terminalId = requireUuid(id);
    const value = minutes(rawBody, true);
    await this.database.withContext((client) => client.query('SELECT app.set_terminal_offline_minutes($1, $2)', [terminalId, value]));
    return { status: 'ok' };
  }
}

/** Estoque das outras filiais, para o PDV consultar com internet. */
@Controller('terminals/stock')
@UseGuards(TerminalGuard)
export class TerminalStockController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get(':productId')
  network(@Param('productId') productId: string) {
    const id = requireUuid(productId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_network_stock($1) AS result', [id]);
      return rows[0].result;
    });
  }
}
