import {
  Body as RequestBody,
  Controller,
  Get,
  Inject,
  Param,
  Post,
  Put,
  Query,
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const TEXT_FIELDS = ['name', 'council', 'registration', 'state', 'specialty'] as const;

/** Só os campos conhecidos, com tamanho limitado. As regras ficam no banco (FA733, FA734). */
function professionalData(rawBody: unknown): Record<string, unknown> {
  const body = asBody(rawBody);
  const data: Record<string, unknown> = {};
  for (const field of TEXT_FIELDS) {
    const value = body[field];
    if (value === undefined || value === null) continue;
    if (typeof value !== 'string' || value.length > 200) throw new AppError('FA734');
    data[field] = value;
  }
  if (body.active !== undefined) {
    if (typeof body.active !== 'boolean') throw new AppError('FA734');
    data.active = body.active;
  }
  return data;
}

/** Profissionais da saúde (prescritores) do grupo. */
@Controller('admin/health-professionals')
@UseGuards(SessionGuard)
export class HealthProfessionalsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list(@Query('busca') search?: string, @Query('inativos') inactive?: string) {
    const term = typeof search === 'string' ? search.slice(0, 150) : null;
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.list_health_professionals($1, $2)', [term, inactive === '1']);
      return rows;
    });
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const data = professionalData(rawBody);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.save_health_professional(NULL, $1::jsonb) AS id', [
        JSON.stringify(data),
      ]);
      return { id: rows[0].id };
    });
  }

  @Put(':id')
  update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const professionalId = requireUuid(id);
    const data = professionalData(rawBody);
    return this.database.withContext(async (client) => {
      await client.query('SELECT app.save_health_professional($1, $2::jsonb)', [professionalId, JSON.stringify(data)]);
      return { id: professionalId };
    });
  }
}
