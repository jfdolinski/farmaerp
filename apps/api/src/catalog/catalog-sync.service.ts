import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { DatabaseService } from '../database.service.js';
import { AppLogger } from '../observability/app-logger.js';
import { CatalogClient, catalogConfig, CatalogUnavailable, MappedItem, mapItem } from './catalog-client.js';
import { PreparedImage, prepareImage } from './catalog-images.js';

const WORKER = { worker: 'catalog' };
const BATCH = 500;
const SYNC_EVERY_MS = 60 * 60_000;
const IMAGES_EVERY_MS = 5 * 60_000;
const FIRST_SYNC_MS = 60_000;

type SyncResult = 'busy' | 'unchanged' | 'updated' | 'failed';

/**
 * Cópia do Catálogo externo para o Catálogo do FarmaERP: o catálogo completo de hora em hora (com a
 * ETag, para não baixar de novo o que não mudou), só os itens que mudaram vão ao banco, e as imagens
 * dos itens vinculados vêm aos poucos. O código de barras que a cópia não tem é consultado na hora.
 * Sem CATALOG_URL e CATALOG_API_KEY, fica desligada. CATALOG_WORKER=off desliga só a rotina.
 */
@Injectable()
export class CatalogSyncService implements OnApplicationBootstrap, OnModuleDestroy {
  private timers: NodeJS.Timeout[] = [];
  private client: CatalogClient | null;
  private imagesRunning = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {
    const config = catalogConfig();
    this.client = config ? new CatalogClient(config) : null;
  }

  /** Para os testes: outro endereço ou outro cliente HTTP. */
  useClient(client: CatalogClient | null): void {
    this.client = client;
  }

  get configured(): boolean {
    return this.client !== null;
  }

  onApplicationBootstrap(): void {
    if (process.env.CATALOG_WORKER === 'off' || !this.client) return;
    const later = (fn: () => Promise<unknown>, ms: number, repeat: boolean) => {
      const timer = repeat ? setInterval(() => void fn(), ms) : setTimeout(() => void fn(), ms);
      timer.unref();
      this.timers.push(timer);
    };
    later(() => this.sync('schedule'), FIRST_SYNC_MS, false);
    later(() => this.sync('schedule'), SYNC_EVERY_MS, true);
    later(() => this.syncImages(), IMAGES_EVERY_MS, true);
  }

  onModuleDestroy(): void {
    for (const timer of this.timers) clearTimeout(timer);
  }

  private async apply(items: MappedItem[]): Promise<{ changed: number; failures: { sourceKey: string; reason: string }[] }> {
    let changed = 0;
    const failures: { sourceKey: string; reason: string }[] = [];
    for (let i = 0; i < items.length; i += BATCH) {
      const part = items.slice(i, i + BATCH);
      const result = await this.database.withContext(async (db) => {
        const { rows } = await db.query<{ r: { changed: number; failures: { sourceKey: string; reason: string }[] } }>(
          'SELECT app.catalog_sync_apply($1::jsonb) AS r',
          [JSON.stringify(part)],
        );
        return rows[0].r;
      }, WORKER);
      changed += result.changed;
      failures.push(...result.failures);
    }
    return { changed, failures };
  }

  /** Uma cópia completa. Outra em andamento: não começa ('busy'). */
  async sync(trigger: 'schedule' | 'manual'): Promise<SyncResult> {
    const client = this.client;
    if (!client) return 'failed';
    const start = await this.database.withContext(async (db) => {
      const { rows } = await db.query<{ s: { runId: string; etag: string | null; hashes: Record<string, string> } | null }>(
        'SELECT app.catalog_sync_start($1) AS s',
        [trigger],
      );
      return rows[0].s;
    }, WORKER);
    if (!start) return 'busy';
    const finish = (result: Record<string, unknown>, seen: string[] | null) =>
      this.database.withContext(
        (db) => db.query('SELECT app.catalog_sync_finish($1, $2::jsonb, $3)', [start.runId, JSON.stringify(result), seen]),
        WORKER,
      );
    try {
      const response = await client.catalog(start.etag);
      if (response.unchanged) {
        await finish({ status: 'unchanged', etag: start.etag, items: 0, changed: 0, failed: 0 }, null);
        return 'unchanged';
      }
      const mapped = response.items
        .filter((item) => item.active !== false)
        .map((item) => mapItem(item, client.baseUrl))
        .filter((item): item is MappedItem => item !== null);
      const changedItems = mapped.filter((item) => start.hashes[item.sourceKey] !== item.hash);
      const { changed, failures } = await this.apply(changedItems);
      const message = failures.length
        ? `${failures.length} item(ns) recusado(s). ${failures.slice(0, 3).map((f) => `${f.sourceKey}: ${f.reason}`).join('; ')}`
        : null;
      // Item recusado não conta como visto: o que já estava aqui continua como estava.
      const refused = new Set(failures.map((f) => f.sourceKey));
      const seen = mapped.map((item) => item.sourceKey).filter((key) => !refused.has(key) || start.hashes[key] !== undefined);
      await finish({ status: 'updated', etag: response.etag, items: mapped.length, changed, failed: failures.length, message }, seen);
      this.logger.pino.info({ context: 'CatalogSyncService', items: mapped.length, changed, failed: failures.length }, 'Cópia do Catálogo concluída');
      return 'updated';
    } catch (error) {
      const message = error instanceof CatalogUnavailable ? error.message : 'Erro ao gravar a cópia do Catálogo.';
      this.logger.pino.warn({ context: 'CatalogSyncService', err: error }, 'Cópia do Catálogo falhou');
      await finish({ status: 'failed', message }, null).catch(() => undefined);
      return 'failed';
    }
  }

  /** Traz as imagens de um lote de itens vinculados. Devolve quantos itens ficaram em dia. */
  async syncImages(limit = 50): Promise<number> {
    const client = this.client;
    if (!client || this.imagesRunning) return 0;
    this.imagesRunning = true;
    let done = 0;
    try {
      const due = await this.database.withContext(
        async (db) => (await db.query<{ source_key: string; urls: string[] }>('SELECT * FROM app.catalog_images_due($1)', [limit])).rows,
        WORKER,
      );
      for (const item of due) {
        try {
          const images: PreparedImage[] = [];
          for (const [index, url] of item.urls.slice(0, 5).entries()) {
            const prepared = await prepareImage(await client.image(url), index === 0);
            if (!images.some((image) => image.sha256 === prepared.sha256)) images.push(prepared);
          }
          await this.database.withContext(
            (db) => db.query('SELECT app.catalog_sync_images($1, $2, $3::jsonb)', [item.source_key, item.urls, JSON.stringify(images)]),
            WORKER,
          );
          done += 1;
        } catch (error) {
          // Fica na fila: tenta de novo no próximo lote.
          this.logger.pino.warn({ context: 'CatalogSyncService', sourceKey: item.source_key, err: error }, 'Imagem do Catálogo não veio');
        }
      }
    } finally {
      this.imagesRunning = false;
    }
    return done;
  }

  /**
   * Código de barras que a cópia não tem: consulta o Catálogo e grava o item (pendente, se o
   * Catálogo acabou de criar o cadastro provisório). Sem resposta, a busca segue sem ele.
   */
  async lookup(code: string): Promise<boolean> {
    const client = this.client;
    if (!client) return false;
    try {
      const external = await client.barcode(code);
      const mapped = external && external.active !== false ? mapItem(external, client.baseUrl) : null;
      if (!mapped) return false;
      const { changed } = await this.apply([mapped]);
      return changed > 0;
    } catch (error) {
      this.logger.pino.warn({ context: 'CatalogSyncService', err: error }, 'Consulta ao Catálogo falhou');
      return false;
    }
  }
}
