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

/** Vendas que chegaram dos PDVs. Quem vê o quê é decidido no banco. */
@Controller('admin/sales')
@UseGuards(SessionGuard)
export class SalesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list(@Query('branch') branch?: string, @Query('from') from?: string, @Query('to') to?: string) {
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to)];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_sales($1, $2, $3)', params)).rows,
    );
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    const saleId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ detail: Record<string, unknown> | null }>('SELECT app.sale_detail($1) AS detail', [saleId]);
      if (rows[0].detail === null) throw new AppError('FA006');
      // NFC-e da venda (sem o XML), quando o caixa já mandou.
      const fiscal = await client.query<{ d: unknown }>('SELECT app.sale_fiscal_document($1) AS d', [saleId]);
      return { ...rows[0].detail, nfce: fiscal.rows[0].d };
    });
  }

  /** XML da NFC-e da venda (autorizado com o protocolo, ou o assinado quando ficou pendente). */
  @Get(':id/nfce.xml')
  async nfceXml(@Param('id') id: string, @Res() response: Response) {
    const saleId = requireUuid(id);
    const file = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ x: { access_key: string; xml: string } | null }>('SELECT app.sale_fiscal_xml($1) AS x', [saleId]);
      if (rows[0].x === null) throw new AppError('FA006');
      return rows[0].x;
    });
    response.status(200).type('application/xml; charset=utf-8').attachment(`NFCe-${file.access_key}.xml`).send(file.xml);
  }
}
