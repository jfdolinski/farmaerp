import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const STATUSES = new Set(['open', 'converted', 'replaced', 'expired', 'cancelled', 'all']);

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Orçamentos feitos nos PDVs e os parâmetros de venda da filial. Quem vê e quem muda é decidido no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class QuotesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('quotes')
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('status') status = 'all',
  ) {
    if (!STATUSES.has(status)) throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to), status === 'all' ? null : status];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_quotes($1, $2, $3, $4)', params)).rows,
    );
  }

  @Get('quotes/:id')
  detail(@Param('id') id: string) {
    const quoteId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ detail: unknown }>('SELECT app.quote_detail($1) AS detail', [quoteId]);
      if (rows[0].detail === null) throw new AppError('FA006');
      return rows[0].detail;
    });
  }

  /** Validade do orçamento em dias (0: até o fim do dia) e se o vendedor digita o PIN. */
  @Post('branches/:id/sale-settings')
  @HttpCode(200)
  async settings(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const body = asBody(rawBody);
    const days = body.quoteValidityDays;
    const pin = body.sellerPinRequired;
    if (typeof days !== 'number' || !Number.isInteger(days) || typeof pin !== 'boolean') throw new AppError('FA884');
    await this.database.withContext((client) =>
      client.query('SELECT app.set_branch_sale_settings($1, $2, $3)', [branchId, days, pin]),
    );
    return { status: 'ok' };
  }
}
