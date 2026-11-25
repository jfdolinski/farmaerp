import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, Body, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

function optionalNumber(body: Body, field: string, integer: boolean): number | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 10_000 || (integer && !Number.isInteger(value))) {
    throw new AppError('FA005');
  }
  return value;
}

/** Cashback na retaguarda: extrato do cliente e parâmetros da rede. Permissões no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class CashbackController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get('customers/:id/cashback')
  statement(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) =>
      (await client.query<{ result: unknown }>('SELECT app.cashback_statement($1) AS result', [customerId])).rows[0].result,
    );
  }

  @Get('cashback-policy')
  policy() {
    return this.database.withContext(async (client) =>
      (await client.query<{ result: unknown }>('SELECT app.get_cashback_policy() AS result')).rows[0].result,
    );
  }

  @Post('cashback-policy')
  @HttpCode(200)
  async setPolicy(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const data = {
      waiting_days: optionalNumber(body, 'waitingDays', true),
      validity_days: optionalNumber(body, 'validityDays', true),
      max_use_percent: optionalNumber(body, 'maxUsePercent', false),
    };
    await this.database.withContext((client) => client.query('SELECT app.set_cashback_policy($1::jsonb)', [JSON.stringify(data)]));
    return { status: 'ok' };
  }
}
