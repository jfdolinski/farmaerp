import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Put, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { MAX_ROWS, parseCountCsv } from './stock-count-csv.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** Inventário de abertura da filial. As regras (corte, lote, o que zera) ficam no banco. */
@Controller('admin/stock-counts')
@UseGuards(SessionGuard)
export class StockCountsController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list(@Query('branch') branch?: string) {
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_stock_counts($1)', [branch ? requireUuid(branch) : null])).rows,
    );
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const branchId = requireUuid(body.branchId);
    const cutoffAt = requireText(body, 'cutoffAt', 40);
    if (Number.isNaN(Date.parse(cutoffAt))) throw new AppError('FA005');
    const note = optionalText(body, 'note', 200);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.create_stock_count($1, $2, $3) AS id', [branchId, cutoffAt, note]);
      return { id: rows[0].id };
    });
  }

  /** Cabeçalho, linhas contadas e a conferência (saldo no corte, contado e diferença). */
  @Get(':id')
  detail(@Param('id') id: string) {
    const countId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const header = (await client.query('SELECT * FROM app.list_stock_counts() WHERE id = $1', [countId])).rows[0];
      if (!header) throw new AppError('FA006');
      const items = (await client.query('SELECT * FROM app.stock_count_items($1)', [countId])).rows;
      const review = (await client.query('SELECT * FROM app.stock_count_review($1)', [countId])).rows;
      return { ...header, items, review };
    });
  }

  /** Planilha (CSV, texto): cada arquivo soma ao que já foi contado. */
  @Post(':id/file')
  @HttpCode(200)
  load(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const countId = requireUuid(id);
    if (typeof rawBody !== 'string' || rawBody.trim() === '') throw new AppError('FA005');
    const rows = parseCountCsv(rawBody);
    if (rows.length === 0 || rows.length > MAX_ROWS) throw new AppError('FA005');
    return this.database.withContext(async (client) => {
      const { rows: result } = await client.query<{ r: unknown }>('SELECT app.stock_count_load($1, $2::jsonb) AS r', [
        countId, JSON.stringify(rows),
      ]);
      return result[0].r;
    });
  }

  /** Digitação: define a quantidade do produto (e do lote, se ele exigir). */
  @Put(':id/items')
  async setItem(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const countId = requireUuid(id);
    const body = asBody(rawBody);
    const lookup = requireText(body, 'lookup', 60);
    const batch = optionalText(body, 'batch', 30);
    const expiresOn = optionalText(body, 'expiresOn', 10);
    if (expiresOn !== null && expiresOn !== '' && !DAY.test(expiresOn)) throw new AppError('FA005');
    const quantity = body.quantity;
    if (typeof quantity !== 'number' || !Number.isFinite(quantity)) throw new AppError('FA005');
    await this.database.withContext((client) =>
      client.query('SELECT app.stock_count_set_item($1, $2, $3, $4, $5)', [countId, lookup, batch, expiresOn || null, quantity]),
    );
    return { ok: true };
  }

  @Post(':id/items/:itemId/remove')
  @HttpCode(200)
  async removeItem(@Param('itemId') itemId: string) {
    const target = requireUuid(itemId);
    await this.database.withContext((client) => client.query('SELECT app.stock_count_remove_item($1)', [target]));
    return { ok: true };
  }

  @Post(':id/apply')
  @HttpCode(200)
  apply(@Param('id') id: string) {
    const countId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ t: unknown }>('SELECT app.apply_stock_count($1) AS t', [countId]);
      return rows[0].t;
    });
  }

  @Post(':id/cancel')
  @HttpCode(200)
  async cancel(@Param('id') id: string) {
    const countId = requireUuid(id);
    await this.database.withContext((client) => client.query('SELECT app.cancel_stock_count($1)', [countId]));
    return { ok: true };
  }
}
