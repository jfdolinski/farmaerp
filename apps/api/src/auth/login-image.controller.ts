import {
  Controller,
  Delete,
  Get,
  Headers,
  HttpCode,
  Inject,
  Put,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { finished } from 'node:stream/promises';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { SessionGuard } from './session.guard.js';

/** Até 3 MB, como o banco confere. A retaguarda já reduz a imagem antes de enviar. */
export const LOGIN_IMAGE_MAX_BYTES = 3 * 1024 * 1024;
const TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

interface CurrentImage {
  sha256: string;
  mime: string;
  content: Buffer | null;
  size: number;
}

/**
 * Descarta o resto do envio antes de recusar: se a resposta sair com o arquivo ainda chegando, o
 * servidor fecha a conexão e quem enviou não vê o motivo. Envio muito acima do limite não espera.
 */
async function refuse(request: Request): Promise<never> {
  const declared = Number(request.headers['content-length']);
  if (
    Number.isSafeInteger(declared) &&
    declared <= 4 * LOGIN_IMAGE_MAX_BYTES &&
    !request.readableEnded
  ) {
    request.resume();
    await finished(request).catch(() => undefined);
  }
  throw new AppError('FA225');
}

/** Lê o corpo binário até o limite; passou do limite, recusa. */
async function readBody(request: Request, limit: number): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request as AsyncIterable<Buffer>) {
    total += chunk.length;
    if (total > limit) return refuse(request);
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/**
 * Imagem da tela de entrada (retaguarda e PDV). Trocar e tirar: só o administrador da plataforma
 * (o banco confere). Ler: sem sessão, porque a tela de entrada aparece antes de alguém entrar.
 */
@Controller()
export class LoginImageController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  private current(withContent: boolean) {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<CurrentImage>(
        'SELECT * FROM app.current_login_image($1)',
        [withContent],
      );
      return rows[0] ?? null;
    });
  }

  /** Só o resumo: a tela de entrada e o PDV sabem se há imagem e se ela mudou. */
  @Get('public/login-image/info')
  async info() {
    const image = await this.current(false);
    return image
      ? { sha256: image.sha256, mime: image.mime, size: image.size }
      : { sha256: null };
  }

  @Get('public/login-image')
  async image(
    @Headers('if-none-match') ifNoneMatch: string | undefined,
    @Res() response: Response,
  ) {
    const image = await this.current(true);
    if (!image?.content) throw new AppError('FA006');
    const etag = `"${image.sha256}"`;
    response.setHeader('ETag', etag);
    // O endereço não muda quando a imagem muda: o navegador confere a cada poucos minutos.
    response.setHeader('Cache-Control', 'public, max-age=300');
    if (ifNoneMatch === etag) {
      response.status(304).end();
      return;
    }
    response.status(200).type(image.mime).send(image.content);
  }

  @Put('platform/login-image')
  @UseGuards(SessionGuard)
  async upload(@Req() request: Request) {
    const mime = String(request.headers['content-type'] ?? '')
      .split(';')[0]
      .trim()
      .toLowerCase();
    const declared = Number(request.headers['content-length']);
    if (
      !TYPES.has(mime) ||
      !Number.isSafeInteger(declared) ||
      declared < 1 ||
      declared > LOGIN_IMAGE_MAX_BYTES
    ) {
      return refuse(request);
    }
    // Permissão antes de ler o arquivo.
    await this.database.withContext((client) =>
      client.query('SELECT app.require_platform_admin()'),
    );
    const content = await readBody(request, LOGIN_IMAGE_MAX_BYTES);
    if (content.length !== declared) throw new AppError('FA225');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ sha256: string }>(
        'SELECT app.set_login_image($1, $2) AS sha256',
        [mime, content],
      );
      return { sha256: rows[0].sha256 };
    });
  }

  @Delete('platform/login-image')
  @UseGuards(SessionGuard)
  @HttpCode(200)
  async clear() {
    await this.database.withContext((client) =>
      client.query('SELECT app.clear_login_image()'),
    );
    return { status: 'ok' };
  }
}
