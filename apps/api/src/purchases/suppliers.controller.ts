import {
  Body as RequestBody,
  Controller,
  Get,
  Inject,
  Param,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, Body, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const MAX_FRACTION = 9_999_999;

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

/** Campos vazios seguem como nulos: o banco recusa o que for obrigatório, com a mensagem certa. */
const supplierData = (body: Body) => ({
  cnpj: optionalText(body, 'cnpj', 30),
  legalName: optionalText(body, 'legalName', 150),
  tradeName: optionalText(body, 'tradeName', 150),
  stateRegistration: optionalText(body, 'stateRegistration', 20),
  phone: optionalText(body, 'phone', 30),
  email: optionalText(body, 'email', 200),
  postalCode: optionalText(body, 'postalCode', 20),
  street: optionalText(body, 'street', 150),
  streetNumber: optionalText(body, 'streetNumber', 20),
  complement: optionalText(body, 'complement', 100),
  district: optionalText(body, 'district', 100),
  city: optionalText(body, 'city', 100),
  cityCode: optionalText(body, 'cityCode', 10),
  state: optionalText(body, 'state', 2),
});

const SUPPLIER_COLUMNS = `id, cnpj, legal_name, trade_name, state_registration, phone, email, postal_code, street,
  street_number, complement, district, city, city_code, state::text AS state`;

/** Fornecedores e os códigos deles nos produtos. As regras e as permissões ficam no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class SuppliersController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('suppliers')
  search(@Query('q') query?: string, @Query('limit') limit?: string) {
    if (query !== undefined && (typeof query !== 'string' || query.length > 200)) {
      throw new AppError('FA005');
    }
    // O banco limita a 200; aqui só se recusa o que não é número.
    if (limit !== undefined && (typeof limit !== 'string' || !/^\d{1,3}$/.test(limit))) {
      throw new AppError('FA005');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.search_suppliers($1, $2)', [query ?? '', limit ? Number(limit) : 50]);
      return rows;
    });
  }

  @Get('suppliers/:id')
  detail(@Param('id') id: string) {
    const supplierId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(`SELECT ${SUPPLIER_COLUMNS} FROM v_supplier WHERE id = $1`, [supplierId]);
      if (rows.length === 0) {
        throw new AppError('FA006');
      }
      // Produto que o usuário não enxerga não aparece: a relação existe, mas sem nome para mostrar.
      const products = await client.query(
        `SELECT ps.id, ps.supplier_code, ps.fraction_quantity, ps.product_id, p.code AS product_code,
                p.display_name AS product_name,
                app.effective_fraction(ps.product_id, NULL, ps.id) AS effective_fraction
           FROM v_product_supplier ps
           JOIN v_product p ON p.id = ps.product_id
          WHERE ps.supplier_id = $1
          ORDER BY p.display_name, ps.supplier_code
          LIMIT 500`,
        [supplierId],
      );
      return { ...rows[0], products: products.rows };
    });
  }

  @Post('suppliers')
  create(@RequestBody() rawBody: unknown) {
    const data = supplierData(asBody(rawBody));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.create_supplier($1::jsonb) AS id', [
        JSON.stringify(data),
      ]);
      return { id: rows[0].id };
    });
  }

  @Patch('suppliers/:id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const supplierId = requireUuid(id);
    const data = supplierData(asBody(rawBody));
    await this.database.withContext((client) =>
      client.query('SELECT app.update_supplier($1, $2::jsonb)', [supplierId, JSON.stringify(data)]),
    );
    return { status: 'ok' };
  }

  @Post('suppliers/:id/delete')
  async remove(@Param('id') id: string) {
    const supplierId = requireUuid(id);
    await this.database.withContext((client) => client.query('SELECT app.delete_supplier($1)', [supplierId]));
    return { status: 'ok' };
  }

  /** Códigos de fornecedor do produto, com o fracionamento que vale em cada um. */
  @Get('products/:id/suppliers')
  productSuppliers(@Param('id') id: string) {
    const productId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT ps.id, ps.supplier_id, s.legal_name AS supplier_name, s.cnpj AS supplier_cnpj, ps.supplier_code,
                ps.fraction_quantity, app.effective_fraction(ps.product_id, NULL, ps.id) AS effective_fraction
           FROM v_product_supplier ps
           JOIN v_supplier s ON s.id = ps.supplier_id
          WHERE ps.product_id = $1
          ORDER BY s.legal_name, ps.supplier_code`,
        [productId],
      );
      return rows;
    });
  }

  @Post('products/:id/suppliers')
  addProductSupplier(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const productId = requireUuid(id);
    const body = asBody(rawBody);
    const data = {
      supplierId: requireUuid(body.supplierId),
      supplierCode: optionalText(body, 'supplierCode', 60),
      fractionQuantity: optionalFraction(body, 'fractionQuantity'),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.add_product_supplier($1, $2::jsonb) AS id',
        [productId, JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Patch('product-suppliers/:id')
  async updateProductSupplier(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const relationId = requireUuid(id);
    const fraction = optionalFraction(asBody(rawBody), 'fractionQuantity');
    await this.database.withContext((client) =>
      client.query('SELECT app.update_product_supplier($1, $2)', [relationId, fraction]),
    );
    return { status: 'ok' };
  }

  @Post('product-suppliers/:id/remove')
  async removeProductSupplier(@Param('id') id: string) {
    const relationId = requireUuid(id);
    await this.database.withContext((client) => client.query('SELECT app.remove_product_supplier($1)', [relationId]));
    return { status: 'ok' };
  }
}
