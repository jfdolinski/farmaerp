import { Body as RequestBody, Controller, Get, Inject, Post, UseGuards } from '@nestjs/common';
import { asBody, Body, optionalText, requireText } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { generateTemporaryPassword, hashPassword } from './password.js';
import { SessionGuard } from './session.guard.js';

const BRANCH_FIELDS = ['name', 'state', 'pmcRegion', 'postalCode', 'street', 'streetNumber', 'complement', 'district', 'city', 'cityCode', 'phone'];

function nested(body: Body, field: string): Body {
  const value = body[field];
  if (value === undefined || value === null) return {};
  return asBody(value);
}

/**
 * Plataforma: empresas como clientes separados. Só o administrador da plataforma (o banco confere).
 * A senha temporária do administrador da empresa nova aparece uma única vez, nesta resposta.
 */
@Controller('platform/tenants')
@UseGuards(SessionGuard)
export class PlatformController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.list_tenants()')).rows);
  }

  @Post()
  async create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const branchBody = nested(body, 'branch');
    const adminBody = nested(body, 'admin');
    const branch: Record<string, string | null> = {};
    for (const field of BRANCH_FIELDS) branch[field] = optionalText(branchBody, field, 150);
    const data = {
      groupName: optionalText(body, 'groupName', 200) ?? '',
      cnpj: requireText(body, 'cnpj', 30),
      legalName: optionalText(body, 'legalName', 200),
      tradeName: optionalText(body, 'tradeName', 200),
      branch,
      admin: { name: optionalText(adminBody, 'name', 200) ?? '', email: optionalText(adminBody, 'email', 254) ?? '' },
    };
    const temporaryPassword = generateTemporaryPassword();
    const hash = await hashPassword(temporaryPassword);
    const created = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: Record<string, string> | null }>(
        'SELECT app.create_tenant($1::jsonb, $2) AS result',
        [JSON.stringify(data), hash],
      );
      return rows[0].result;
    });
    if (!created) throw new AppError('FA000');
    return { ...created, temporaryPassword };
  }
}
