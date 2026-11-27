import { Controller, Get, HttpCode, Inject, Param, Post, Res, UseGuards } from '@nestjs/common';
import { buildDanfe } from '@farmaerp/fiscal-js';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { CentralNfeService } from './central-nfe.service.js';

/** NF-e emitida pela central: devolução ao fornecedor. Regras e permissões no banco. */
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

  @Get('central-nfe/:id/danfe')
  async danfe(@Param('id') id: string, @Res() response: Response) {
    const file = await this.file(id);
    const pdf = await buildDanfe(file.xml);
    response.status(200).type('application/pdf').attachment(`DANFE-${file.access_key}.pdf`).send(pdf);
  }
}
