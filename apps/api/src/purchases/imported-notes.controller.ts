import { Controller, Get, Inject, Param, Query, Res, UseGuards } from '@nestjs/common';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const KINDS = new Set(['purchase', 'customer_return', 'other_entry', 'own_entry', 'supplier_return', 'transfer', 'other_output']);

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** NF-e de estoque trazidas pela importação (compras, transferências, devoluções). O banco decide quem vê. */
@Controller('admin/imported-notes')
@UseGuards(SessionGuard)
export class ImportedNotesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('kind') kind?: string,
  ) {
    if (kind !== undefined && kind !== '' && !KINDS.has(kind)) throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to), kind || null];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_imported_notes($1, $2, $3, $4)', params)).rows,
    );
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    const noteId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ d: unknown }>('SELECT app.imported_note_detail($1) AS d', [noteId]);
      if (rows[0].d === null) throw new AppError('FA006');
      return rows[0].d;
    });
  }

  /** XML da NF-e como veio no arquivo importado. */
  @Get(':id/xml')
  async xml(@Param('id') id: string, @Res() response: Response) {
    const noteId = requireUuid(id);
    const file = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ x: { access_key: string; xml: string } | null }>('SELECT app.imported_note_xml($1) AS x', [noteId]);
      if (rows[0].x === null) throw new AppError('FA006');
      return rows[0].x;
    });
    response.status(200).type('application/xml; charset=utf-8').attachment(`NFe-${file.access_key}.xml`).send(file.xml);
  }
}
