import { Controller, Get, Inject, Query, UseGuards } from '@nestjs/common';
import { requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { SessionGuard } from './session.guard.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Entradas, falhas, bloqueios e liberações feitos nos PDVs. Quem vê é decidido no banco. */
@Controller('admin/pdv-auth-events')
@UseGuards(SessionGuard)
export class PdvAuthEventsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('alerts') alerts?: string,
  ) {
    if (alerts !== undefined && alerts !== '' && alerts !== '1' && alerts !== '0') throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to), alerts === '1'];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_pdv_auth_events($1, $2, $3, $4)', params)).rows,
    );
  }
}
