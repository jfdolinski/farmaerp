import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Query, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { DfeService } from './dfe.service.js';

/** Download automático das notas: situação por filial, liga e desliga, e ciência da operação. */
@Controller('admin')
@UseGuards(SessionGuard)
export class DfeController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(DfeService) private readonly dfe: DfeService,
  ) {}

  @Get('dfe/status')
  status() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.dfe_sync_status()')).rows);
  }

  @Post('branches/:id/dfe')
  @HttpCode(200)
  async setEnabled(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const { enabled } = asBody(rawBody);
    if (typeof enabled !== 'boolean') throw new AppError('FA005');
    await this.database.withContext((client) => client.query('SELECT app.set_dfe_sync($1, $2)', [branchId, enabled]));
    return { status: 'ok' };
  }

  @Get('purchase-summaries')
  summaries(@Query('branch') branch?: string) {
    const branchId = branch ? requireUuid(branch) : null;
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_purchase_summaries($1)', [branchId])).rows,
    );
  }

  /** Manifestação oficial à Sefaz em nome da empresa: só por pedido na tela, uma nota por vez. */
  @Post('purchase-summaries/:id/awareness')
  @HttpCode(200)
  @Throttle({ default: { limit: 60, ttl: 60_000 } })
  awareness(@Param('id') id: string) {
    return this.dfe.giveAwareness(requireUuid(id));
  }
}
