import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Patch,
  Post,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { resolveSupervisorRelease } from '../auth/supervisor-release.js';
import {
  asBody,
  Body,
  optionalText,
  requireText,
  requireUuid,
} from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const MAX_QUANTITY = 99_999_999;
const DAY = /^\d{4}-\d{2}-\d{2}$/;

// A validade é uma data: como texto, não muda de dia conforme o fuso do servidor.
const OVERVIEW_COLUMNS = `balance_id, branch_id, branch_name, product_id, product_code, product_name,
  batch_id, batch_number, expires_on::text AS expires_on, ms_registration, ms_original, base_ms,
  quantity, is_expired, days_to_expire, ms_diverges, needs_batch`;

/** Mais de três decimais seria arredondado em silêncio pelo banco, então é recusado aqui. */
function quantityOf(value: unknown): number {
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    Math.abs(value) > MAX_QUANTITY ||
    Number(value.toFixed(3)) !== value
  ) {
    throw new AppError('FA005');
  }
  return value;
}

function optionalDay(body: Body, field: string): string | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (
    typeof value !== 'string' ||
    !DAY.test(value) ||
    Number.isNaN(Date.parse(`${value}T00:00:00Z`)) ||
    new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) !== value
  ) {
    throw new AppError('FA005');
  }
  return value;
}

function searchText(value: unknown): string {
  if (value === undefined) {
    return '';
  }
  if (typeof value !== 'string' || value.length > 200) {
    throw new AppError('FA005');
  }
  return value;
}

const optionalBranch = (value: unknown): string | null =>
  value === undefined || value === '' ? null : requireUuid(value);

/** Estoque. As regras, os saldos e as permissões ficam no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class StockController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('stock')
  overview(
    @Query('q') query?: string,
    @Query('branch') branch?: string,
    @Query('zerados') includeZero?: string,
  ) {
    const text = searchText(query);
    const branchId = optionalBranch(branch);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT ${OVERVIEW_COLUMNS} FROM app.stock_overview($1, $2, NULL, $3)`,
        [text, branchId, includeZero === '1'],
      );
      return rows;
    });
  }

  @Get('stock/movements')
  movements(@Query('branch') branch?: string) {
    const branchId = optionalBranch(branch);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT * FROM app.list_stock_movements(NULL, $1)',
        [branchId],
      );
      // Saídas de transferência feitas aqui (não importadas): a NF-e de transferência sai delas.
      const transfers = await client.query<{ id: string; transfer_group: string; can_issue_nfe: boolean }>(
        `SELECT m.id, m.transfer_group, app.has_permission('fiscal.nfe_issue', m.branch_id) AS can_issue_nfe
           FROM v_stock_movement m
          WHERE m.id = ANY($1::uuid[]) AND m.movement_type = 'transfer' AND m.quantity < 0
            AND m.transfer_group IS NOT NULL AND m.imported_stock_item_id IS NULL AND m.reversal_of IS NULL`,
        [rows.map((row) => row.id)],
      );
      const groups = transfers.rows.map((row) => row.transfer_group);
      const nfes = groups.length
        ? (await client.query<{ x: Record<string, unknown> }>('SELECT app.transfer_nfes($1::uuid[]) AS x', [groups])).rows[0].x
        : {};
      const byMovement = new Map(transfers.rows.map((row) => [row.id, row]));
      return rows.map((row) => {
        const transfer = byMovement.get(row.id);
        return transfer
          ? { ...row, transfer: { id: transfer.transfer_group, can_issue_nfe: transfer.can_issue_nfe, nfe: nfes[transfer.transfer_group] ?? null } }
          : row;
      });
    });
  }

  /** Qualquer diferença entre o saldo e as movimentações é defeito, e a tela avisa. */
  @Get('stock/check')
  check() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ total: number }>(
        'SELECT count(*)::int AS total FROM app.stock_balance_divergences()',
      );
      return { divergences: rows[0].total };
    });
  }

  @Get('products/:id/stock')
  productStock(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const balances = await client.query(
        `SELECT ${OVERVIEW_COLUMNS} FROM app.stock_overview(NULL, NULL, $1)`,
        [productId],
      );
      const tracking = await client.query(
        'SELECT * FROM app.batch_tracking_grid($1)',
        [productId],
      );
      return { balances: balances.rows, tracking: tracking.rows };
    });
  }

  @Post('products/:id/batch-tracking')
  @HttpCode(200)
  async setTracking(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    if (typeof body.tracks !== 'boolean') {
      throw new AppError('FA005');
    }
    const productId = requireUuid(id);
    const branchId = requireUuid(body.branchId);
    const tracks = body.tracks;
    await this.database.withContext((client) =>
      client.query('SELECT app.set_batch_tracking($1, $2, $3)', [productId, branchId, tracks]),
    );
    return { status: 'ok' };
  }

  @Post('stock/adjustments')
  async adjust(@RequestBody() rawBody: unknown, @Req() request: Request) {
    const body = asBody(rawBody);
    const release = await resolveSupervisorRelease(this.database, body, request.ip ?? '');
    const data = {
      productLookup: requireText(body, 'productLookup', 30),
      branchId: requireUuid(body.branchId),
      direction: requireText(body, 'direction', 3),
      quantity: quantityOf(body.quantity),
      batchNumber: optionalText(body, 'batchNumber', 40),
      expiresOn: optionalDay(body, 'expiresOn'),
      msRegistration: optionalText(body, 'msRegistration', 13),
      reason: optionalText(body, 'reason', 500),
      release,
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.adjust_stock($1::jsonb) AS id',
        [JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Get('stock/destinations')
  destinations() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.transfer_destinations()');
      return rows;
    });
  }

  @Post('stock/transfers')
  transfer(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const data = {
      productLookup: requireText(body, 'productLookup', 30),
      fromBranchId: requireUuid(body.fromBranchId),
      toBranchId: requireUuid(body.toBranchId),
      quantity: quantityOf(body.quantity),
      batchNumber: optionalText(body, 'batchNumber', 40),
      reason: optionalText(body, 'reason', 500),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.transfer_stock($1::jsonb) AS id',
        [JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  /** Contagem igual ao saldo não gera movimentação, e a resposta diz isso. */
  @Post('stock/counts')
  async count(@RequestBody() rawBody: unknown, @Req() request: Request) {
    const body = asBody(rawBody);
    const counted = body.countedQuantity;
    if (typeof counted === 'number' && counted < 0) {
      throw new AppError('FA005');
    }
    const data = {
      productLookup: requireText(body, 'productLookup', 30),
      branchId: requireUuid(body.branchId),
      countedQuantity: counted === 0 ? 0 : quantityOf(counted),
      batchNumber: optionalText(body, 'batchNumber', 40),
      expiresOn: optionalDay(body, 'expiresOn'),
      msRegistration: optionalText(body, 'msRegistration', 13),
      reason: optionalText(body, 'reason', 500),
      release: await resolveSupervisorRelease(this.database, body, request.ip ?? ''),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string | null }>(
        'SELECT app.count_stock($1::jsonb) AS id',
        [JSON.stringify(data)],
      );
      return { id: rows[0].id, changed: rows[0].id !== null };
    });
  }

  @Post('stock/losses')
  async loss(@RequestBody() rawBody: unknown, @Req() request: Request) {
    const body = asBody(rawBody);
    const data = {
      productLookup: requireText(body, 'productLookup', 30),
      branchId: requireUuid(body.branchId),
      quantity: quantityOf(body.quantity),
      batchNumber: optionalText(body, 'batchNumber', 40),
      reason: optionalText(body, 'reason', 500),
      release: await resolveSupervisorRelease(this.database, body, request.ip ?? ''),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.register_stock_loss($1::jsonb) AS id',
        [JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Post('stock/movements/:id/reverse')
  reverse(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const movementId = requireUuid(id);
    const reason = optionalText(asBody(rawBody), 'reason', 500);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.reverse_stock_movement($1, $2) AS id',
        [movementId, reason],
      );
      return { id: rows[0].id };
    });
  }

  @Patch('stock/batches/:id')
  async updateBatch(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const batchId = requireUuid(id);
    const body = asBody(rawBody);
    const data = {
      batchNumber: requireText(body, 'batchNumber', 40),
      expiresOn: optionalDay(body, 'expiresOn'),
      msRegistration: optionalText(body, 'msRegistration', 13),
      reason: optionalText(body, 'reason', 500),
    };
    await this.database.withContext((client) =>
      client.query('SELECT app.update_product_batch($1, $2::jsonb)', [batchId, JSON.stringify(data)]),
    );
    return { status: 'ok' };
  }
}
