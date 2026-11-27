import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { asBody, requireUuid } from '../common/parse.js';
import { isValidCnpj } from '../customers/customers.controller.js';
import { lookupCnpj } from '../customers/cnpj-lookup.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

/**
 * Clientes para o PDV, com internet: a busca devolve a lista com o documento mascarado, e só o
 * cliente escolhido desce inteiro (e passa a ser acompanhado pela descida deste terminal).
 */
@Controller('terminals/customers')
@UseGuards(TerminalGuard)
export class TerminalCustomersController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  // POST para a busca não ir na URL: ela pode ter CPF, que não deve parar em log de acesso.
  @Post('search')
  @HttpCode(200)
  search(@RequestBody() rawBody: unknown) {
    const query = asBody(rawBody).query;
    if (typeof query !== 'string' || query.length > 200) throw new AppError('FA005');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_search_customers($1) AS result', [query]);
      return rows[0].result;
    });
  }

  /**
   * Cadastro na tela de vendas (só com internet). O operador do caixa é conferido no banco (permissão
   * de cadastrar cliente na filial). O CPF ou CNPJ vai no corpo, nunca na URL. Pessoa jurídica leva
   * a inscrição estadual e o endereço completo (o banco confere), para a NF-e.
   */
  @Post()
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const operatorId = requireUuid(body.operatorId);
    const text = (field: string, max: number) => {
      const value = body[field];
      if (value === undefined || value === null || value === '') return null;
      if (typeof value !== 'string' || value.length > max) throw new AppError('FA904');
      return value;
    };
    const consents = body.consents;
    if (consents !== undefined && (consents === null || typeof consents !== 'object' || Array.isArray(consents))) {
      throw new AppError('FA905');
    }
    const flags = (consents ?? {}) as Record<string, unknown>;
    for (const value of [flags.cashback, flags.marketing]) {
      if (value !== undefined && typeof value !== 'boolean') throw new AppError('FA905');
    }
    const data = {
      name: text('name', 150),
      personType: text('personType', 20),
      document: text('document', 20),
      tradeName: text('tradeName', 150),
      phone: text('phone', 20),
      email: text('email', 200),
      birthDate: text('birthDate', 10),
      postalCode: text('postalCode', 10),
      street: text('street', 150),
      streetNumber: text('streetNumber', 20),
      complement: text('complement', 100),
      district: text('district', 100),
      city: text('city', 100),
      cityCode: text('cityCode', 7),
      state: text('state', 2),
      stateRegistration: text('stateRegistration', 20),
      ieIndicator: text('ieIndicator', 1),
      consents: { cashback: flags.cashback === true, marketing: flags.marketing === true },
    };
    if (data.birthDate !== null && !/^\d{4}-\d{2}-\d{2}$/.test(data.birthDate)) throw new AppError('FA904');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_create_customer($1, $2::jsonb) AS result', [
        operatorId,
        JSON.stringify(data),
      ]);
      return rows[0].result;
    });
  }

  /**
   * Preenche o cadastro de pessoa jurídica no caixa pelos serviços públicos. Só o operador que pode
   * cadastrar cliente na filial usa; o CNPJ vai no corpo e nada da resposta vai para o log.
   */
  @Post('cnpj')
  @HttpCode(200)
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  async lookup(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const operatorId = requireUuid(body.operatorId);
    if (typeof body.cnpj !== 'string' || body.cnpj.length > 20) throw new AppError('FA902');
    const cnpj = body.cnpj.replace(/[^0-9A-Za-z]/g, '').toUpperCase();
    if (!isValidCnpj(cnpj)) throw new AppError('FA902');
    const allowed = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ ok: boolean }>('SELECT app.pdv_can_create_customer($1) AS ok', [operatorId]);
      return rows[0].ok;
    });
    if (!allowed) throw new AppError('FA002');
    return lookupCnpj(cnpj);
  }

  /** Histórico de compras do cliente na rede (com internet). */
  @Get(':id/history')
  history(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_customer_history($1) AS result', [customerId]);
      return rows[0].result;
    });
  }

  @Get(':id')
  customer(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_get_customer($1) AS result', [customerId]);
      return rows[0].result;
    });
  }
}
