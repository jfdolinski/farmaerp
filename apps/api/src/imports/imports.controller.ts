import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  Put,
  Req,
  UseGuards,
} from '@nestjs/common';
import type { Request } from 'express';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { importFilePath, importsDir } from './imports.service.js';

/** Cada parte tem até 20 MB (a última pode ser menor). */
export const PART_BYTES = 20 * 1024 * 1024;

function requireDir(): string {
  const dir = importsDir();
  // Sem a pasta configurada, a importação fica indisponível.
  if (!dir) throw new AppError('FA740');
  return dir;
}

/** Importação das notas do sistema anterior: o arquivo chega em partes e é processado depois. */
@Controller('admin/imports')
@UseGuards(SessionGuard)
export class ImportsController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  list() {
    return this.database.withContext(async (client) => (await client.query('SELECT * FROM app.list_document_imports()')).rows);
  }

  @Get(':id')
  report(@Param('id') id: string) {
    const importId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ r: unknown }>('SELECT app.document_import_report($1) AS r', [importId]);
      return rows[0].r;
    });
  }

  @Post()
  async create(@RequestBody() rawBody: unknown) {
    requireDir();
    const { fileName, size } = asBody(rawBody);
    if (typeof fileName !== 'string' || fileName.length > 200 || typeof size !== 'number' || !Number.isSafeInteger(size)) {
      throw new AppError('FA740');
    }
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.create_document_import($1, $2) AS id', [fileName, size]);
      return { id: rows[0].id, partBytes: PART_BYTES };
    });
  }

  /** Parte do arquivo (corpo binário). Gravada à parte e só juntada depois de o banco aceitar a ordem. */
  @Put(':id/parts/:part')
  async part(@Param('id') id: string, @Param('part') part: string, @Req() request: Request) {
    const dir = requireDir();
    const importId = requireUuid(id);
    const number = Number(part);
    const declared = Number(request.headers['content-length']);
    if (!Number.isSafeInteger(number) || number < 1 || !Number.isSafeInteger(declared) || declared < 1 || declared > PART_BYTES) {
      throw new AppError('FA741');
    }
    // Permissão e arquivo do grupo antes de gravar qualquer coisa.
    await this.database.withContext((client) => client.query('SELECT app.document_import_report($1)', [importId]));
    await mkdir(dir, { recursive: true });
    const temporary = join(dir, `${importId}.part${number}`);
    let received = 0;
    const counter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        received += chunk.length;
        if (received > declared) {
          callback(new AppError('FA741'));
          return;
        }
        callback(null, chunk);
      },
    });
    try {
      await pipeline(request, counter, createWriteStream(temporary));
      if (received !== declared) throw new AppError('FA741');
      const total = await this.database.withContext(async (client) => {
        const { rows } = await client.query<{ n: string }>('SELECT app.document_import_part($1, $2, $3) AS n', [importId, number, received]);
        // Junta ao arquivo dentro da transação: se falhar, a parte não conta.
        await pipeline(createReadStream(temporary), createWriteStream(importFilePath(dir, importId), { flags: 'a' }));
        return Number(rows[0].n);
      });
      return { received: total };
    } finally {
      await rm(temporary, { force: true });
    }
  }

  @Post(':id/complete')
  @HttpCode(200)
  async complete(@Param('id') id: string) {
    const dir = requireDir();
    const importId = requireUuid(id);
    await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ r: { size_bytes: number } }>('SELECT app.document_import_report($1) AS r', [importId]);
      const onDisk = await stat(importFilePath(dir, importId)).then((info) => info.size, () => -1);
      // O arquivo no disco precisa ter o tamanho declarado.
      if (onDisk !== Number(rows[0].r.size_bytes)) throw new AppError('FA741');
      await client.query('SELECT app.complete_document_import($1)', [importId]);
    });
    return { status: 'queued' };
  }
}
