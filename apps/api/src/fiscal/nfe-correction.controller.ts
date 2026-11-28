import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Post, Res, UseGuards } from '@nestjs/common';
import { buildCorrectionPdf } from '@farmaerp/fiscal-js';
import type { Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { correctionText, CorrectionKind, NfeCorrectionService } from './nfe-correction.service.js';

function kindOf(value: string): CorrectionKind {
  if (value !== 'sale' && value !== 'central') throw new AppError('FA005');
  return value;
}

type CorrectionFile = { access_key: string; sequence: number; xml: string; nfe_xml: string };

/** Carta de correção da NF-e 55 (venda, devolução e transferência): lista, envio, XML e PDF. Regras e permissões no banco. */
@Controller('admin/nfe-corrections')
@UseGuards(SessionGuard)
export class NfeCorrectionController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(NfeCorrectionService) private readonly corrections: NfeCorrectionService,
  ) {}

  /** A nota, se dá para mandar outra carta e as cartas registradas (a última primeiro). */
  @Get(':kind/:id')
  list(@Param('kind') kind: string, @Param('id') id: string) {
    const params = [kindOf(kind), requireUuid(id)];
    return this.database.withContext(async (client) => (await client.query<{ x: unknown }>('SELECT app.nfe_corrections($1, $2) AS x', params)).rows[0].x);
  }

  /** Envia a carta à Sefaz e registra. */
  @Post(':kind/:id')
  @HttpCode(200)
  send(@Param('kind') kind: string, @Param('id') id: string, @RequestBody() rawBody: unknown) {
    const text = correctionText(requireText(asBody(rawBody), 'text', 4000));
    return this.corrections.send(kindOf(kind), requireUuid(id), text);
  }

  private file(id: string): Promise<CorrectionFile> {
    const correctionId = requireUuid(id);
    return this.database.withContext(async (client) =>
      (await client.query<CorrectionFile>('SELECT * FROM app.nfe_correction_file($1)', [correctionId])).rows[0],
    );
  }

  /** XML do evento registrado (procEventoNFe). */
  @Get('file/:id/xml')
  async xml(@Param('id') id: string, @Res() response: Response) {
    const file = await this.file(id);
    response.status(200).type('application/xml; charset=utf-8').attachment(`CCe-${file.access_key}-${file.sequence}.xml`).send(file.xml);
  }

  /** PDF da carta, com os dados da nota. */
  @Get('file/:id/pdf')
  async pdf(@Param('id') id: string, @Res() response: Response) {
    const file = await this.file(id);
    const pdf = await buildCorrectionPdf(file.xml, file.nfe_xml);
    response.status(200).type('application/pdf').attachment(`CCe-${file.access_key}-${file.sequence}.pdf`).send(pdf);
  }
}
