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
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, Body, optionalText, requireText, requireUuid } from '../common/parse.js';
import { appEnvironment } from '../config/environment.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { readAuthorizedNfe, sha256 } from './nfe-xml.js';

const STATUSES = new Set(['review', 'not_postable']);

function optionalUuid(body: Body, field: string): string | null {
  const value = body[field];
  return value === undefined || value === null || value === '' ? null : requireUuid(value);
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
    const data = readAuthorizedNfe(raw);
    const acceptsTest = appEnvironment() !== 'production';
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.import_purchase_invoice($1::jsonb, $2, $3, $4) AS id',
        [JSON.stringify(data), raw, sha256(raw), acceptsTest],
      );
      return { id: rows[0].id };
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
                u.name AS author, app.has_permission('purchases.manage', i.branch_id) AS can_manage
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
      const items = await client.query('SELECT * FROM app.purchase_invoice_items($1)', [invoiceId]);
      return { ...rows[0], items: items.rows };
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
