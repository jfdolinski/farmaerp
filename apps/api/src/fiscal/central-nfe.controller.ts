import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Patch, Post, Res, UseGuards } from '@nestjs/common';
import { buildDanfe } from '@farmaerp/fiscal-js';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { CentralNfeService } from './central-nfe.service.js';

/** NF-e emitida pela central: devolução ao fornecedor e transferência entre filiais. Regras e permissões no banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class CentralNfeController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(CentralNfeService) private readonly nfe: CentralNfeService,
  ) {}

  /** Emite a NF-e da devolução ao fornecedor (ou transmite de novo a que ficou pendente). */
  @Post('purchase-returns/:id/nfe')
  @HttpCode(200)
  emit(@Param('id') id: string) {
    return this.nfe.emitReturn(requireUuid(id));
  }

  /** Emite a NF-e da transferência entre filiais (ou transmite de novo a que ficou pendente). */
  @Post('stock-transfers/:id/nfe')
  @HttpCode(200)
  emitTransfer(@Param('id') id: string) {
    return this.nfe.emitTransfer(requireUuid(id));
  }

  private async file(id: string) {
    const documentId = requireUuid(id);
    const file = await this.database.withContext(async (client) =>
      (await client.query<{ access_key: string; status: string; xml: string }>('SELECT * FROM app.central_nfe_xml($1)', [documentId])).rows[0],
    );
    if (!file) throw new AppError('FA006');
    return file;
  }

  @Get('central-nfe/:id/xml')
  async xml(@Param('id') id: string, @Res() response: Response) {
    const file = await this.file(id);
    response.status(200).type('application/xml; charset=utf-8').attachment(`NFe-${file.access_key}.xml`).send(file.xml);
  }

  /** Padrões fiscais da NF-e de devolução de cada filial que a pessoa vê no fiscal. */
  @Get('fiscal/return-tax')
  returnTax() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.return_tax_settings()')).rows);
  }

  /** Altera os padrões da filial (só os campos enviados); o banco confere permissão e valores. */
  @Patch('fiscal/return-tax/:branchId')
  setReturnTax(@Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const branch = requireUuid(branchId);
    const body = asBody(rawBody);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ v: unknown }>('SELECT app.set_return_tax_setting($1, $2::jsonb) AS v', [branch, JSON.stringify(body)]);
      return rows[0].v;
    });
  }

  /** Volta a filial aos padrões de fábrica. */
  @Post('fiscal/return-tax/:branchId/reset')
  @HttpCode(200)
  resetReturnTax(@Param('branchId') branchId: string) {
    const branch = requireUuid(branchId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ v: unknown }>('SELECT app.reset_return_tax_setting($1) AS v', [branch]);
      return rows[0].v;
    });
  }

  @Get('central-nfe/:id/danfe')
  async danfe(@Param('id') id: string, @Res() response: Response) {
    const file = await this.file(id);
    const pdf = await buildDanfe(file.xml);
    response.status(200).type('application/pdf').attachment(`DANFE-${file.access_key}.pdf`).send(pdf);
  }
}
