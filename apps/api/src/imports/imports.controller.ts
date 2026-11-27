import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  Put,
  Query,
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
import { asBody, Body, requireUuid } from '../common/parse.js';
import { DatabaseService, type DbClient } from '../database.service.js';
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

/**
 * De quem é a importação, decidido no começo de cada transação: o grupo de quem está logado (nada a
 * fazer) ou o cliente escolhido pelo administrador da plataforma (o banco confere).
 */
type Scope = (client: DbClient) => Promise<unknown>;
const ownGroup: Scope = async () => undefined;

/** O caminho de uma importação, do envio ao relatório. As regras ficam no banco. */
abstract class ImportFlow {
  constructor(protected readonly database: DatabaseService) {}

  private run<T>(scope: Scope, fn: (client: DbClient) => Promise<T>): Promise<T> {
    return this.database.withContext(async (client) => {
      await scope(client);
      return fn(client);
    });
  }

  protected listIn(scope: Scope) {
    return this.run(scope, async (client) => (await client.query('SELECT * FROM app.list_document_imports()')).rows);
  }

  protected reportIn(scope: Scope, id: string) {
    const importId = requireUuid(id);
    return this.run(scope, async (client) => {
      const { rows } = await client.query<{ r: unknown }>('SELECT app.document_import_report($1) AS r', [importId]);
      return rows[0].r;
    });
  }

  protected createIn(scope: Scope, body: Body) {
    requireDir();
    const { fileName, size } = body;
    if (typeof fileName !== 'string' || fileName.length > 200 || typeof size !== 'number' || !Number.isSafeInteger(size)) {
      throw new AppError('FA740');
    }
    return this.run(scope, async (client) => {
      const { rows } = await client.query<{ id: string }>('SELECT app.create_document_import($1, $2) AS id', [fileName, size]);
      return { id: rows[0].id, partBytes: PART_BYTES };
    });
  }

  /** Parte do arquivo (corpo binário). Gravada à parte e só juntada depois de o banco aceitar a ordem. */
  protected async partIn(scope: Scope, id: string, part: string, request: Request) {
    const dir = requireDir();
    const importId = requireUuid(id);
    const number = Number(part);
    const declared = Number(request.headers['content-length']);
    if (!Number.isSafeInteger(number) || number < 1 || !Number.isSafeInteger(declared) || declared < 1 || declared > PART_BYTES) {
      throw new AppError('FA741');
    }
    // Permissão e arquivo do grupo antes de gravar qualquer coisa.
    await this.run(scope, (client) => client.query('SELECT app.document_import_report($1)', [importId]));
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
      const total = await this.run(scope, async (client) => {
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

  protected async completeIn(scope: Scope, id: string) {
    const dir = requireDir();
    const importId = requireUuid(id);
    await this.run(scope, async (client) => {
      const { rows } = await client.query<{ r: { size_bytes: number } }>('SELECT app.document_import_report($1) AS r', [importId]);
      const onDisk = await stat(importFilePath(dir, importId)).then((info) => info.size, () => -1);
      // O arquivo no disco precisa ter o tamanho declarado.
      if (onDisk !== Number(rows[0].r.size_bytes)) throw new AppError('FA741');
      await client.query('SELECT app.complete_document_import($1)', [importId]);
    });
    return { status: 'queued' };
  }
}

/** Importação das notas do sistema anterior: o arquivo chega em partes e é processado depois. */
@Controller('admin/imports')
@UseGuards(SessionGuard)
export class ImportsController extends ImportFlow {
  constructor(@Inject(DatabaseService) database: DatabaseService) {
    super(database);
  }

  @Get()
  list() {
    return this.listIn(ownGroup);
  }

  @Get(':id')
  report(@Param('id') id: string) {
    return this.reportIn(ownGroup, id);
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    return this.createIn(ownGroup, asBody(rawBody));
  }

  @Put(':id/parts/:part')
  part(@Param('id') id: string, @Param('part') part: string, @Req() request: Request) {
    return this.partIn(ownGroup, id, part, request);
  }

  @Post(':id/complete')
  @HttpCode(200)
  complete(@Param('id') id: string) {
    return this.completeIn(ownGroup, id);
  }
}

/** O cliente escolhido pelo administrador da plataforma. */
const clientGroup =
  (groupId: unknown): Scope =>
  (client) =>
    client.query('SELECT app.use_import_group($1)', [requireUuid(groupId)]);

/** O cliente de uma importação já começada. */
const groupOfImport =
  (importId: string): Scope =>
  (client) =>
    client.query('SELECT app.use_import_of($1)', [requireUuid(importId)]);

/**
 * Importação pela Plataforma: o administrador da plataforma envia o arquivo de um cliente, que entra
 * no grupo dele com o mesmo processamento e o mesmo relatório.
 */
@Controller('platform/imports')
@UseGuards(SessionGuard)
export class PlatformImportsController extends ImportFlow {
  constructor(@Inject(DatabaseService) database: DatabaseService) {
    super(database);
  }

  @Get()
  list(@Query('groupId') groupId?: string) {
    return this.listIn(clientGroup(groupId));
  }

  @Get(':id')
  report(@Param('id') id: string) {
    return this.reportIn(groupOfImport(id), id);
  }

  @Post()
  create(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.createIn(clientGroup(body.groupId), body);
  }

  @Put(':id/parts/:part')
  part(@Param('id') id: string, @Param('part') part: string, @Req() request: Request) {
    return this.partIn(groupOfImport(id), id, part, request);
  }

  @Post(':id/complete')
  @HttpCode(200)
  complete(@Param('id') id: string) {
    return this.completeIn(groupOfImport(id), id);
  }
}
