import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Query, Res, UseGuards } from '@nestjs/common';
import { buildDanfe } from '@farmaerp/fiscal-js';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { NfceActionsService } from './nfce-actions.service.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
type DocumentFiles = { access_key: string; status: string; model: string; xml: string; cancellation: { xml: string } | null };

const STATUSES = new Set(['authorized', 'rejected', 'pending', 'contingency', 'canceled']);

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** Justificativa da Sefaz: de 15 a 255 letras. */
function reasonOf(body: Record<string, unknown>): string {
  const reason = requireText(body, 'reason', 255).trim();
  if (reason.length < 15) throw new AppError('FA005');
  return reason;
}

/**
 * Notas fiscais emitidas no caixa (NFC-e e NF-e de venda) na central: consulta, reenvio, cancelamento,
 * inutilização e avisos. A NF-e 55 por enquanto só é listada e baixada (XML e DANFE A4).
 */
@Controller('admin/fiscal-documents')
@UseGuards(SessionGuard)
export class FiscalDocumentsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(NfceActionsService) private readonly actions: NfceActionsService,
  ) {}

  @Get()
  list(
    @Query('branch') branch?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('status') status?: string,
    @Query('alerts') alerts?: string,
  ) {
    if (status && !STATUSES.has(status)) throw new AppError('FA005');
    const params = [branch ? requireUuid(branch) : null, optionalDay(from), optionalDay(to), status || null, alerts === '1'];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_fiscal_documents($1, $2, $3, $4, $5)', params)).rows,
    );
  }

  /** Buracos de numeração (sugestão de inutilização). */
  @Get('gaps')
  gaps(@Query('branch') branch?: string) {
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.fiscal_number_gaps($1)', [branch ? requireUuid(branch) : null])).rows,
    );
  }

  @Get('voids')
  voids(@Query('branch') branch?: string) {
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_fiscal_voids($1)', [branch ? requireUuid(branch) : null])).rows,
    );
  }

  @Post('voids')
  async createVoid(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const branchId = requireUuid(body.branchId);
    const numbers = [body.series, body.first, body.last];
    if (!numbers.every((value) => typeof value === 'number' && Number.isSafeInteger(value) && value > 0)) throw new AppError('FA005');
    const [series, first, last] = numbers as number[];
    return this.actions.void(branchId, series, first, last, reasonOf(body));
  }

  private async files(id: string) {
    const documentId = requireUuid(id);
    const files = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ f: DocumentFiles | null }>('SELECT app.fiscal_document_files($1) AS f', [documentId]);
      return rows[0].f;
    });
    if (!files) throw new AppError('FA006');
    return files;
  }

  /** XML da nota e, se houver, o do cancelamento (kind=cancel). */
  @Get(':id/xml')
  async xml(@Param('id') id: string, @Query('kind') kind: string | undefined, @Res() response: Response) {
    const files = await this.files(id);
    const label = files.model === '55' ? 'NFe' : 'NFCe';
    if (kind === 'cancel') {
      if (!files.cancellation) throw new AppError('FA006');
      response.status(200).type('application/xml; charset=utf-8').attachment(`Cancelamento-${label}-${files.access_key}.xml`).send(files.cancellation.xml);
      return;
    }
    response.status(200).type('application/xml; charset=utf-8').attachment(`${label}-${files.access_key}.xml`).send(files.xml);
  }

  /** DANFE A4 da NF-e de venda autorizada (a NFC-e tem o cupom, impresso no caixa). */
  @Get(':id/danfe')
  async danfe(@Param('id') id: string, @Res() response: Response) {
    const files = await this.files(id);
    if (files.model !== '55' || files.status !== 'authorized') throw new AppError('FA006');
    const pdf = await buildDanfe(files.xml);
    response.status(200).type('application/pdf').attachment(`DANFE-${files.access_key}.pdf`).send(pdf);
  }

  @Post(':id/consult')
  @HttpCode(200)
  consult(@Param('id') id: string) {
    return this.actions.consult(requireUuid(id));
  }

  @Post(':id/resend')
  @HttpCode(200)
  resend(@Param('id') id: string) {
    return this.actions.resend(requireUuid(id));
  }

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.actions.cancel(requireUuid(id), reasonOf(asBody(rawBody)));
  }

  @Post(':id/dismiss')
  @HttpCode(200)
  async dismiss(@Param('id') id: string) {
    const documentId = requireUuid(id);
    await this.database.withContext((client) => client.query('SELECT app.dismiss_fiscal_alert($1)', [documentId]));
    return { ok: true };
  }
}
