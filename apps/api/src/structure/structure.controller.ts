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
import { asBody, Body, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const BRANCH_FIELDS: Record<string, number> = {
  name: 300,
  cnpj: 30,
  state: 2,
  pmcRegion: 30,
  postalCode: 20,
  street: 300,
  streetNumber: 100,
  complement: 300,
  district: 300,
  city: 300,
  cityCode: 20,
  phone: 30,
};

function branchData(body: Body): Record<string, string | null> {
  return Object.fromEntries(
    Object.entries(BRANCH_FIELDS).map(([field, length]) => [field, optionalText(body, field, length)]),
  );
}

/** Empresas e filiais. Quem altera é decidido no banco, pela permissão structure.manage. */
@Controller('admin/structure')
@UseGuards(SessionGuard)
export class StructureController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  overview() {
    return this.database.withContext(async (client) => {
      const { rows: [access] } = await client.query<{ can_view: boolean; can_manage: boolean }>(
        `SELECT app.has_permission_anywhere('structure.manage') OR app.has_permission_anywhere('branches.view_all') AS can_view,
                app.permission_group('structure.manage') IS NOT NULL AS can_manage`,
      );
      if (!access.can_view) {
        throw new AppError('FA002');
      }
      const { rows: companies } = await client.query(
        `SELECT id, legal_name, trade_name, cnpj_root, tax_regime FROM v_company ORDER BY trade_name`,
      );
      const { rows: branches } = await client.query(
        `SELECT id, company_id, name, cnpj, state, pmc_region, postal_code, street, street_number,
                complement, district, city, city_code, phone
           FROM v_branch
          ORDER BY name`,
      );
      return { canManage: access.can_manage, companies, branches };
    });
  }

  @Post('companies')
  createCompany(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const branch = body.branch === undefined || body.branch === null ? null : branchData(asBody(body.branch));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: { id: string; branchId: string | null } }>(
        'SELECT app.create_company($1, $2, $3, $4::jsonb) AS result',
        [
          optionalText(body, 'cnpj', 30),
          optionalText(body, 'legalName', 300),
          optionalText(body, 'tradeName', 300),
          branch && JSON.stringify(branch),
        ],
      );
      return rows[0].result;
    });
  }

  @Patch('companies/:id')
  async updateCompany(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const companyId = requireUuid(id);
    const body = asBody(rawBody);
    await this.database.withContext((client) =>
      client.query('SELECT app.update_company($1, $2, $3)', [
        companyId,
        optionalText(body, 'legalName', 300),
        optionalText(body, 'tradeName', 300),
      ]),
    );
    return { status: 'ok' };
  }

  @Post('companies/:id/delete')
  @HttpCode(200)
  async deleteCompany(@Param('id') id: string) {
    const companyId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.delete_company($1)', [companyId]),
    );
    return { status: 'ok' };
  }

  @Post('companies/:id/branches')
  createBranch(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const companyId = requireUuid(id);
    const data = branchData(asBody(rawBody));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_branch($1, $2::jsonb) AS id',
        [companyId, JSON.stringify(data)],
      );
      return { id: rows[0].id };
    });
  }

  @Patch('branches/:id')
  updateBranch(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const data = branchData(asBody(rawBody));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: { certificateEnded: boolean } }>(
        'SELECT app.update_branch($1, $2::jsonb) AS result',
        [branchId, JSON.stringify(data)],
      );
      return rows[0].result;
    });
  }

  @Post('branches/:id/move')
  @HttpCode(200)
  moveBranch(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const companyId = requireUuid(asBody(rawBody).companyId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: { moved: boolean; certificateEnded: boolean } }>(
        'SELECT app.move_branch($1, $2) AS result',
        [branchId, companyId],
      );
      return rows[0].result;
    });
  }

  @Post('branches/:id/delete')
  @HttpCode(200)
  async deleteBranch(@Param('id') id: string) {
    const branchId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.delete_branch($1)', [branchId]),
    );
    return { status: 'ok' };
  }
}
