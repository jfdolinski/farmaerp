import { Controller, Get, Inject, Param, Query, Res, UseGuards } from '@nestjs/common';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Vendas trazidas do sistema anterior pela importação das notas. Quem vê o quê é decidido no banco. */
@Controller('admin/imported-sales')
@UseGuards(SessionGuard)
export class ImportedSalesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('customer') customer?: string,
  ) {
    const params = [
      branch ? requireUuid(branch) : null,
      optionalDay(from),
      optionalDay(to),
      customer ? requireUuid(customer) : null,
    ];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_imported_sales($1, $2, $3, $4)', params)).rows,
    );
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    const saleId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ d: unknown }>('SELECT app.imported_sale_detail($1) AS d', [saleId]);
      if (rows[0].d === null) throw new AppError('FA006');
      return rows[0].d;
    });
  }

  /** XML da nota como veio no arquivo importado. */
  @Get(':id/xml')
  async xml(@Param('id') id: string, @Res() response: Response) {
    const saleId = requireUuid(id);
    const file = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ x: { access_key: string; model: string; xml: string } | null }>(
        'SELECT app.imported_sale_xml($1) AS x',
        [saleId],
      );
      if (rows[0].x === null) throw new AppError('FA006');
      return rows[0].x;
    });
    const prefix = file.model === '65' ? 'NFCe' : 'NFe';
    response.status(200).type('application/xml; charset=utf-8').attachment(`${prefix}-${file.access_key}.xml`).send(file.xml);
  }
}
