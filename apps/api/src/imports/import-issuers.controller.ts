import { Body as RequestBody, Controller, Get, Inject, Param, Post, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

/**
 * Plataforma: CNPJs das notas importadas que o cliente ainda não tem como filial. O administrador
 * da plataforma cria a empresa e a filial (ou só a filial) no cliente que importou, ou recusa. O
 * banco confere quem é o administrador da plataforma.
 */
@Controller('platform/import-issuers')
@UseGuards(SessionGuard)
export class ImportIssuersController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.platform_pending_issuers()')).rows);
  }

  @Post(':id/decision')
  async decide(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const issuerId = requireUuid(id);
    const body = asBody(rawBody);
    const decision = body.decision;
    if (decision !== 'create' && decision !== 'refuse') throw new AppError('FA005');
    // Regime tributário (CRT): 1 a 4, como número ou texto; ausente fica o da nota.
    const raw = body.taxRegime;
    const taxRegime = typeof raw === 'number' || typeof raw === 'string' ? String(raw) : null;
    if ((raw !== undefined && raw !== null && taxRegime === null) || (taxRegime !== null && !['1', '2', '3', '4'].includes(taxRegime))) {
      throw new AppError('FA005');
    }
    const data = {
      legalName: optionalText(body, 'legalName', 150),
      tradeName: optionalText(body, 'tradeName', 150),
      taxRegime,
    };
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ r: Record<string, unknown> }>(
        'SELECT app.platform_resolve_issuer($1, $2, $3::jsonb) AS r',
        [issuerId, decision, JSON.stringify(data)],
      );
      return rows[0].r;
    });
  }
}
