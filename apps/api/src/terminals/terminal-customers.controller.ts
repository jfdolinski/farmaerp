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
import { asBody, requireUuid } from '../common/parse.js';
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
   * de vender na filial). O CPF vai no corpo, nunca na URL.
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
      document: text('document', 20),
      phone: text('phone', 20),
      birthDate: text('birthDate', 10),
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

  @Get(':id')
  customer(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_get_customer($1) AS result', [customerId]);
      return rows[0].result;
    });
  }
}
