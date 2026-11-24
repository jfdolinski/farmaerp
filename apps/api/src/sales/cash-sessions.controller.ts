import { Controller, Get, Inject, Param, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const STATUSES = new Set(['open', 'closed', 'all']);

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Turnos de caixa: sangrias, suprimentos e a conferência do fechamento. Quem vê é decidido no banco. */
@Controller('admin/cash-sessions')
@UseGuards(SessionGuard)
export class CashSessionsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('status') status = 'all',
  ) {
    if (!STATUSES.has(status)) throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to), status === 'all' ? null : status];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_cash_sessions($1, $2, $3, $4)', params)).rows,
    );
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    const sessionId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ detail: unknown }>('SELECT app.cash_session_detail($1) AS detail', [sessionId]);
      if (rows[0].detail === null) throw new AppError('FA006');
      return rows[0].detail;
    });
  }
}
