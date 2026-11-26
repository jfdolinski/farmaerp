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
import { SessionGuard } from '../auth/session.guard.js';
import {
  asBody,
  Body,
  optionalText,
  requireUuid,
} from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { lookupCnpj } from './cnpj-lookup.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const MAX_LIMIT = 9_999_999_999.99;

/** Mesmo cálculo de app.is_valid_cnpj, inclusive o alfanumérico: evita consultar fora o que não existe. */
export function isValidCnpj(cnpj: string): boolean {
  if (!/^[0-9A-Z]{12}[0-9]{2}$/.test(cnpj) || /^(.)\1{13}$/.test(cnpj)) {
    return false;
  }
  const digit = (base: string) => {
    const weights = base.length === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const total = base.split("").reduce((sum, char, i) => sum + (char.charCodeAt(0) - 48) * weights[i], 0);
    const rest = total % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(cnpj.slice(0, 12));
  const second = digit(cnpj.slice(0, 12) + String(first));
  return cnpj.endsWith(`${first}${second}`);
}

function creditLimit(value: unknown): number {
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    Math.abs(value) > MAX_LIMIT ||
    Number(value.toFixed(2)) !== value
  ) {
    throw new AppError('FA005');
  }
  return value;
}

function optionalDay(body: Body, field: string): string | null {
  const value = body[field];
  if (value === undefined || value === null || value === '') {
    return null;
  }
  if (
    typeof value !== 'string' ||
    !DAY.test(value) ||
    Number.isNaN(Date.parse(`${value}T00:00:00Z`)) ||
    new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) !== value
  ) {
    throw new AppError('FA005');
  }
  return value;
}

/** Campos vazios seguem como nulos: o banco recusa o que for obrigatório, com a mensagem certa. */
const customerData = (body: Body) => ({
  personType: optionalText(body, 'personType', 20),
  document: optionalText(body, 'document', 30),
  name: optionalText(body, 'name', 150),
  tradeName: optionalText(body, 'tradeName', 150),
  birthDate: optionalDay(body, 'birthDate'),
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
  stateRegistration: optionalText(body, 'stateRegistration', 20),
});

const dependentData = (body: Body) => ({
  name: optionalText(body, 'name', 150),
  relationship: optionalText(body, 'relationship', 20),
  birthDate: optionalDay(body, 'birthDate'),
  cpf: optionalText(body, 'cpf', 20),
});

// Datas como texto, para o dia não mudar conforme o fuso do servidor.
const CUSTOMER_COLUMNS = `id, code, person_type, document, name, trade_name, birth_date::text AS birth_date,
  phone, email, postal_code, street, street_number, complement, district, city, city_code, state::text AS state,
  state_registration, customer_group_id`;

/** Clientes. As regras e as permissões ficam no banco; o log nunca recebe os dados deles. */
@Controller('admin/customers')
@UseGuards(SessionGuard)
export class CustomersController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  /**
   * Preenche o cadastro de pessoa jurídica pelos serviços públicos. Só quem cadastra clientes, fornecedores ou a estrutura usa,
   * e nada da resposta vai para o log.
   */
  @Get('cnpj/:cnpj')
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  async lookup(@Param('cnpj') raw: string) {
    const cnpj = raw.replace(/[^0-9A-Za-z]/g, '').toUpperCase();
    if (!isValidCnpj(cnpj)) {
      throw new AppError('FA902');
    }
    const allowed = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ ok: boolean }>(
        `SELECT app.has_permission_anywhere('customers.manage') OR app.has_permission_anywhere('structure.manage')
                OR app.has_permission_anywhere('purchases.manage') AS ok`,
      );
      return rows[0].ok;
    });
    if (!allowed) {
      throw new AppError('FA002');
    }
    return lookupCnpj(cnpj);
  }

  /** A lista sai com o documento mascarado. */
  @Get()
  search(@Query('q') query?: string) {
    if (query !== undefined && (typeof query !== 'string' || query.length > 200)) {
      throw new AppError('FA005');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.search_customers($1)', [query ?? '']);
      return rows;
    });
  }

  /** Ticket médio, compras dos últimos 30 dias e produtos recorrentes, nas filiais que o usuário vê. */
  @Get(':id/history')
  history(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.customer_purchase_history($1) AS result', [customerId]);
      return rows[0].result;
    });
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT ${CUSTOMER_COLUMNS} FROM v_customer WHERE id = $1`,
        [customerId],
      );
      if (rows.length === 0) {
        throw new AppError('FA006');
      }
      const dependents = await client.query(
        `SELECT id, name, relationship, birth_date::text AS birth_date, cpf
           FROM v_customer_dependent WHERE customer_id = $1 ORDER BY name, id`,
        [customerId],
      );
      const consents = await client.query('SELECT * FROM app.customer_consents($1)', [customerId]);
      const agreements = await client.query(
        `SELECT ca.id, ca.agreement_id, a.name AS agreement_name, ca.registration, ca.credit_limit
           FROM v_customer_agreement ca
           JOIN v_agreement a ON a.id = ca.agreement_id
          WHERE ca.customer_id = $1
          ORDER BY a.name`,
        [customerId],
      );
      const history = await client.query(
        `SELECT e.purpose, e.granted, e.channel, e.created_at, u.name AS author
           FROM v_customer_consent_event e
           LEFT JOIN v_user_account u ON u.id = e.updated_by
          WHERE e.customer_id = $1
          ORDER BY e.created_at DESC, e.id DESC
          LIMIT 50`,
        [customerId],
      );
      return {
        ...rows[0],
        dependents: dependents.rows,
        agreements: agreements.rows,
        consents: consents.rows,
        consent_history: history.rows,
      };
    });
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const data = customerData(asBody(rawBody));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_customer($1::jsonb) AS id',
        [JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Patch(':id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const customerId = requireUuid(id);
    const data = customerData(asBody(rawBody));
    await this.database.withContext((client) =>
      client.query('SELECT app.update_customer($1, $2::jsonb)', [customerId, JSON.stringify(data)]),
    );
    return { status: 'ok' };
  }

  @Post(':id/dependents')
  addDependent(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const customerId = requireUuid(id);
    const data = dependentData(asBody(rawBody));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.add_customer_dependent($1, $2::jsonb) AS id',
        [customerId, JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Patch('dependents/:id')
  async updateDependent(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const dependentId = requireUuid(id);
    const data = dependentData(asBody(rawBody));
    await this.database.withContext((client) =>
      client.query('SELECT app.update_customer_dependent($1, $2::jsonb)', [dependentId, JSON.stringify(data)]),
    );
    return { status: 'ok' };
  }

  @Post('dependents/:id/remove')
  @HttpCode(200)
  async removeDependent(@Param('id') id: string) {
    const dependentId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.remove_customer_dependent($1)', [dependentId]),
    );
    return { status: 'ok' };
  }

  @Post(':id/agreements')
  linkAgreement(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const customerId = requireUuid(id);
    const body = asBody(rawBody);
    const agreementId = requireUuid(body.agreementId);
    const registration = optionalText(body, 'registration', 40);
    const limit = creditLimit(body.creditLimit);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.link_customer_agreement($1, $2, $3, $4) AS id',
        [customerId, agreementId, registration, limit],
      );
      return { id: rows[0].id };
    });
  }

  @Patch('agreements/:id')
  async updateLink(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const linkId = requireUuid(id);
    const body = asBody(rawBody);
    const registration = optionalText(body, 'registration', 40);
    const limit = creditLimit(body.creditLimit);
    await this.database.withContext((client) =>
      client.query('SELECT app.update_customer_agreement($1, $2, $3)', [linkId, registration, limit]),
    );
    return { status: 'ok' };
  }

  @Post('agreements/:id/remove')
  @HttpCode(200)
  async unlink(@Param('id') id: string) {
    const linkId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.unlink_customer_agreement($1)', [linkId]),
    );
    return { status: 'ok' };
  }

  /** Repetir a decisão atual não gera registro, e a resposta diz isso. */
  @Post(':id/consents')
  consent(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const customerId = requireUuid(id);
    const body = asBody(rawBody);
    if (typeof body.granted !== 'boolean') {
      throw new AppError('FA005');
    }
    const granted = body.granted;
    const purpose = optionalText(body, 'purpose', 30);
    const channel = optionalText(body, 'channel', 20);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string | null }>(
        'SELECT app.record_customer_consent($1, $2, $3, $4) AS id',
        [customerId, purpose, granted, channel],
      );
      return { id: rows[0].id, changed: rows[0].id !== null };
    });
  }
}
