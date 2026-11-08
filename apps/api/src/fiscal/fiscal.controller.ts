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
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { readCertificate } from './certificate.js';
import { seal } from './secret-box.js';

// Um A1 tem poucos KB; o limite evita gastar a API abrindo arquivos que não são certificado.
const MAX_PFX_BASE64 = 64_000;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const CSC_TOKEN = /^[0-9A-Za-z-]{1,36}$/;
const MAX_COPY_TARGETS = 500;

/** Configuração fiscal. Quem altera o quê é decidido no banco, filial por filial. */
@Controller('admin/fiscal')
@UseGuards(SessionGuard)
export class FiscalController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  overview() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query('SELECT * FROM app.fiscal_overview()');
      return rows;
    });
  }

  @Patch('companies/:id/regime')
  async setRegime(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const companyId = requireUuid(id);
    const { regime } = asBody(rawBody);
    if (typeof regime !== 'number' || !Number.isInteger(regime) || Math.abs(regime) > 32767) {
      throw new AppError('FA917');
    }
    await this.database.withContext((client) =>
      client.query('SELECT app.set_company_tax_regime($1, $2::smallint)', [companyId, regime]),
    );
    return { status: 'ok' };
  }

  @Patch('branches/:id/state-registration')
  async setStateRegistration(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const registration = optionalText(asBody(rawBody), 'stateRegistration', 30);
    await this.database.withContext((client) =>
      client.query('SELECT app.set_branch_state_registration($1, $2)', [branchId, registration]),
    );
    return { status: 'ok' };
  }

  /** O arquivo e a senha só existem abertos aqui, durante esta chamada. */
  @Post('branches/:id/certificate')
  setCertificate(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const { file, password } = asBody(rawBody);
    if (
      typeof file !== 'string' ||
      typeof password !== 'string' ||
      file.length > MAX_PFX_BASE64 ||
      !BASE64.test(file)
    ) {
      throw new AppError('FA912');
    }
    return this.database.withContext(async (client) => {
      // Permissão antes de tudo: quem não pode atualizar não chega a abrir arquivo nenhum.
      const { rows: [branch] } = await client.query<{ company_id: string }>(
        `SELECT (app.require_branch_permission('fiscal.certificate', $1)).company_id AS company_id`,
        [branchId],
      );
      const pfx = Buffer.from(file, 'base64');
      const info = readCertificate(pfx, password);
      const context = `certificate:${branch.company_id}`;
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.set_branch_certificate($1, $2::jsonb, $3, $4) AS id',
        [branchId, JSON.stringify(info), seal(pfx, context), seal(Buffer.from(password, 'utf8'), context)],
      );
      return {
        id: rows[0].id,
        subjectName: info.subjectName,
        cnpj: info.cnpj,
        validTo: info.validTo,
      };
    });
  }

  @Post('branches/:id/certificate/copy')
  @HttpCode(200)
  copyCertificate(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const { targets } = asBody(rawBody);
    if (!Array.isArray(targets) || targets.length === 0 || targets.length > MAX_COPY_TARGETS) {
      throw new AppError('FA005');
    }
    const targetIds = targets.map((target) => requireUuid(target));
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ copied: number }>(
        'SELECT app.copy_branch_certificate($1, $2) AS copied',
        [branchId, targetIds],
      );
      return { copied: rows[0].copied };
    });
  }

  @Put('branches/:id/csc')
  setCsc(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(id);
    const { cscId, token } = asBody(rawBody);
    if (typeof cscId !== 'string' || typeof token !== 'string' || !CSC_TOKEN.test(token.trim())) {
      throw new AppError('FA916');
    }
    return this.database.withContext(async (client) => {
      await client.query(`SELECT app.require_branch_permission('fiscal.certificate', $1)`, [branchId]);
      const sealed = seal(Buffer.from(token.trim(), 'utf8'), `csc:${branchId}`);
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.set_branch_csc($1, $2, $3) AS id',
        [branchId, cscId, sealed],
      );
      return { id: rows[0].id };
    });
  }
}
