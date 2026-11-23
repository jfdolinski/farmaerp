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

  @Get(':id')
  customer(@Param('id') id: string) {
    const customerId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>('SELECT app.pdv_get_customer($1) AS result', [customerId]);
      return rows[0].result;
    });
  }
}
