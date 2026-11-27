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
import { Throttle } from '@nestjs/throttler';
import { verifyPassword } from '../auth/password.js';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, Body, optionalText, requireText, requireUuid } from '../common/parse.js';
import { appEnvironment } from '../config/environment.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { readAuthorizedNfe, sha256 } from './nfe-xml.js';

const STATUSES = new Set(['review', 'not_postable', 'posted', 'cancelled']);
const MAX_BATCHES = 50;

function optionalUuid(body: Body, field: string): string | null {
  const value = body[field];
  return value === undefined || value === null || value === '' ? null : requireUuid(value);
}

/** Lotes digitados: só confere o formato; o banco confere número, datas, quantidade e repetição. */
function batchList(body: Body): unknown[] {
  const value = body.batches;
  if (!Array.isArray(value) || value.length > MAX_BATCHES) throw new AppError('FA936');
  return value.map((entry: unknown) => {
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) throw new AppError('FA936');
    const batch = entry as Body;
    const text = (field: string, max: number, required: boolean) => {
      const raw = batch[field];
      if (raw === undefined || raw === null || raw === '') {
        if (required) throw new AppError('FA936');
        return null;
      }
      if (typeof raw !== 'string' && typeof raw !== 'number') throw new AppError('FA936');
      const textValue = String(raw).trim();
      if (textValue.length > max) throw new AppError('FA936');
      return textValue;
    };
    return {
      number: text('number', 20, true),
      quantity: text('quantity', 20, true),
      expiresOn: text('expiresOn', 10, true),
      manufacturedOn: text('manufacturedOn', 10, false),
    };
  });
}

function optionalBoolean(body: Body, field: string): boolean | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'boolean') throw new AppError('FA005');
  return value;
}

/** Notas de compra: importação e conferência. As regras e as permissões ficam no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class PurchaseInvoicesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  @Get('purchase-invoices')
  list(@Query('branch') branch?: string, @Query('status') status?: string) {
    const branchId = branch ? requireUuid(branch) : null;
    if (status !== undefined && status !== '' && !STATUSES.has(status)) {
      throw new AppError('FA005');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.list_purchase_invoices($1, $2)', [branchId, status || null]);
      return rows;
    });
  }

  /**
   * O XML chega como texto (application/xml). A assinatura, o protocolo e a chave são conferidos
   * aqui; quem decide filial, permissão e situação é o banco. O motivo de uma recusa vai só para o log.
   */
  @Post('purchase-invoices')
  @Throttle({ default: { limit: 60, ttl: 60_000 } })
  import(@RequestBody() raw: unknown) {
    if (typeof raw !== 'string' || raw.trim() === '') {
      throw new AppError('FA930');
    }
    const { detail, ...data } = readAuthorizedNfe(raw);
    const acceptsTest = appEnvironment() !== 'production';
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.import_purchase_invoice($1::jsonb, $2, $3, $4) AS id',
        [JSON.stringify(data), raw, sha256(raw), acceptsTest],
      );
      const id = rows[0].id;
      // Os dados completos e as duplicatas: se falhar, a nota fica importada e a rotina tenta depois.
      await client.query('SAVEPOINT content');
      try {
        await client.query('SELECT app.store_purchase_content($1, $2::jsonb, $3::jsonb)', [
          id, JSON.stringify(detail.content), JSON.stringify(detail.installments),
        ]);
        await client.query('RELEASE SAVEPOINT content');
      } catch (error) {
        await client.query('ROLLBACK TO SAVEPOINT content');
        this.logger.pino.warn({ context: 'PurchaseInvoices', invoiceId: id, err: error }, 'conteúdo da nota não gravado na importação');
      }
      return { id };
    });
  }

  @Get('purchase-invoices/:id')
  detail(@Param('id') id: string) {
    const invoiceId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT i.id, i.branch_id, b.name AS branch_name, i.supplier_id,
                COALESCE(s.trade_name, s.legal_name, i.emitter_name) AS supplier_name, i.emitter_cnpj, i.emitter_name,
                i.access_key, i.series, i.number, i.issued_at, i.authorized_at, i.protocol_number, i.environment,
                i.operation_type, i.purpose, i.products_total, i.discount_total, i.freight_total, i.insurance_total,
                i.other_total, i.ipi_total, i.st_total, i.invoice_total, i.status, i.not_postable_reason, i.created_at,
                i.source, i.confirmation, i.confirmation_required, i.confirmed_at, i.confirmation_message, i.cancelled_at,
                u.name AS author, app.has_permission('purchases.manage', i.branch_id) AS can_manage,
                app.has_permission('purchases.post', i.branch_id) AS can_post,
                app.has_permission('purchases.cost_override', i.branch_id) AS can_override_cost
           FROM v_purchase_invoice i
           JOIN v_branch b ON b.id = i.branch_id
           LEFT JOIN v_supplier s ON s.id = i.supplier_id
           LEFT JOIN v_user_account u ON u.id = i.updated_by
          WHERE i.id = $1`,
        [invoiceId],
      );
      if (rows.length === 0) {
        throw new AppError('FA006');
      }
      const items = await client.query<{ id: string }>('SELECT * FROM app.purchase_invoice_items($1)', [invoiceId]);
      const posting = await client.query<{ item_id: string }>('SELECT * FROM app.purchase_invoice_posting($1)', [invoiceId]);
      const byItem = new Map(posting.rows.map(({ item_id: itemId, ...rest }) => [itemId, rest]));
      const events = await client.query(
        `SELECT e.kind, e.reason, e.created_at, u.name AS user_name
           FROM v_purchase_invoice_event e
           LEFT JOIN v_user_account u ON u.id = e.user_id
          WHERE e.invoice_id = $1
          ORDER BY e.created_at, e.id`,
        [invoiceId],
      );
      // Conteúdo completo do XML, duplicatas e auditoria (lançada, estornada e as alterações).
      const extra = await client.query<{ x: Record<string, unknown> | null }>('SELECT app.purchase_invoice_extra($1) AS x', [invoiceId]);
      return {
        ...rows[0],
        items: items.rows.map((item) => ({ ...item, posting: byItem.get(item.id) ?? null })),
        events: events.rows,
        content: extra.rows[0]?.x?.content ?? null,
        content_read_at: extra.rows[0]?.x?.content_read_at ?? null,
        content_error: extra.rows[0]?.x?.content_error ?? null,
        installments: extra.rows[0]?.x?.installments ?? [],
        audit: extra.rows[0]?.x?.audit ?? [],
      };
    });
  }

  @Post('purchase-invoices/:id/discard')
  @HttpCode(200)
  async discard(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const invoiceId = requireUuid(id);
    const reason = optionalText(asBody(rawBody), 'reason', 500);
    await this.database.withContext((client) =>
      client.query('SELECT app.discard_purchase_invoice($1, $2)', [invoiceId, reason]),
    );
    return { status: 'ok' };
  }

  @Post('purchase-invoices/:id/post')
  @HttpCode(200)
  async post(@Param('id') id: string) {
    const invoiceId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.post_purchase_invoice($1)', [invoiceId]),
    );
    return { status: 'ok' };
  }

  @Post('purchase-invoices/:id/reverse')
  @HttpCode(200)
  async reverse(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const invoiceId = requireUuid(id);
    const reason = optionalText(asBody(rawBody), 'reason', 500);
    await this.database.withContext((client) =>
      client.query('SELECT app.reverse_purchase_invoice($1, $2)', [invoiceId, reason]),
    );
    return { status: 'ok' };
  }

  @Post('purchase-invoice-items/:id/batches')
  @HttpCode(200)
  async setBatches(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const itemId = requireUuid(id);
    const batches = batchList(asBody(rawBody));
    await this.database.withContext((client) =>
      client.query('SELECT app.set_purchase_item_batches($1, $2::jsonb)', [itemId, JSON.stringify(batches)]),
    );
    return { status: 'ok' };
  }

  /** O banco confere a permissão e a trava; a senha só a API consegue conferir, porque o Argon2 fica aqui. */
  @Post('purchase-invoice-items/:id/release-cost')
  @HttpCode(200)
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  async releaseCost(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const itemId = requireUuid(id);
    const reason = optionalText(body, 'reason', 500);
    const password = requireText(body, 'password', 200);
    await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ hash: string | null }>('SELECT app.current_password_hash() AS hash');
      const currentHash = rows[0].hash;
      if (!currentHash || !(await verifyPassword(currentHash, password))) {
        throw new AppError('FA409');
      }
      await client.query('SELECT app.release_purchase_item_cost($1, $2)', [itemId, reason]);
    });
    return { status: 'ok' };
  }

  @Get('products/:id/average-costs')
  averageCosts(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.product_average_costs($1)', [productId]);
      return rows;
    });
  }

  @Post('purchase-invoice-items/:id/link')
  @HttpCode(200)
  link(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const itemId = requireUuid(id);
    const productId = requireUuid(asBody(rawBody).productId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>(
        'SELECT app.link_purchase_item($1, $2) AS result',
        [itemId, productId],
      );
      return rows[0].result;
    });
  }

  @Post('purchase-invoice-items/:id/duplicate')
  duplicate(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const itemId = requireUuid(id);
    const body = asBody(rawBody);
    const sourceId = requireUuid(body.sourceProductId);
    const data = {
      displayName: optionalText(body, 'displayName', 150),
      barcode: optionalText(body, 'barcode', 30),
      barcodeIsInternal: optionalBoolean(body, 'barcodeIsInternal'),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.duplicate_product_for_item($1, $2, $3::jsonb) AS id',
        [itemId, sourceId, JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Post('purchase-invoice-items/:id/catalog')
  fromCatalog(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const itemId = requireUuid(id);
    const body = asBody(rawBody);
    const data = {
      catalogProductId: requireUuid(body.catalogProductId),
      displayName: requireText(body, 'displayName', 150),
      barcode: optionalText(body, 'barcode', 30),
      barcodeIsInternal: optionalBoolean(body, 'barcodeIsInternal'),
      categoryId: optionalUuid(body, 'categoryId'),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_product_for_item($1, $2::jsonb) AS id',
        [itemId, JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }
}
