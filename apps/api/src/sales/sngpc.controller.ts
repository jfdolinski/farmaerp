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
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { verifyPassword } from '../auth/password.js';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, Body, optionalText, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const STATUSES = new Set(['pending', 'confirmed', 'sent', 'accepted', 'rejected', 'disregarded']);
const COMPLEMENT_TEXT = [
  'prescriptionType', 'prescriptionNumber', 'prescriptionDate', 'prescriberName', 'prescriberCouncil', 'prescriberNumber',
  'prescriberState', 'buyerName', 'buyerDocumentType', 'buyerDocument', 'buyerIssuer', 'buyerState', 'patientName', 'patientSex',
];

function day(value: unknown): string {
  if (typeof value !== 'string' || !DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
    throw new AppError('FA005');
  }
  return value;
}

function quantity(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0 || value > 99_999_999 || Number(value.toFixed(3)) !== value) {
    throw new AppError('FA005');
  }
  return value;
}

function uuidList(body: Body): string[] {
  const ids = body.ids;
  if (!Array.isArray(ids) || ids.length === 0 || ids.length > 500) throw new AppError('FA005');
  return ids.map((id) => requireUuid(id));
}

/**
 * Manutenção do SNGPC (entreposto). Quem pode, a ordem, o saldo por lote e o que falta são
 * decididos no banco. A conferência pede a senha de quem confere.
 */
@Controller('admin/sngpc')
@UseGuards(SessionGuard)
export class SngpcController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('branches')
  branches() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.sngpc_branches()')).rows);
  }

  @Post('branches/:branchId/open')
  @HttpCode(200)
  open(@Param('branchId') branchId: string) {
    const id = requireUuid(branchId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.sngpc_open($1) AS result', [id]);
      return rows[0].result;
    });
  }

  @Get('branches/:branchId/movements')
  movements(@Param('branchId') branchId: string, @Query('status') status = 'pending') {
    const id = requireUuid(branchId);
    if (!STATUSES.has(status)) throw new AppError('FA005');
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.sngpc_movements($1, $2)', [id, status])).rows,
    );
  }

  @Get('branches/:branchId/batches')
  batches(@Param('branchId') branchId: string, @Query('productId') productId?: string) {
    const id = requireUuid(branchId);
    const product = requireUuid(productId);
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.sngpc_batches($1, $2)', [id, product])).rows,
    );
  }

  @Post('branches/:branchId/inventory')
  addInventory(@Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(branchId);
    const body = asBody(rawBody);
    const batchId = requireUuid(body.batchId);
    const amount = quantity(body.quantity);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.sngpc_add_inventory($1, $2, $3) AS id', [id, batchId, amount]);
      return { id: rows[0].id };
    });
  }

  /** Simulação: os problemas de cada movimentação escolhida (vazio = pode conferir). */
  @Post('branches/:branchId/check')
  @HttpCode(200)
  check(@Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(branchId);
    const ids = uuidList(asBody(rawBody));
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.sngpc_check($1, $2::uuid[])', [id, ids])).rows,
    );
  }

  /** Conferência: a senha de quem está na sessão, a escolha e a data de envio. */
  @Post('branches/:branchId/confirm')
  @HttpCode(200)
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  async confirm(@Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(branchId);
    const body = asBody(rawBody);
    const ids = uuidList(body);
    const sendOn = day(body.sendOn);
    const password = requireText(body, 'password', 200);
    const hash = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ hash: string | null }>('SELECT app.current_password_hash() AS hash');
      return rows[0].hash;
    });
    if (!hash || !(await verifyPassword(hash, password))) throw new AppError('FA409');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ confirmed: number }>(
        'SELECT app.sngpc_confirm($1, $2::uuid[], $3::date) AS confirmed',
        [id, ids, sendOn],
      );
      return { confirmed: rows[0].confirmed };
    });
  }

  /** Data do SNGPC, motivo da perda, lote (quando veio sem) ou quantidade do inventário. */
  @Patch('movements/:id')
  async update(@Param('id') movementId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(movementId);
    const body = asBody(rawBody);
    const data: Record<string, unknown> = {};
    if (body.reportedOn !== undefined) data.reportedOn = day(body.reportedOn);
    if (body.lossReason !== undefined) data.lossReason = optionalText(body, 'lossReason', 30) ?? '';
    if (body.batchId !== undefined) data.batchId = requireUuid(body.batchId);
    if (body.quantity !== undefined) data.quantity = quantity(body.quantity);
    if (Object.keys(data).length === 0) throw new AppError('FA005');
    await this.database.withContext((client) =>
      client.query('SELECT app.sngpc_update_movement($1, $2::jsonb)', [id, JSON.stringify(data)]),
    );
    return { status: 'ok' };
  }

  /** Lote e receita da venda liberada como pendente no caixa. */
  @Post('movements/:id/complete')
  @HttpCode(200)
  async complete(@Param('id') movementId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(movementId);
    const body = asBody(rawBody);
    const data: Record<string, unknown> = { batchId: requireUuid(body.batchId) };
    for (const field of COMPLEMENT_TEXT) data[field] = optionalText(body, field, 150);
    if (body.patientAge !== undefined && body.patientAge !== null) {
      if (typeof body.patientAge !== 'number' || !Number.isInteger(body.patientAge)) throw new AppError('FA005');
      data.patientAge = body.patientAge;
    }
    await this.database.withContext((client) =>
      client.query('SELECT app.sngpc_complete_sale($1, $2::jsonb)', [id, JSON.stringify(data)]),
    );
    return { status: 'ok' };
  }

  @Post('movements/:id/disregard')
  @HttpCode(200)
  async disregard(@Param('id') movementId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(movementId);
    const reason = optionalText(asBody(rawBody), 'reason', 500) ?? '';
    await this.database.withContext((client) => client.query('SELECT app.sngpc_disregard($1, $2)', [id, reason]));
    return { status: 'ok' };
  }
}
