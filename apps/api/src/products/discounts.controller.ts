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
import { asBody, Body, optionalInstant, optionalText, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

function optionalNumber(body: Body, field: string, decimals: number): number | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > 99_999_999 || Number(value.toFixed(decimals)) !== value) {
    throw new AppError('FA005');
  }
  return value;
}

function optionalInteger(body: Body, field: string): number | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'number' || !Number.isInteger(value) || Math.abs(value) > 1_000_000) throw new AppError('FA005');
  return value;
}

function optionalUuid(body: Body, field: string): string | null {
  const value = body[field];
  return value === undefined || value === null || value === '' ? null : requireUuid(value);
}

const LINE_LIMIT = 50;

/** Item de venda de exemplo para o simulador: produto, quantidade e preço unitário. */
function simulatedLines(value: unknown) {
  if (!Array.isArray(value) || value.length === 0 || value.length > LINE_LIMIT) throw new AppError('FA005');
  return value.map((raw, index) => {
    const item = asBody(raw);
    const quantity = optionalNumber(item, 'quantity', 3);
    const unitPrice = optionalNumber(item, 'unitPrice', 2);
    if (quantity === null || quantity <= 0 || unitPrice === null || unitPrice < 0) throw new AppError('FA005');
    return { line: index + 1, product_lookup: requireText(item, 'product', 30), quantity, unit_price: unitPrice };
  });
}

/** Descontos automáticos (motor de regras) e grupos de clientes. Regras e permissões no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class DiscountsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('discount-rules')
  list(@Query('historico') history?: string, @Query('branch') branch?: string) {
    const branchId = branch ? requireUuid(branch) : null;
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_discount_rules($1, $2)', [branchId, history === '1'])).rows,
    );
  }

  @Post('discount-rules')
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const data = {
      name: requireText(body, 'name', 80),
      kind: requireText(body, 'kind', 40),
      level: requireText(body, 'level', 40),
      stacking: requireText(body, 'stacking', 20),
      productLookup: optionalText(body, 'productLookup', 30),
      productGroupId: optionalUuid(body, 'productGroupId'),
      manufacturerId: optionalUuid(body, 'manufacturerId'),
      categoryId: optionalUuid(body, 'categoryId'),
      branchId: optionalUuid(body, 'branchId'),
      percent: optionalNumber(body, 'percent', 4),
      buyQuantity: optionalInteger(body, 'buyQuantity'),
      payQuantity: optionalInteger(body, 'payQuantity'),
      minQuantity: optionalInteger(body, 'minQuantity'),
      paymentMethod: optionalText(body, 'paymentMethod', 20),
      customerGroupId: optionalUuid(body, 'customerGroupId'),
      agreementId: optionalUuid(body, 'agreementId'),
      minTotal: optionalNumber(body, 'minTotal', 2),
      coupon: optionalText(body, 'coupon', 40),
      validFrom: optionalInstant(body, 'validFrom'),
      validTo: optionalInstant(body, 'validTo'),
      reason: optionalText(body, 'reason', 500),
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.create_discount_rule($1::jsonb) AS id', [JSON.stringify(data)]);
      return { id: rows[0].id };
    });
  }

  @Post('discount-rules/:id/end')
  @HttpCode(200)
  async end(@Param('id') id: string) {
    const ruleId = requireUuid(id);
    await this.database.withContext((client) => client.query('SELECT app.end_discount_rule($1)', [ruleId]));
    return { status: 'ok' };
  }

  /** Simulador: os descontos de uma venda de exemplo, com o cliente, a forma de pagamento e o cupom. */
  @Post('discount-rules/simulate')
  @HttpCode(200)
  simulate(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const branchId = requireUuid(body.branchId);
    const lines = simulatedLines(body.lines);
    const methods = body.paymentMethods ?? [];
    if (!Array.isArray(methods) || methods.length > 10 || methods.some((m) => typeof m !== 'string' || m.length > 20)) {
      throw new AppError('FA005');
    }
    const agreements = body.agreementIds ?? [];
    if (!Array.isArray(agreements) || agreements.length > 10) throw new AppError('FA005');
    const context = {
      payment_methods: methods,
      customer_id: optionalUuid(body, 'customerId'),
      agreement_ids: agreements.map((value) => requireUuid(value)),
      coupon: optionalText(body, 'coupon', 40),
    };
    return this.database.withContext(async (client) => {
      const resolved = [];
      for (const line of lines) {
        const found = await client.query<{ id: string | null }>('SELECT app.find_product_id($1) AS id', [line.product_lookup]);
        const productId = found.rows[0].id;
        if (!productId) throw new AppError('FA006');
        const visible = await client.query<{ display_name: string }>('SELECT display_name FROM v_product WHERE id = $1', [productId]);
        if (visible.rows.length === 0) throw new AppError('FA006');
        resolved.push({ line: line.line, product_id: productId, name: visible.rows[0].display_name, quantity: line.quantity, unit_price: line.unit_price });
      }
      const { rows } = await client.query<{ result: { line: number; total_cents: number; applied: unknown[] }[] }>(
        'SELECT app.simulate_discounts($1, $2::jsonb, $3::jsonb) AS result',
        [branchId, JSON.stringify(resolved), JSON.stringify(context)],
      );
      return resolved.map((line) => ({
        ...line,
        ...rows[0].result.find((r) => r.line === line.line),
      }));
    });
  }

  @Get('customer-groups')
  groups() {
    return this.database.withContext(
      async (client) => (await client.query('SELECT id, name FROM v_customer_group ORDER BY name')).rows,
    );
  }

  @Post('customer-groups')
  createGroup(@RequestBody() rawBody: unknown) {
    const name = requireText(asBody(rawBody), 'name', 60);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.save_customer_group(NULL, $1) AS id', [name]);
      return { id: rows[0].id };
    });
  }

  @Post('customer-groups/:id')
  @HttpCode(200)
  async renameGroup(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const groupId = requireUuid(id);
    const name = requireText(asBody(rawBody), 'name', 60);
    await this.database.withContext((client) => client.query('SELECT app.save_customer_group($1, $2)', [groupId, name]));
    return { status: 'ok' };
  }

  @Post('customer-groups/:id/delete')
  @HttpCode(200)
  async removeGroup(@Param('id') id: string) {
    const groupId = requireUuid(id);
    await this.database.withContext((client) => client.query('SELECT app.remove_customer_group($1)', [groupId]));
    return { status: 'ok' };
  }

  /** Põe o cliente num grupo (ou tira, com vazio). */
  @Post('customers/:id/group')
  @HttpCode(200)
  async setGroup(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const customerId = requireUuid(id);
    const groupId = optionalUuid(asBody(rawBody), 'groupId');
    await this.database.withContext((client) => client.query('SELECT app.set_customer_group($1, $2)', [customerId, groupId]));
    return { status: 'ok' };
  }
}
