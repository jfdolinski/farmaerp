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
  optionalInstant,
  optionalText,
  requireText,
  requireUuid,
} from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const MAX_VALUE = 99_999_999;

/** Mais de quatro decimais seria arredondado em silêncio pelo banco, então é recusado aqui. */
function ruleValue(value: unknown): number {
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    Math.abs(value) > MAX_VALUE ||
    Number(value.toFixed(4)) !== value
  ) {
    throw new AppError('FA005');
  }
  return value;
}

function optionalInteger(body: Body, field: string): number | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new AppError('FA005');
  }
  return value;
}

function optionalUuid(body: Body, field: string): string | null {
  const value = body[field];
  return value === undefined || value === null ? null : requireUuid(value);
}

const editableFields = (body: Body) => ({
  value: ruleValue(body.value),
  priority: optionalInteger(body, 'priority'),
  validFrom: optionalInstant(body, 'validFrom'),
  validTo: optionalInstant(body, 'validTo'),
  reason: optionalText(body, 'reason', 500),
});

/** Motor de regras. A decisão e as permissões ficam no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class RulesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('rules')
  list(@Query('historico') history?: string) {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT * FROM app.list_product_rules($1)',
        [history === '1'],
      );
      return rows;
    });
  }

  @Get('rule-options')
  options() {
    return this.database.withContext(async (client) => {
      const types = await client.query(
        'SELECT code, name, unit, min_value, max_value FROM v_rule_type ORDER BY name',
      );
      // Só os fabricantes dos produtos da rede: o Catálogo inteiro não caberia em uma lista.
      const manufacturers = await client.query(
        `SELECT DISTINCT m.id, m.name
           FROM v_product p
           JOIN v_catalog_product cp ON cp.id = p.catalog_product_id
           JOIN v_catalog_manufacturer m ON m.id = cp.manufacturer_id
          ORDER BY m.name
          LIMIT 1000`,
      );
      return { types: types.rows, manufacturers: manufacturers.rows };
    });
  }

  /** O que vale agora para um produto, localizado pelo código ou pelo código de barras. */
  @Get('rules/simulate')
  simulate(
    @Query('product') product?: string,
    @Query('branch') branch?: string,
  ) {
    if (typeof product !== 'string' || product.trim() === '' || product.length > 30) {
      throw new AppError('FA005');
    }
    const branchId = branch ? requireUuid(branch) : null;
    return this.database.withContext(async (client) => {
      const found = await client.query<{ id: string | null }>(
        'SELECT app.find_product_id($1) AS id',
        [product],
      );
      const productId = found.rows[0].id;
      if (!productId) {
        throw new AppError('FA006');
      }
      const visible = await client.query<{ display_name: string; code: string }>(
        'SELECT display_name, code FROM v_product WHERE id = $1',
        [productId],
      );
      if (visible.rows.length === 0) {
        throw new AppError('FA006');
      }
      const { rows } = await client.query(
        'SELECT * FROM app.simulate_product_rules($1, $2)',
        [productId, branchId],
      );
      return { product: visible.rows[0], rules: rows };
    });
  }

  @Post('rules')
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const data = {
      ...editableFields(body),
      typeCode: requireText(body, 'typeCode', 40),
      level: requireText(body, 'level', 40),
      productLookup: optionalText(body, 'productLookup', 30),
      productGroupId: optionalUuid(body, 'productGroupId'),
      manufacturerId: optionalUuid(body, 'manufacturerId'),
      categoryId: optionalUuid(body, 'categoryId'),
      branchId: optionalUuid(body, 'branchId'),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_product_rule($1::jsonb) AS id',
        [JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  /** Encerra a regra e cria outra, por isso devolve um identificador novo. */
  @Patch('rules/:id')
  replace(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const ruleId = requireUuid(id);
    const data = editableFields(asBody(rawBody));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.replace_product_rule($1, $2::jsonb) AS id',
        [ruleId, JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Post('rules/:id/end')
  @HttpCode(200)
  async end(@Param('id') id: string) {
    const ruleId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.end_product_rule($1)', [ruleId]),
    );
    return { status: 'ok' };
  }
}
