import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Put, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const FIELDS = ['periodDays', 'aMinSales', 'bMinSales', 'aIntervalDays', 'bIntervalDays', 'cIntervalDays'] as const;

/** Curva ABC de clientes por filial. O banco confere quem vê e quem troca os parâmetros. */
@Controller('admin/abc')
@UseGuards(SessionGuard)
export class AbcController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  /** Parâmetros e contagem por curva das filiais que a pessoa vê. */
  @Get('settings')
  settings() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.abc_settings()')).rows);
  }

  @Put('settings/:branchId')
  @HttpCode(200)
  async save(@Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const branch = requireUuid(branchId);
    const body = asBody(rawBody);
    const data: Record<string, number> = {};
    for (const field of FIELDS) {
      const value = body[field];
      if (typeof value !== 'number' || !Number.isInteger(value)) throw new AppError('FA005');
      data[field] = value;
    }
    await this.database.withContext((client) => client.query('SELECT app.set_abc_settings($1, $2::jsonb)', [branch, JSON.stringify(data)]));
    return { ok: true };
  }

  @Post('recalculate/:branchId')
  @HttpCode(200)
  async recalculate(@Param('branchId') branchId: string) {
    const branch = requireUuid(branchId);
    return this.database.withContext(
      async (client) => (await client.query<{ r: unknown }>('SELECT app.abc_recalculate_now($1) AS r', [branch])).rows[0].r,
    );
  }

  /** Clientes da curva (A, B ou C; sem curva, todas) na filial, com busca por nome ou código. */
  @Get('customers')
  customers(@Query('branch') branch: string | undefined, @Query('curve') curve: string | undefined, @Query('q') search: string | undefined) {
    const branchId = requireUuid(branch);
    if (curve !== undefined && curve !== '' && !['A', 'B', 'C'].includes(curve)) throw new AppError('FA005');
    if (search !== undefined && search.length > 100) throw new AppError('FA005');
    return this.database.withContext(
      async (client) =>
        (await client.query('SELECT * FROM app.abc_customers($1, $2, $3)', [branchId, curve || null, search?.trim() || null])).rows,
    );
  }

  /** Curva do cliente em cada filial. */
  @Get('customers/:id')
  customer(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.customer_abc_curves($1)', [customerId])).rows,
    );
  }
}
