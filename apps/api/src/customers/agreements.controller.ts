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
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** Data no formato AAAA-MM-DD; vazio vira null (o banco sugere o último fechamento). */
function optionalDay(value: unknown): string | null {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || !DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
    throw new AppError('FA005');
  }
  return value;
}

function requireDay(value: unknown): string {
  const day = optionalDay(value);
  if (day === null) throw new AppError('FA005');
  return day;
}

/** Convênios. Quem cria e vincula é decidido no banco, pela permissão agreements.manage. */
@Controller('admin/agreements')
@UseGuards(SessionGuard)
export class AgreementsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT a.id, a.name, a.cnpj, a.closing_day,
                (SELECT count(*)::int FROM v_customer_agreement ca WHERE ca.agreement_id = a.id) AS customers
           FROM v_agreement a
          ORDER BY a.name`,
      );
      return rows;
    });
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const name = optionalText(body, 'name', 150);
    const cnpj = optionalText(body, 'cnpj', 20);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_agreement($1, $2) AS id',
        [name, cnpj],
      );
      return { id: rows[0].id };
    });
  }

  @Patch(':id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const agreementId = requireUuid(id);
    const body = asBody(rawBody);
    const name = optionalText(body, 'name', 150);
    const cnpj = optionalText(body, 'cnpj', 20);
    await this.database.withContext((client) =>
      client.query('SELECT app.update_agreement($1, $2, $3)', [agreementId, name, cnpj]),
    );
    return { status: 'ok' };
  }

  /** Dia do mês em que a fatura do convênio fecha (1 a 28). */
  @Patch(':id/closing-day')
  async setClosingDay(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const agreementId = requireUuid(id);
    const day = asBody(rawBody).day;
    if (typeof day !== 'number' || !Number.isInteger(day)) throw new AppError('FA005');
    await this.database.withContext((client) =>
      client.query('SELECT app.set_agreement_closing_day($1, $2)', [agreementId, day]),
    );
    return { status: 'ok' };
  }

  /** O que entraria na fatura fechada até a data (sem data, até o último fechamento). */
  @Get(':id/invoice-preview')
  preview(@Param('id') id: string, @Query('until') until?: string) {
    const agreementId = requireUuid(id);
    const day = optionalDay(until);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ preview: unknown }>(
        'SELECT app.agreement_invoice_preview($1, $2::date) AS preview',
        [agreementId, day],
      );
      return rows[0].preview;
    });
  }

  @Get(':id/invoices')
  invoices(@Param('id') id: string) {
    const agreementId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.list_agreement_invoices($1)', [agreementId]);
      return rows;
    });
  }

  /** Fecha a fatura com as vendas e devoluções ainda não faturadas até a data. */
  @Post(':id/invoices')
  close(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const agreementId = requireUuid(id);
    const until = requireDay(asBody(rawBody).until);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.close_agreement_invoice($1, $2::date) AS id',
        [agreementId, until],
      );
      return { id: rows[0].id };
    });
  }

  @Post(':id/delete')
  @HttpCode(200)
  async remove(@Param('id') id: string) {
    const agreementId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.delete_agreement($1)', [agreementId]),
    );
    return { status: 'ok' };
  }
}

/** Faturas do convênio: detalhe, pagamento e cancelamento. As regras ficam no banco. */
@Controller('admin/agreement-invoices')
@UseGuards(SessionGuard)
export class AgreementInvoicesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get(':id')
  detail(@Param('id') id: string) {
    const invoiceId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ detail: unknown }>(
        'SELECT app.agreement_invoice_detail($1) AS detail',
        [invoiceId],
      );
      return rows[0].detail;
    });
  }

  @Post(':id/pay')
  @HttpCode(200)
  async pay(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const invoiceId = requireUuid(id);
    const body = asBody(rawBody);
    const paidOn = requireDay(body.paidOn);
    const note = optionalText(body, 'note', 500);
    await this.database.withContext((client) =>
      client.query('SELECT app.pay_agreement_invoice($1, $2::date, $3)', [invoiceId, paidOn, note]),
    );
    return { status: 'ok' };
  }

  @Post(':id/cancel')
  @HttpCode(200)
  async cancel(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const invoiceId = requireUuid(id);
    const reason = optionalText(asBody(rawBody), 'reason', 500) ?? '';
    await this.database.withContext((client) =>
      client.query('SELECT app.cancel_agreement_invoice($1, $2)', [invoiceId, reason]),
    );
    return { status: 'ok' };
  }
}
