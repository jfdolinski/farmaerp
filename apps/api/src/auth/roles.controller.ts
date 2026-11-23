import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Patch,
  Post,
  Put,
  Query,
  UseGuards,
} from '@nestjs/common';
import { asBody, optionalText, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { SessionGuard } from './session.guard.js';

function permissionCodes(value: unknown): string[] {
  if (!Array.isArray(value) || value.some((code) => typeof code !== 'string')) {
    throw new AppError('FA005');
  }
  return value as string[];
}

/** Perfis e catálogo de permissões. As regras, inclusive de escalada, ficam no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class RolesController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('permissions')
  permissions() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT code, module, name FROM v_permission ORDER BY module, name',
      );
      return rows;
    });
  }

  /** Limites de valor de cada perfil (o Administrador não tem). */
  @Get('role-limits')
  roleLimits() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.role_limits()')).rows);
  }

  /** Troca os limites do perfil: { limits: { codigo: valor | null } }. Vazio tira o limite. */
  @Put('roles/:id/limits')
  @HttpCode(200)
  async setRoleLimits(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const roleId = requireUuid(id);
    const limits = asBody(rawBody).limits;
    if (!limits || typeof limits !== 'object' || Array.isArray(limits)) throw new AppError('FA005');
    for (const [code, value] of Object.entries(limits as Record<string, unknown>)) {
      const valid = value === null || value === '' || (typeof value === 'number' && Number.isFinite(value)) ||
        (typeof value === 'string' && /^\d{1,12}(\.\d{1,2})?$/.test(value));
      if (!/^[a-z_]{1,40}$/.test(code) || !valid) throw new AppError('FA005');
    }
    await this.database.withContext((client) =>
      client.query('SELECT app.set_role_limits($1, $2::jsonb)', [roleId, JSON.stringify(limits)]),
    );
    return { status: 'ok' };
  }

  /** Liberações de supervisor (e as de custo da nota de compra), para auditoria. */
  @Get('supervisor-releases')
  releases(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('action') action?: string,
  ) {
    const day = (value?: string) => {
      if (value === undefined || value === '') return null;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
      return value;
    };
    if (action !== undefined && action !== '' && !/^[a-z_]+\.[a-z_]+$/.test(action)) throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, day(from), day(to), action || null];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_supervisor_releases($1, $2, $3, $4)', params)).rows,
    );
  }

  @Get('roles')
  roles() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT r.id, r.name, r.description, r.system_key,
                COALESCE(
                  (SELECT array_agg(p.code ORDER BY p.code)
                     FROM v_role_permission rp
                     JOIN v_permission p ON p.id = rp.permission_id
                    WHERE rp.role_id = r.id),
                  '{}'
                ) AS permissions
           FROM v_role r
          ORDER BY r.system_key NULLS LAST, r.name`,
      );
      return rows;
    });
  }

  @Post('roles')
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const name = requireText(body, 'name', 100);
    const description = optionalText(body, 'description', 500);
    const codes = permissionCodes(body.permissions);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.create_role($1, $2, $3) AS id',
        [name, description, codes],
      );
      return { id: rows[0].id };
    });
  }

  @Patch('roles/:id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const roleId = requireUuid(id);
    const name = requireText(body, 'name', 100);
    const description = optionalText(body, 'description', 500);
    const codes = permissionCodes(body.permissions);
    await this.database.withContext((client) =>
      client.query('SELECT app.update_role($1, $2, $3, $4)', [
        roleId,
        name,
        description,
        codes,
      ]),
    );
    return { status: 'ok' };
  }

  @Post('roles/:id/delete')
  @HttpCode(200)
  async remove(@Param('id') id: string) {
    const roleId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.delete_role($1)', [roleId]),
    );
    return { status: 'ok' };
  }

  @Post('users/:id/roles')
  assign(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const userId = requireUuid(id);
    const roleId = requireUuid(body.roleId);
    const branchId =
      body.branchId === undefined || body.branchId === null
        ? null
        : requireUuid(body.branchId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.assign_role($1, $2, $3) AS id',
        [userId, roleId, branchId],
      );
      return { id: rows[0].id };
    });
  }

  @Post('user-roles/:id/remove')
  @HttpCode(200)
  async unassign(@Param('id') id: string) {
    const userRoleId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.unassign_role($1)', [userRoleId]),
    );
    return { status: 'ok' };
  }
}
