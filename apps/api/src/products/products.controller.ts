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
import {
  asBody,
  Body,
  optionalText,
  requireText,
  requireUuid,
} from '../common/parse.js';
import { CatalogSyncService } from '../catalog/catalog-sync.service.js';
import { DatabaseService, DbClient } from '../database.service.js';
import { catalogImages, withMainImage } from './catalog-images.js';
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

const MAX_MONEY = 9_999_999_999.99;

/** Mais de dois decimais seria arredondado em silêncio pelo banco, então é recusado aqui. */
function money(value: unknown): number {
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    Math.abs(value) > MAX_MONEY ||
    Number(value.toFixed(2)) !== value
  ) {
    throw new AppError('FA005');
  }
  return value;
}

function branchList(body: Body): string[] {
  const list = uuidList(body, 'branchIds');
  if (list.length === 0) {
    throw new AppError('FA005');
  }
  return list;
}

/** Origem do vínculo com o Catálogo informada pela tela: busca automática pelo código de barras ou à mão. */
function catalogSource(body: Body): 'manual' | 'barcode' | null {
  const value = body.catalogSource;
  if (value === undefined || value === null || value === '') return null;
  if (value !== 'manual' && value !== 'barcode') throw new AppError('FA005');
  return value;
}

function searchKind(value: unknown): 'search' | 'lookup' {
  if (value !== 'search' && value !== 'lookup') throw new AppError('FA005');
  return value;
}

/** A busca que levou ao item do Catálogo no cadastro novo; fica na auditoria do produto. */
function catalogLookup(body: Body): { kind: 'search' | 'lookup'; query: string; resultCount: number } | null {
  const value = body.catalogLookup;
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw new AppError('FA005');
  const lookup = value as Body;
  const resultCount = lookup.resultCount;
  if (typeof resultCount !== 'number' || !Number.isInteger(resultCount) || resultCount < 0 || resultCount > 1000) {
    throw new AppError('FA005');
  }
  return { kind: searchKind(lookup.kind), query: requireText(lookup, 'query', 200), resultCount };
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
  // Sigla da lista fixa (UN, CX, KG...); o banco confere. Vazia: UN no cadastro, a atual na alteração.
  unit: optionalText(body, 'unit', 10),
  catalogSource: catalogSource(body),
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
    @Inject(CatalogSyncService) private readonly catalogSync: CatalogSyncService,
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
  search(@Query('q') query?: string, @Query('inativos') inactive?: string) {
    if (query !== undefined && (typeof query !== 'string' || query.length > 200)) {
      throw new AppError('FA005');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT * FROM app.search_products($1, 50, $2)',
        [query ?? '', inactive === '1'],
      );
      return withMainImage(client, rows, 'catalog_product_id');
    });
  }

  @Get('products/:id')
  detail(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT p.id, p.code, p.display_name, p.catalog_product_id, p.own_manufacturer, p.category_id,
                p.commission_group_id, p.pricing_group_id, p.price_family_id, p.uses_pmc,
                p.online_sale_blocked, p.fraction_quantity, p.unit,
                cp.name AS catalog_name, cp.active_ingredient, m.name AS catalog_manufacturer,
                cp.brand AS catalog_brand, cp.department AS catalog_department,
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
      const grid = await client.query(
        `SELECT g.*, a.sellable, a.auto_purchase, a.notice, a.sellable_quantity
           FROM app.product_branch_grid($1) g
           LEFT JOIN LATERAL app.product_availability($1, g.branch_id) a ON true`,
        [productId],
      );
      const pmc = await client.query(
        `SELECT pm.state, pm.pmc_region, pm.value, pm.source, pm.created_at, u.name AS author
           FROM v_product_pmc pm
           LEFT JOIN v_user_account u ON u.id = pm.updated_by
          WHERE pm.product_id = $1
         UNION ALL
         SELECT cm.state, cm.pmc_region, cm.value, 'catalog', cm.created_at, NULL
           FROM v_catalog_product_pmc cm
           JOIN v_product p ON p.catalog_product_id = cm.catalog_product_id
          WHERE p.id = $1
          ORDER BY created_at DESC
          LIMIT 50`,
        [productId],
      );
      const prices = await client.query(
        `SELECT pp.branch_id, b.name AS branch_name, pp.price, pp.reason, pp.created_at, u.name AS author
           FROM v_product_price pp
           LEFT JOIN v_branch b ON b.id = pp.branch_id
           LEFT JOIN v_user_account u ON u.id = pp.updated_by
          WHERE pp.product_id = $1
          ORDER BY pp.created_at DESC, pp.id DESC
          LIMIT 50`,
        [productId],
      );
      const events = await client.query(
        `SELECT b.name AS branch_name, e.old_status, e.new_status, e.reason, e.created_at, u.name AS author
           FROM v_product_status_event e
           JOIN v_product_branch_status s ON s.id = e.product_branch_status_id
           LEFT JOIN v_branch b ON b.id = e.branch_id
           LEFT JOIN v_user_account u ON u.id = e.updated_by
          WHERE s.product_id = $1
          ORDER BY e.created_at DESC, e.id DESC
          LIMIT 50`,
        [productId],
      );
      const images = await catalogImages(client, [rows[0].catalog_product_id as string | null]);
      return {
        ...rows[0],
        images: images.map(({ id: imageId, is_main: isMain, width, height }) => ({ id: imageId, is_main: isMain, width, height })),
        barcodes: barcodes.rows,
        grid: grid.rows,
        pmc: pmc.rows,
        prices: prices.rows,
        status_events: events.rows,
      };
    });
  }

  /** Regra em vigor em cada filial que o usuário enxerga. A regra de escolha fica no banco. */
  @Get('products/:id/tax')
  tax(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        // A última coluna de mesmo nome vence: a data sai como texto, sem passar por fuso.
        `SELECT b.id AS branch_id, b.name AS branch_name, r.*, r.valid_from::text AS valid_from
           FROM v_branch b
           CROSS JOIN LATERAL app.resolve_product_tax($1, b.id) r
          ORDER BY b.name`,
        [productId],
      );
      if (rows.length === 0) {
        throw new AppError('FA006');
      }
      return rows;
    });
  }

  /** Preço da rede, sem filial, ou exceção da filial. Preço vazio encerra a exceção. */
  @Post('products/:id/prices')
  setPrice(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const price = body.price === null ? null : money(body.price);
    return this.create('SELECT app.set_product_price($1, $2, $3, $4) AS id', [
      requireUuid(id),
      optionalUuid(body, 'branchId'),
      price,
      optionalText(body, 'reason', 500),
    ]);
  }

  @Post('products/:id/pmc')
  addPmc(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.create('SELECT app.add_product_pmc($1, $2, $3, $4) AS id', [
      requireUuid(id),
      requireText(body, 'state', 2),
      optionalText(body, 'region', 30),
      money(body.value),
    ]);
  }

  @Post('products/:id/status')
  @HttpCode(200)
  setStatus(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.call('SELECT app.set_product_status($1, $2, $3, $4)', [
      requireUuid(id),
      branchList(body),
      requireText(body, 'status', 20),
      optionalText(body, 'reason', 500),
    ]);
  }

  /** O banco confere a permissão; a senha só a API consegue conferir, porque o Argon2 fica aqui. */
  @Post('products/:id/reactivate')
  @HttpCode(200)
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  async reactivate(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const productId = requireUuid(id);
    const branchIds = branchList(body);
    const status = requireText(body, 'status', 20);
    const reason = optionalText(body, 'reason', 500);
    const password = requireText(body, 'password', 200);

    const currentHash = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ hash: string | null }>(
        'SELECT app.current_password_hash() AS hash',
      );
      return rows[0].hash;
    });
    if (!currentHash || !(await verifyPassword(currentHash, password))) {
      throw new AppError('FA409');
    }
    return this.call('SELECT app.reactivate_product($1, $2, $3, $4)', [
      productId,
      branchIds,
      status,
      reason,
    ]);
  }

  @Post('branches/:id/location')
  @HttpCode(200)
  setBranchLocation(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.call('SELECT app.set_branch_location($1, $2, $3)', [
      requireUuid(id),
      optionalText(body, 'state', 2),
      optionalText(body, 'region', 30),
    ]);
  }

  @Post('products')
  createProduct(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const data = {
      ...productData(body),
      barcode: requireText(body, 'barcode', 30),
      barcodeIsInternal: optionalBoolean(body, 'barcodeIsInternal'),
      catalogLookup: catalogLookup(body),
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

  /**
   * Consulta ao Catálogo para preencher o cadastro. Feita na tela de um produto (productId), fica na
   * auditoria dele: `search` é a busca manual; `lookup`, a automática pelo código de barras.
   */
  @Get('catalog')
  async catalog(@Query('q') query?: string, @Query('productId') productId?: string, @Query('kind') kind?: string) {
    if (query !== undefined && (typeof query !== 'string' || query.length > 200)) {
      throw new AppError('FA005');
    }
    const product = productId === undefined ? null : requireUuid(productId);
    const searchType = product ? searchKind(kind ?? 'search') : null;
    const search = (client: DbClient) =>
      client.query<{ id: string; barcodes: string[] }>('SELECT * FROM app.search_catalog($1)', [query ?? '']).then((r) => r.rows);
    // Código de barras que a cópia do Catálogo não tem: consulta o Catálogo na hora (fora da
    // transação da busca) e procura de novo. Só quem está logado chega aqui.
    const code = query?.trim() ?? '';
    if (/^\d{8,14}$/.test(code) && this.catalogSync.configured) {
      const found = await this.database.withContext(async (client) => (await search(client)).length > 0);
      if (!found) await this.catalogSync.lookup(code);
    }
    return this.database.withContext(async (client) => {
      const rows = await search(client);
      if (product && searchType && query?.trim()) {
        // Na automática, o item achado é o que tem exatamente este código.
        const found = searchType === 'lookup' ? rows.filter((row) => row.barcodes.includes(query.trim())) : rows;
        await client.query('SELECT app.record_catalog_search($1, $2, $3, $4, $5)', [
          product,
          searchType,
          query,
          found.length,
          searchType === 'lookup' && found.length === 1 ? found[0].id : null,
        ]);
      }
      return withMainImage(client, rows, 'id');
    });
  }

  /** Auditoria do Catálogo no produto: buscas e vínculos, do mais novo para o mais antigo. */
  @Get('products/:id/catalog-history')
  catalogHistory(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.product_catalog_history($1)', [productId]);
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
      // Unidades de medida aceitas no cadastro (lista fixa do banco).
      const units = await client.query('SELECT code, name, fractional FROM app.measure_units()');
      return {
        categories: categories.rows,
        groups: groups.rows,
        channels: channels.rows,
        units: units.rows,
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
