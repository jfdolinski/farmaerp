import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  Query,
  Req,
  Res,
  UseGuards,
} from '@nestjs/common';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, rename, rm, stat } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { Request, Response } from 'express';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from '../terminals/terminal.guard.js';
import { ReleaseManifest, verifyRelease } from './release-signature.js';

const MAX_SIZE = 500 * 1024 * 1024;
const VERSION = /^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/;
const FILE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;
const PLATFORMS = new Set(['windows', 'linux']);
const REPORTS = new Set(['downloaded', 'applied', 'rolled_back', 'failed']);

/** Pasta das versões (volume da VPS). Sem ela, o envio e o download ficam desligados. */
function releasesDir(): string | null {
  const dir = process.env.RELEASES_DIR;
  return dir && isAbsolute(dir) ? dir : null;
}

function sameToken(received: string, expected: string): boolean {
  const a = Buffer.from(received);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

function releasePath(dir: string, app: string, platform: string, version: string, fileName: string): string {
  return join(dir, app, platform, version, fileName);
}

/**
 * Envio da versão pelo CI: arquivo no corpo (application/octet-stream) e os dados na query.
 * A assinatura é conferida antes de gravar; o resumo e o tamanho, depois de receber.
 */
@Controller('releases')
export class ReleasesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Post()
  async upload(@Req() request: Request, @Query() query: Record<string, unknown>) {
    const dir = releasesDir();
    const token = process.env.RELEASE_UPLOAD_TOKEN ?? '';
    const [scheme, value] = (request.headers.authorization ?? '').split(' ');
    if (!dir || token.length < 32 || scheme?.toLowerCase() !== 'bearer' || !sameToken(value ?? '', token)) {
      throw new AppError('FA876');
    }
    const text = (field: string) => (typeof query[field] === 'string' ? (query[field] as string) : '');
    const manifest: ReleaseManifest = {
      app: text('app'),
      platform: text('platform'),
      version: text('version'),
      sha256: text('sha256'),
      size: Number(text('size')),
    };
    const fileName = text('fileName');
    const signature = text('signature');
    const notes = text('notes');
    const declared = Number(request.headers['content-length']);
    if (
      manifest.app !== 'pdv' || !PLATFORMS.has(manifest.platform) || !VERSION.test(manifest.version) ||
      !/^[0-9a-f]{64}$/.test(manifest.sha256) || !Number.isSafeInteger(manifest.size) || manifest.size <= 0 ||
      manifest.size > MAX_SIZE || declared !== manifest.size || !FILE_NAME.test(fileName) || fileName.includes('..') ||
      notes.length > 2000 || !verifyRelease(manifest, signature)
    ) {
      throw new AppError('FA869');
    }

    const temporary = join(dir, `.upload-${randomUUID()}`);
    const hash = createHash('sha256');
    let received = 0;
    const counter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        received += chunk.length;
        if (received > manifest.size) {
          callback(new AppError('FA869'));
          return;
        }
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    try {
      await mkdir(dir, { recursive: true });
      await pipeline(request, counter, createWriteStream(temporary, { flags: 'wx' }));
      if (received !== manifest.size || hash.digest('hex') !== manifest.sha256) throw new AppError('FA869');
      const id = await this.database.withContext(
        async (client) => {
          const { rows } = await client.query<{ id: string }>('SELECT app.register_release($1::jsonb) AS id', [
            JSON.stringify({ ...manifest, fileName, signature, notes: notes || null }),
          ]);
          return rows[0].id;
        },
        { worker: 'release' },
      );
      const target = releasePath(dir, manifest.app, manifest.platform, manifest.version, fileName);
      await mkdir(join(dir, manifest.app, manifest.platform, manifest.version), { recursive: true });
      await rename(temporary, target);
      return { id };
    } finally {
      await rm(temporary, { force: true });
    }
  }
}

/** Versões para o administrador da plataforma: liberar para a rede ou retirar. */
@Controller('platform/releases')
@UseGuards(SessionGuard)
export class PlatformReleasesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.list_releases()')).rows);
  }

  @Post(':id/status')
  @HttpCode(200)
  async status(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const releaseId = requireUuid(id);
    const value = asBody(rawBody).status;
    if (value !== 'general' && value !== 'withdrawn') throw new AppError('FA877');
    await this.database.withContext((client) => client.query('SELECT app.set_release_status($1, $2)', [releaseId, value]));
    return { status: 'ok' };
  }
}

/** O PDV pergunta se há versão nova, baixa (com retomada) e informa o que fez. */
@Controller('terminals/updates')
@UseGuards(TerminalGuard)
export class TerminalUpdatesController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  check(@Query('platform') platform?: string, @Query('current') current?: string) {
    if (!platform || !PLATFORMS.has(platform) || !current || current.length > 50) throw new AppError('FA005');
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ release: unknown }>('SELECT app.terminal_update_check($1, $2) AS release', [
        platform,
        current,
      ]);
      return rows[0].release ? { available: true, release: rows[0].release } : { available: false };
    });
  }

  @Get(':id/file')
  async file(@Param('id') id: string, @Res() response: Response) {
    const releaseId = requireUuid(id);
    const dir = releasesDir();
    if (!dir) throw new AppError('FA875');
    const info = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ info: { app: string; platform: string; version: string; fileName: string } }>(
        'SELECT app.terminal_release_file($1) AS info',
        [releaseId],
      );
      return rows[0].info;
    });
    const path = releasePath(dir, info.app, info.platform, info.version, info.fileName);
    try {
      await stat(path);
    } catch {
      throw new AppError('FA875');
    }
    // O Express responde o pedaço pedido (Range), para o PDV retomar o download.
    await new Promise<void>((resolve, reject) => {
      response.sendFile(
        path,
        { acceptRanges: true, cacheControl: false, headers: { 'Content-Type': 'application/octet-stream' } },
        (error) => (error && !response.headersSent ? reject(new AppError('FA875')) : resolve()),
      );
    });
  }

  @Post(':id/report')
  @HttpCode(200)
  async report(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const releaseId = requireUuid(id);
    const body = asBody(rawBody);
    if (typeof body.status !== 'string' || !REPORTS.has(body.status)) throw new AppError('FA005');
    const detail = optionalText(body, 'detail', 500);
    await this.database.withContext((client) =>
      client.query('SELECT app.record_terminal_update($1, $2, $3)', [releaseId, body.status, detail]),
    );
    return { status: 'ok' };
  }
}
