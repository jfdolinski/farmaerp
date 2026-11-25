import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const DESTINATIONS = new Set(['credit', 'agreement', 'cash', 'store_credit', 'all']);

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Devoluções feitas nos caixas e o prazo de devolução da filial. Quem vê e quem muda é decidido no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class ReturnsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('returns')
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('destination') destination = 'all',
  ) {
    if (!DESTINATIONS.has(destination)) throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to), destination === 'all' ? null : destination];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_returns($1, $2, $3, $4)', params)).rows,
    );
  }

  @Get('returns/:id')
  detail(@Param('id') id: string) {
    const returnId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ detail: unknown }>('SELECT app.return_detail($1) AS detail', [returnId]);
      if (rows[0].detail === null) throw new AppError('FA006');
      return rows[0].detail;
    });
  }

  @Post('branches/:id/return-days')
  @HttpCode(200)
  async returnDays(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const days = asBody(rawBody).days;
    if (typeof days !== 'number' || !Number.isInteger(days)) throw new AppError('FA899');
    await this.database.withContext((client) => client.query('SELECT app.set_branch_return_days($1, $2)', [branchId, days]));
    return { status: 'ok' };
  }
}
