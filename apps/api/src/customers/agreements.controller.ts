import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';

/** Convênios. Quem cria e vincula é decidido no banco, pela permissão agreements.manage. */
@Controller('admin/agreements')
@UseGuards(SessionGuard)
export class AgreementsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT a.id, a.name, a.cnpj,
                (SELECT count(*)::int FROM v_customer_agreement ca WHERE ca.agreement_id = a.id) AS customers
           FROM v_agreement a
          ORDER BY a.name`,
      );
      return rows;
    });
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const name = optionalText(body, 'name', 150);
    const cnpj = optionalText(body, 'cnpj', 20);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_agreement($1, $2) AS id',
        [name, cnpj],
      );
      return { id: rows[0].id };
    });
  }

  @Patch(':id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const agreementId = requireUuid(id);
    const body = asBody(rawBody);
    const name = optionalText(body, 'name', 150);
    const cnpj = optionalText(body, 'cnpj', 20);
    await this.database.withContext((client) =>
      client.query('SELECT app.update_agreement($1, $2, $3)', [agreementId, name, cnpj]),
    );
    return { status: 'ok' };
  }

  @Post(':id/delete')
  @HttpCode(200)
  async remove(@Param('id') id: string) {
    const agreementId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.delete_agreement($1)', [agreementId]),
    );
    return { status: 'ok' };
  }
}
