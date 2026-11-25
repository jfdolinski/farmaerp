import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, Body, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const SITUATIONS = new Set(['all', 'debt', 'overdue', 'blocked']);
const MODES = new Set(['closing', 'days']);

/** Valor em reais com até 2 casas, entre min e max. */
function money(value: unknown, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max || Number(value.toFixed(2)) !== value) {
    throw new AppError('FA005');
  }
  return value;
}

function wholeNumber(body: Body, field: string): number | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 1000) {
    throw new AppError('FA005');
  }
  return value;
}

function decimal(body: Body, field: string): number | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  return money(value, 0, 1000);
}

function reason(body: Body): string {
  const value = optionalText(body, 'reason', 500);
  return value ?? '';
}

/** Crediário dos clientes. Quem pode ver e mexer, os limites e as contas são decididos no banco. */
@Controller('admin/credit')
@UseGuards(SessionGuard)
export class CreditController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('accounts')
  list(@Query('situation') situation = 'all', @Query('search') search?: string) {
    if (!SITUATIONS.has(situation) || (search !== undefined && search.length > 100)) throw new AppError('FA005');
    return this.database.withContext(
      async (client) =>
        (await client.query('SELECT * FROM app.list_credit_accounts($1, $2)', [situation, search?.trim() || null])).rows,
    );
  }

  @Get('customers/:id')
  async detail(@Param('id') id: string) {
    const customerId = requireUuid(id);
    const detail = await this.database.withContext(
      async (client) =>
        (await client.query<{ detail: unknown }>('SELECT app.credit_account_detail($1) AS detail', [customerId])).rows[0]
          ?.detail,
    );
    if (!detail) throw new AppError('FA006');
    return detail;
  }

  @Post('customers/:id/open')
  open(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const customerId = requireUuid(id);
    const body = asBody(rawBody);
    const branchId = requireUuid(body.homeBranchId);
    const limit = money(body.creditLimit, -1_000_000_000, 1_000_000_000);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.open_credit_account($1, $2, $3, $4) AS id', [
        customerId,
        branchId,
        limit,
        optionalText(body, 'reason', 500),
      ]);
      return { id: rows[0].id };
    });
  }

  @Post('accounts/:id/limit')
  @HttpCode(200)
  async limit(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const accountId = requireUuid(id);
    const body = asBody(rawBody);
    const value = money(body.creditLimit, -1_000_000_000, 1_000_000_000);
    await this.database.withContext((client) =>
      client.query('SELECT app.set_credit_limit($1, $2, $3)', [accountId, value, reason(body)]),
    );
    return { status: 'ok' };
  }

  @Post('accounts/:id/status')
  @HttpCode(200)
  async status(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const accountId = requireUuid(id);
    const body = asBody(rawBody);
    if (body.status !== 'active' && body.status !== 'blocked') throw new AppError('FA005');
    await this.database.withContext((client) =>
      client.query('SELECT app.set_credit_status($1, $2, $3)', [accountId, body.status, reason(body)]),
    );
    return { status: 'ok' };
  }

  @Post('accounts/:id/terms')
  @HttpCode(200)
  async terms(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const accountId = requireUuid(id);
    const body = asBody(rawBody);
    const mode = body.dueMode ?? null;
    if (mode !== null && (typeof mode !== 'string' || !MODES.has(mode))) throw new AppError('FA005');
    const terms = {
      due_mode: mode,
      closing_day: wholeNumber(body, 'closingDay'),
      due_day: wholeNumber(body, 'dueDay'),
      interval_days: wholeNumber(body, 'intervalDays'),
    };
    await this.database.withContext((client) =>
      client.query('SELECT app.set_credit_terms($1, $2::jsonb)', [accountId, JSON.stringify(terms)]),
    );
    return { status: 'ok' };
  }

  @Post('dependents/:id')
  @HttpCode(200)
  async dependent(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const dependentId = requireUuid(id);
    const body = asBody(rawBody);
    if (typeof body.allowed !== 'boolean') throw new AppError('FA005');
    await this.database.withContext((client) =>
      client.query('SELECT app.set_dependent_credit($1, $2)', [dependentId, body.allowed]),
    );
    return { status: 'ok' };
  }

  @Get('policies')
  policies() {
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_credit_policies()')).rows,
    );
  }

  @Post('policies/:branchId')
  @HttpCode(200)
  async setPolicy(@Param('branchId') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const body = asBody(rawBody);
    const mode = body.dueMode ?? null;
    if (mode !== null && (typeof mode !== 'string' || !MODES.has(mode))) throw new AppError('FA005');
    const policy = {
      late_fee_percent: decimal(body, 'lateFeePercent'),
      monthly_interest_percent: decimal(body, 'monthlyInterestPercent'),
      max_installments: wholeNumber(body, 'maxInstallments'),
      limit_factor: decimal(body, 'limitFactor'),
      block_after_days: wholeNumber(body, 'blockAfterDays'),
      due_mode: mode,
      closing_day: wholeNumber(body, 'closingDay'),
      due_day: wholeNumber(body, 'dueDay'),
      interval_days: wholeNumber(body, 'intervalDays'),
    };
    await this.database.withContext((client) =>
      client.query('SELECT app.set_credit_policy($1, $2::jsonb)', [branchId, JSON.stringify(policy)]),
    );
    return { status: 'ok' };
  }
}
