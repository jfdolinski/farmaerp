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
import {
  asBody,
  Body,
  optionalText,
  requireText,
  requireUuid,
} from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const MAX_FRACTION = 9_999_999;

function optionalUuid(body: Body, field: string): string | null {
  const value = body[field];
  return value === undefined || value === null ? null : requireUuid(value);
}

function optionalBoolean(body: Body, field: string): boolean | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'boolean') {
    throw new AppError('FA005');
  }
  return value;
}

function optionalFraction(body: Body, field: string): number | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'number' || !Number.isFinite(value) || value > MAX_FRACTION) {
    throw new AppError('FA005');
  }
  return value;
}

function uuidList(body: Body, field: string): string[] {
  const value = body[field];
  if (value === undefined || value === null) {
    return [];
  }
  if (!Array.isArray(value)) {
    throw new AppError('FA005');
  }
  return value.map((item) => requireUuid(item));
}

const productData = (body: Body) => ({
  catalogProductId: optionalUuid(body, 'catalogProductId'),
  displayName: requireText(body, 'displayName', 200),
  ownManufacturer: optionalText(body, 'ownManufacturer', 200),
  categoryId: optionalUuid(body, 'categoryId'),
  commissionGroupId: optionalUuid(body, 'commissionGroupId'),
  pricingGroupId: optionalUuid(body, 'pricingGroupId'),
  priceFamilyId: optionalUuid(body, 'priceFamilyId'),
  usesPmc: optionalBoolean(body, 'usesPmc'),
  onlineSaleBlocked: optionalBoolean(body, 'onlineSaleBlocked'),
  fractionQuantity: optionalFraction(body, 'fractionQuantity'),
});

const barcodeOptions = (body: Body) => ({
  sendsToSupplier: optionalBoolean(body, 'sendsToSupplier'),
  scanEnabled: optionalBoolean(body, 'scanEnabled'),
  fractionQuantity: optionalFraction(body, 'fractionQuantity'),
  channels: uuidList(body, 'channels'),
});

/** Cadastro de produtos. As regras e as permissões ficam no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class ProductsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  private call(sql: string, params: unknown[]) {
    return this.database.withContext(async (client) => {
      await client.query(sql, params);
      return { status: 'ok' };
    });
  }

  private create(sql: string, params: unknown[]) {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(sql, params);
      return { id: rows[0].id };
    });
  }

  @Get('products')
  search(@Query('q') query?: string) {
    if (query !== undefined && (typeof query !== 'string' || query.length > 200)) {
      throw new AppError('FA005');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT * FROM app.search_products($1)',
        [query ?? ''],
      );
      return rows;
    });
  }

  @Get('products/:id')
  detail(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT p.id, p.code, p.display_name, p.catalog_product_id, p.own_manufacturer, p.category_id,
                p.commission_group_id, p.pricing_group_id, p.price_family_id, p.uses_pmc,
                p.online_sale_blocked, p.fraction_quantity,
                cp.name AS catalog_name, cp.active_ingredient, m.name AS catalog_manufacturer,
                cp.ms_registration, cp.controlled_class, cp.ncm, cp.cest
           FROM v_product p
           LEFT JOIN v_catalog_product cp ON cp.id = p.catalog_product_id
           LEFT JOIN v_catalog_manufacturer m ON m.id = cp.manufacturer_id
          WHERE p.id = $1`,
        [productId],
      );
      if (rows.length === 0) {
        throw new AppError('FA006');
      }
      const barcodes = await client.query(
        `SELECT b.id, b.code, b.is_internal, b.is_primary, b.sends_to_supplier, b.scan_enabled,
                b.fraction_quantity,
                app.effective_fraction(b.product_id, b.id) AS effective_fraction,
                COALESCE(
                  (SELECT array_agg(bc.channel_id)
                     FROM v_product_barcode_channel bc
                    WHERE bc.barcode_id = b.id),
                  '{}'
                ) AS channels
           FROM v_product_barcode b
          WHERE b.product_id = $1
          ORDER BY b.is_primary DESC, b.code`,
        [productId],
      );
      return { ...rows[0], barcodes: barcodes.rows };
    });
  }

  @Post('products')
  createProduct(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const data = {
      ...productData(body),
      barcode: requireText(body, 'barcode', 30),
      barcodeIsInternal: optionalBoolean(body, 'barcodeIsInternal'),
    };
    return this.create('SELECT app.create_product($1::jsonb) AS id', [
      JSON.stringify(data),
    ]);
  }

  @Patch('products/:id')
  updateProduct(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const productId = requireUuid(id);
    const data = productData(asBody(rawBody));
    return this.call('SELECT app.update_product($1, $2::jsonb)', [
      productId,
      JSON.stringify(data),
    ]);
  }

  @Post('products/:id/barcodes')
  addBarcode(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const productId = requireUuid(id);
    const body = asBody(rawBody);
    const data = {
      ...barcodeOptions(body),
      code: requireText(body, 'code', 30),
      isInternal: optionalBoolean(body, 'isInternal'),
    };
    return this.create('SELECT app.add_barcode($1, $2::jsonb) AS id', [
      productId,
      JSON.stringify(data),
    ]);
  }

  @Patch('barcodes/:id')
  updateBarcode(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const barcodeId = requireUuid(id);
    const data = barcodeOptions(asBody(rawBody));
    return this.call('SELECT app.update_barcode($1, $2::jsonb)', [
      barcodeId,
      JSON.stringify(data),
    ]);
  }

  @Post('barcodes/:id/primary')
  @HttpCode(200)
  setPrimary(@Param('id') id: string) {
    return this.call('SELECT app.set_primary_barcode($1)', [requireUuid(id)]);
  }

  @Post('barcodes/:id/remove')
  @HttpCode(200)
  removeBarcode(@Param('id') id: string) {
    return this.call('SELECT app.remove_barcode($1)', [requireUuid(id)]);
  }

  /** Consulta ao Catálogo para preencher o cadastro. */
  @Get('catalog')
  catalog(@Query('q') query?: string) {
    if (query !== undefined && (typeof query !== 'string' || query.length > 200)) {
      throw new AppError('FA005');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT * FROM app.search_catalog($1)',
        [query ?? ''],
      );
      return rows;
    });
  }

  @Get('product-structure')
  structure() {
    return this.database.withContext(async (client) => {
      const categories = await client.query(
        'SELECT id, parent_id, level, name FROM v_product_category ORDER BY level, name',
      );
      const groups = await client.query(
        'SELECT id, kind, name FROM v_product_group ORDER BY kind, name',
      );
      const channels = await client.query(
        'SELECT id, name FROM v_sales_channel ORDER BY name',
      );
      return {
        categories: categories.rows,
        groups: groups.rows,
        channels: channels.rows,
      };
    });
  }

  @Post('product-categories')
  createCategory(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.create('SELECT app.create_product_category($1, $2) AS id', [
      optionalUuid(body, 'parentId'),
      requireText(body, 'name', 100),
    ]);
  }

  @Patch('product-categories/:id')
  renameCategory(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.call('SELECT app.rename_product_category($1, $2)', [
      requireUuid(id),
      requireText(asBody(rawBody), 'name', 100),
    ]);
  }

  @Post('product-categories/:id/delete')
  @HttpCode(200)
  deleteCategory(@Param('id') id: string) {
    return this.call('SELECT app.delete_product_category($1)', [requireUuid(id)]);
  }

  @Post('product-groups')
  createGroup(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.create('SELECT app.create_product_group($1, $2) AS id', [
      requireText(body, 'kind', 20),
      requireText(body, 'name', 100),
    ]);
  }

  @Patch('product-groups/:id')
  renameGroup(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.call('SELECT app.rename_product_group($1, $2)', [
      requireUuid(id),
      requireText(asBody(rawBody), 'name', 100),
    ]);
  }

  @Post('product-groups/:id/delete')
  @HttpCode(200)
  deleteGroup(@Param('id') id: string) {
    return this.call('SELECT app.delete_product_group($1)', [requireUuid(id)]);
  }

  @Post('sales-channels')
  createChannel(@RequestBody() rawBody: unknown) {
    return this.create('SELECT app.create_sales_channel($1) AS id', [
      requireText(asBody(rawBody), 'name', 100),
    ]);
  }

  @Patch('sales-channels/:id')
  renameChannel(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.call('SELECT app.rename_sales_channel($1, $2)', [
      requireUuid(id),
      requireText(asBody(rawBody), 'name', 100),
    ]);
  }

  @Post('sales-channels/:id/delete')
  @HttpCode(200)
  deleteChannel(@Param('id') id: string) {
    return this.call('SELECT app.delete_sales_channel($1)', [requireUuid(id)]);
  }
}
