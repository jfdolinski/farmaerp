import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, UseGuards } from '@nestjs/common';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

function money(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0 || value > 9_999_999 || Number(value.toFixed(2)) !== value) {
    throw new AppError('FA005');
  }
  return value;
}

/**
 * Cashback no caixa, só com internet: saldo, reserva do uso (a venda confirma) e liberação quando
 * a venda não acontece. Consentimento, saldo e máximo de uso são conferidos no banco.
 */
@Controller('terminals/cashback')
@UseGuards(TerminalGuard)
export class TerminalCashbackController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get(':customerId')
  balance(@Param('customerId') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) =>
      (await client.query<{ result: unknown }>('SELECT app.pdv_cashback($1) AS result', [customerId])).rows[0].result,
    );
  }

  @Post('reserve')
  @HttpCode(200)
  reserve(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const customerId = requireUuid(body.customerId);
    const amount = money(body.amount);
    const saleTotal = money(body.saleTotal);
    return this.database.withContext(async (client) =>
      (await client.query<{ result: unknown }>('SELECT app.pdv_cashback_reserve($1, $2, $3) AS result', [customerId, amount, saleTotal]))
        .rows[0].result,
    );
  }

  @Post('release')
  @HttpCode(200)
  async release(@RequestBody() rawBody: unknown) {
    const reservationId = requireUuid(asBody(rawBody).reservationId);
    await this.database.withContext((client) => client.query('SELECT app.pdv_cashback_release($1)', [reservationId]));
    return { status: 'released' };
  }
}
