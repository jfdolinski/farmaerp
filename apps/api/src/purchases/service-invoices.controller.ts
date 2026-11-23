import { Controller, Get, Inject, Param, Query, Res, UseGuards } from '@nestjs/common';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const STATUSES = new Set(['active', 'cancelled', 'replaced']);
const DAY = /^\d{4}-\d{2}-\d{2}$/;

function optionalDay(value: string | undefined): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Notas de serviço recebidas, baixadas do Ambiente de Dados Nacional. Só leitura. */
@Controller('admin')
@UseGuards(SessionGuard)
export class ServiceInvoicesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get('service-invoices')
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('status') status?: string,
  ) {
    const branchId = branch ? requireUuid(branch) : null;
    if (status !== undefined && status !== '' && !STATUSES.has(status)) throw new AppError('FA005');
    const params = [branchId, optionalDay(from), optionalDay(to), status || null];
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.list_service_invoices($1, $2, $3, $4)', params);
      return rows;
    });
  }

  @Get('service-invoices/:id')
  detail(@Param('id') id: string) {
    const invoiceId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT s.id, s.branch_id, b.name AS branch_name, s.access_key, s.number, s.environment, s.issued_at,
                s.competence::text AS competence, s.processed_at, s.provider_document, s.provider_name, s.provider_location,
                s.taker_document, s.service_code, s.municipal_code, s.nbs_code, s.description, s.incidence_location,
                s.service_value, s.unconditional_discount, s.deductions, s.iss_base, s.iss_rate, s.iss_value,
                s.iss_withholding, s.irrf_withheld, s.csll_withheld, s.social_security_withheld, s.pis_value,
                s.cofins_value, s.pis_cofins_withholding, s.total_withheld, s.net_value, s.status, s.status_changed_at,
                s.replaced_by, substitute.number AS replaced_by_number, replaced.id AS replaces_id,
                replaced.number AS replaces_number
           FROM v_service_invoice s
           JOIN v_branch b ON b.id = s.branch_id
           LEFT JOIN v_service_invoice substitute ON substitute.id = s.replaced_by
           LEFT JOIN v_service_invoice replaced ON replaced.access_key = s.replaces_key
                AND replaced.economic_group_id = s.economic_group_id
          WHERE s.id = $1 AND s.role = 'received'`,
        [invoiceId],
      );
      if (rows.length === 0) throw new AppError('FA006');
      return rows[0];
    });
  }

  /** O XML como veio do ADN, para guardar ou mandar ao contador. */
  @Get('service-invoices/:id/xml')
  async xml(@Param('id') id: string, @Res({ passthrough: true }) res: Response) {
    const invoiceId = requireUuid(id);
    const row = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ xml: string; access_key: string }>(
        `SELECT d.xml, s.access_key FROM v_service_invoice s JOIN v_dfe_document d ON d.id = s.document_id
          WHERE s.id = $1 AND s.role = 'received'`,
        [invoiceId],
      );
      return rows[0];
    });
    if (!row) throw new AppError('FA006');
    res.setHeader('Content-Type', 'application/xml; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="NFSe-${row.access_key}.xml"`);
    return row.xml;
  }
}
