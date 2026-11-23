import { Controller, Get, Inject, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const STATUSES = new Set(['complete', 'pending', 'all']);

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Vendas de controlados (e as pendentes de dados para o SNGPC). Quem vê é decidido no banco. */
@Controller('admin/controlled')
@UseGuards(SessionGuard)
export class ControlledController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list(@Query('status') status = 'all', @Query('from') from?: string, @Query('to') to?: string) {
    if (!STATUSES.has(status)) throw new AppError('FA005');
    const params = [status === 'all' ? null : status, optionalDay(from), optionalDay(to)];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_controlled_dispensings($1, $2, $3)', params)).rows,
    );
  }
}
