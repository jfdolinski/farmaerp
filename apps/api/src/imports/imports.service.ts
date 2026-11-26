import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { existsSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { join } from 'node:path';
import yauzl from 'yauzl';
import { v7 as uuidv7 } from 'uuid';
import { DatabaseService, type DbClient } from '../database.service.js';
import { AppLogger } from '../observability/app-logger.js';
import { runWithContext } from '../observability/request-context.js';
import { parseEntry } from './nfe-parse.js';

const TICK_MS = 10_000;
/** Uma nota tem poucos KB; acima disso a entrada não é lida (protege a memória). */
const MAX_ENTRY_BYTES = 10 * 1024 * 1024;
const PROGRESS_EVERY = 100;
/** Notas liberadas pela plataforma: reservadas de 50 em 50, por até 8 segundos a cada rodada. */
const RELEASED_BATCH = 50;
const RELEASED_BUDGET_MS = 8_000;

interface ReleasedNote {
  import_id: string;
  entry: string;
  model: '55' | '65';
  note: unknown;
}

/** Volume padrão no servidor (EasyPanel): basta montar o volume, sem variável. */
export const DEFAULT_IMPORTS_DIR = '/data/imports';

/**
 * Pasta dos arquivos enviados: IMPORTS_DIR, ou o volume padrão quando ele existe. Sem nenhum dos
 * dois, a importação fica indisponível.
 */
export function importsDir(defaultDir = DEFAULT_IMPORTS_DIR): string | null {
  const dir = process.env.IMPORTS_DIR;
  if (dir && dir.trim() !== '') return dir;
  return existsSync(defaultDir) ? defaultDir : null;
}

export const importFilePath = (dir: string, id: string) => join(dir, `${id}.zip`);

export interface ImportTotals {
  entries: number;
  models: Record<string, number>;
  imported: number;
  duplicate: number;
  ignored: number;
  failed: number;
  canceled: number;
  /** Notas de CNPJ que o cliente ainda não tem: esperam o administrador da plataforma. */
  waiting: number;
}

/** Texto da entrada: UTF-8, ou ISO-8859-1 quando o XML declara. */
function decode(buffer: Buffer): string {
  const head = buffer.subarray(0, 200).toString('latin1');
  return /encoding=["']iso-8859-1["']/i.test(head) ? buffer.toString('latin1') : buffer.toString('utf8').replace(/^﻿/, '');
}

/** Lê as entradas do .zip uma a uma (sem carregar o arquivo inteiro na memória). */
function readEntries(path: string, onEntry: (name: string, content: Buffer | null) => Promise<void>): Promise<void> {
  return new Promise((resolve, reject) => {
    yauzl.open(path, { lazyEntries: true, autoClose: true }, (openError, zip) => {
      if (openError || !zip) {
        reject(openError ?? new Error('zip'));
        return;
      }
      zip.on('error', reject);
      zip.on('end', () => resolve());
      zip.on('entry', (entry: yauzl.Entry) => {
        const name = entry.fileName;
        if (name.endsWith('/')) {
          zip.readEntry();
          return;
        }
        if (!/\.xml$/i.test(name) || entry.uncompressedSize > MAX_ENTRY_BYTES) {
          onEntry(name, null).then(() => zip.readEntry(), reject);
          return;
        }
        zip.openReadStream(entry, (streamError, stream) => {
          if (streamError || !stream) {
            onEntry(name, null).then(() => zip.readEntry(), reject);
            return;
          }
          const chunks: Buffer[] = [];
          stream.on('data', (chunk: Buffer) => chunks.push(chunk));
          stream.on('error', reject);
          stream.on('end', () => {
            onEntry(name, Buffer.concat(chunks)).then(() => zip.readEntry(), reject);
          });
        });
      });
      zip.readEntry();
    });
  });
}

/**
 * Processa os arquivos da fila: cada XML vira uma chamada ao banco (uma transação por nota). O
 * arquivo é lido duas vezes: primeiro as NFC-e (que cadastram as filiais do cliente) e o resto;
 * depois as NF-e (modelo 55), que dependem das filiais para saber a direção da nota. Os
 * cancelamentos ficam para o fim. Reprocessar é seguro: nota repetida é ignorada pela chave.
 */
@Injectable()
export class ImportsService implements OnApplicationBootstrap, OnModuleDestroy {
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  onApplicationBootstrap(): void {
    if (process.env.IMPORTS_WORKER === 'off') return;
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private worker<T>(fn: (client: DbClient) => Promise<T>): Promise<T> {
    return this.database.withContext(fn, { worker: 'import' });
  }

  /** Um arquivo por rodada. Nunca lança. */
  async tick(): Promise<void> {
    const dir = importsDir();
    if (this.running || !dir) return;
    this.running = true;
    try {
      await runWithContext({ traceId: uuidv7() }, async () => {
        const job = await this.worker(async (client) =>
          (await client.query<{ j: { id: string } | null }>('SELECT app.claim_document_import() AS j')).rows[0].j,
        );
        if (job) await this.process(dir, job.id);
        await this.processReleased();
      });
    } catch (error) {
      this.logger.pino.error({ context: 'ImportsService', err: error }, 'falha no processamento da importação');
    } finally {
      this.running = false;
    }
  }

  /**
   * Notas que esperavam o destino do CNPJ e foram liberadas pela plataforma: entram pela
   * importação delas (NFC-e antes, que criam os produtos). Uma falha não para as outras.
   */
  async processReleased(budgetMs = RELEASED_BUDGET_MS): Promise<number> {
    const started = Date.now();
    let total = 0;
    while (Date.now() - started < budgetMs) {
      const notes = await this.worker(async (client) =>
        (await client.query<{ n: ReleasedNote[] }>('SELECT app.claim_released_import_notes($1) AS n', [RELEASED_BATCH])).rows[0].n,
      );
      if (notes.length === 0) break;
      for (const note of notes) {
        const function_ = note.model === '55' ? 'import_nfe' : 'import_nfce';
        try {
          await this.worker((client) =>
            client.query(`SELECT app.${function_}($1, $2, $3::jsonb)`, [note.import_id, note.entry, JSON.stringify(note.note)]),
          );
        } catch (error) {
          this.logger.pino.warn({ context: 'ImportsService', importId: note.import_id, model: note.model, err: error }, 'nota liberada não processada');
        }
      }
      total += notes.length;
    }
    if (total > 0) this.logger.pino.info({ context: 'ImportsService', released: total }, 'notas liberadas pela plataforma');
    return total;
  }

  async process(dir: string, id: string): Promise<ImportTotals> {
    const totals: ImportTotals = { entries: 0, models: {}, imported: 0, duplicate: 0, ignored: 0, failed: 0, canceled: 0, waiting: 0 };
    const cancels: { entry: string; key: string; at: string | null }[] = [];
    const record = (entry: string, key: string | null, model: string | null, result: string, reason: string) =>
      this.worker((client) =>
        client.query('SELECT app.import_note_result($1, $2, $3, $4, $5, NULL, $6)', [id, entry, key, model, result, reason]),
      );
    const store = async (name: string, function_: string, note: unknown) => {
      const { rows } = await this.worker((client) =>
        client.query<{ r: { result: keyof ImportTotals } }>(`SELECT app.${function_}($1, $2, $3::jsonb) AS r`, [
          id, name, JSON.stringify(note),
        ]),
      );
      const result = rows[0].r.result;
      if (result === 'imported' || result === 'duplicate' || result === 'ignored' || result === 'failed' || result === 'waiting') {
        totals[result] += 1;
      }
    };
    let pendingNfe = 0;
    const progress = (status: string | null, error: string | null) =>
      this.worker((client) =>
        client.query('SELECT app.document_import_progress($1, $2::jsonb, $3, $4)', [id, JSON.stringify(totals), status, error]),
      );
    try {
      await readEntries(importFilePath(dir, id), async (name, content) => {
        totals.entries += 1;
        if (content === null) {
          totals.ignored += 1;
          await record(name, null, null, 'ignored', 'Entrada que não é XML de nota.');
        } else {
          const parsed = parseEntry(decode(content));
          if (parsed.kind === 'note') {
            const model = parsed.note.model;
            totals.models[model] = (totals.models[model] ?? 0) + 1;
            // NF-e fica para a segunda passada.
            if (model === '55') pendingNfe += 1;
            else await store(name, 'import_nfce', parsed.note);
          } else if (parsed.kind === 'cancel') {
            cancels.push({ entry: name, key: parsed.accessKey, at: parsed.canceledAt });
          } else if (parsed.kind === 'other') {
            const model = parsed.model ?? 'evento';
            totals.models[model] = (totals.models[model] ?? 0) + 1;
            totals.ignored += 1;
            await record(name, parsed.accessKey, parsed.model, 'ignored', parsed.reason);
          } else {
            totals.failed += 1;
            await record(name, null, null, 'failed', parsed.reason);
          }
        }
        if (totals.entries % PROGRESS_EVERY === 0) await progress(null, null);
      });
      // Segunda passada: só as NF-e.
      if (pendingNfe > 0) {
        let done = 0;
        await readEntries(importFilePath(dir, id), async (name, content) => {
          if (content === null) return;
          const parsed = parseEntry(decode(content));
          if (parsed.kind !== 'note' || parsed.note.model !== '55') return;
          await store(name, 'import_nfe', parsed.note);
          done += 1;
          if (done % PROGRESS_EVERY === 0) await progress(null, null);
        });
      }
      for (const cancel of cancels) {
        await this.worker((client) =>
          client.query('SELECT app.import_nfce_cancel($1, $2, $3, $4)', [id, cancel.entry, cancel.key, cancel.at]),
        );
        totals.canceled += 1;
      }
      await progress('done', null);
      await rm(importFilePath(dir, id), { force: true });
      this.logger.pino.info({ context: 'ImportsService', importId: id, totals }, 'importação concluída');
    } catch (error) {
      await progress('failed', 'Arquivo .zip inválido ou corrompido.');
      this.logger.pino.warn({ context: 'ImportsService', importId: id, err: error }, 'importação com arquivo inválido');
    }
    return totals;
  }
}
