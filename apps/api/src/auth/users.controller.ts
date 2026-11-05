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
  Req,
  UseGuards,
} from '@nestjs/common';
import { asBody, optionalText, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { generateTemporaryPassword, hashPassword } from './password.js';
import { type AuthenticatedRequest, SessionGuard } from './session.guard.js';

/** Gestão de usuários. Quem pode fazer o quê é decidido pelo banco. */
@Controller('admin/users')
@UseGuards(SessionGuard)
export class UsersController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT u.id, u.code, u.name, u.email, u.is_active,
                u.id = ANY (app.user_ids_with_access()) AS has_access,
                COALESCE(
                  (SELECT array_agg(ub.branch_id)
                     FROM v_user_branch ub WHERE ub.user_id = u.id),
                  '{}'
                ) AS branch_ids,
                COALESCE(
                  (SELECT json_agg(json_build_object(
                            'id', ur.id, 'role_id', r.id, 'name', r.name, 'branch_id', ur.branch_id
                          ) ORDER BY r.name)
                     FROM v_user_role ur
                     JOIN v_role r ON r.id = ur.role_id
                    WHERE ur.user_id = u.id),
                  '[]'
                ) AS roles
           FROM v_user_account u
          ORDER BY u.is_active DESC, u.name`,
      );
      return rows;
    });
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const name = requireText(body, 'name', 200);
    const email = optionalText(body, 'email', 254);

    return this.database.withContext(async (client) => {
      const { rows: current } = await client.query<{ group_id: string | null }>(
        'SELECT app.current_user_group() AS group_id',
      );
      if (!current[0].group_id) {
        throw new AppError('FA002');
      }
      const { rows } = await client.query<{ id: string; code: string }>(
        `INSERT INTO user_account (economic_group_id, name, email)
         VALUES ($1, $2, $3) RETURNING id, code`,
        [current[0].group_id, name, email],
      );
      return { id: rows[0].id, code: Number(rows[0].code) };
    });
  }

  @Patch(':id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const userId = requireUuid(id);
    const name = requireText(body, 'name', 200);
    const email = optionalText(body, 'email', 254);
    const isActive = body.isActive !== false;

    await this.database.withContext(async (client) => {
      const { rowCount } = await client.query(
        `UPDATE user_account
            SET name = $2, email = $3, is_active = $4
          WHERE id = $1 AND deleted_at IS NULL`,
        [userId, name, email, isActive],
      );
      if (rowCount === 0) {
        throw new AppError('FA002');
      }
    });
    return { status: 'ok' };
  }

  @Put(':id/branches')
  async setBranches(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const userId = requireUuid(id);
    const { branchIds } = asBody(rawBody);
    if (!Array.isArray(branchIds)) {
      throw new AppError('FA005');
    }
    const wanted = [...new Set(branchIds.map(requireUuid))];

    await this.database.withContext(async (client) => {
      const { rows: allowed } = await client.query<{ ok: boolean }>(
        'SELECT app.can_manage_user($1) AS ok',
        [userId],
      );
      if (!allowed[0].ok) {
        throw new AppError('FA002');
      }
      await client.query(
        `UPDATE user_branch SET deleted_at = now()
          WHERE user_id = $1 AND deleted_at IS NULL AND NOT (branch_id = ANY ($2::uuid[]))`,
        [userId, wanted],
      );
      await client.query(
        `INSERT INTO user_branch (user_id, branch_id)
         SELECT $1, wanted.branch_id
           FROM unnest($2::uuid[]) AS wanted(branch_id)
          WHERE NOT EXISTS (
            SELECT 1 FROM user_branch ub
             WHERE ub.user_id = $1 AND ub.branch_id = wanted.branch_id AND ub.deleted_at IS NULL
          )`,
        [userId, wanted],
      );
    });
    return { status: 'ok' };
  }

  /** A senha aparece uma única vez, só nesta resposta. */
  @Post(':id/temporary-password')
  @HttpCode(200)
  async temporaryPassword(
    @Param('id') id: string,
    @Req() request: AuthenticatedRequest,
  ) {
    const userId = requireUuid(id);
    const temporaryPassword = generateTemporaryPassword();
    const hash = await hashPassword(temporaryPassword);
    await this.database.withContext((client) =>
      client.query('SELECT app.set_temporary_password($1, $2, $3)', [
        userId,
        hash,
        request.ip ?? '',
      ]),
    );
    return { temporaryPassword };
  }
}
