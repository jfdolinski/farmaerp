import { promisify } from 'node:util';
import { gzip } from 'node:zlib';
import {
  Body as RequestBody,
  Controller,
  Headers,
  HttpCode,
  Inject,
  Post,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Response } from 'express';
import { asBody } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from './terminal.guard.js';

const gzipAsync = promisify(gzip);

/** Itens por pacote: produto com tributação e códigos fica perto de 1 KB. */
export const PULL_PAGE_SIZE = 1000;

/** Campo de texto curto e opcional da descida; o banco confere o formato. */
function syncToken(body: Record<string, unknown>, field: string): string | null {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string' || value.length > 64) throw new AppError('FA956');
  return value;
}

/** Sincronização do terminal: o PDV pede, o banco decide o que desce. */
@Controller('terminals/sync')
@UseGuards(TerminalGuard)
export class TerminalSyncController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  /**
   * Descida. Sem cursor, faz a carga inteira. A resposta traz `until` e, se houver mais pacotes
   * da mesma janela, `next`; o PDV repete com `until` e `after = next` até `next` vir vazio.
   */
  @Post('pull')
  @HttpCode(200)
  async pull(
    @RequestBody() rawBody: unknown,
    @Headers('accept-encoding') acceptEncoding: string | undefined,
    @Res() res: Response,
  ): Promise<void> {
    const body = asBody(rawBody);
    const result = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>(
        'SELECT app.pdv_pull($1, $2, $3, $4) AS result',
        [syncToken(body, 'cursor'), syncToken(body, 'until'), syncToken(body, 'after'), PULL_PAGE_SIZE],
      );
      return rows[0].result;
    });
    const json = Buffer.from(JSON.stringify(result));
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Vary', 'Accept-Encoding');
    if (/\bgzip\b/i.test(acceptEncoding ?? '')) {
      const compressed = await gzipAsync(json);
      res.setHeader('Content-Encoding', 'gzip');
      res.setHeader('Content-Length', String(compressed.length));
      res.status(200).end(compressed);
      return;
    }
    res.setHeader('Content-Length', String(json.length));
    res.status(200).end(json);
  }
}
