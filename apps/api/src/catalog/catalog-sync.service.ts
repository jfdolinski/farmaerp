import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { DatabaseService } from '../database.service.js';
import { open, seal } from '../fiscal/secret-box.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { CATALOG_KEY, CatalogClient, CatalogUnavailable, catalogUrl, Fetcher, MappedItem, mapItem } from './catalog-client.js';
import { PreparedImage, prepareImage } from './catalog-images.js';

const WORKER = { worker: 'catalog' };
const BATCH = 500;
const SYNC_EVERY_MS = 60 * 60_000;
const IMAGES_EVERY_MS = 5 * 60_000;
const TAXES_EVERY_MS = 5 * 60_000;
const FIRST_SYNC_MS = 60_000;

type SyncResult = 'busy' | 'unchanged' | 'updated' | 'failed' | 'no_key';

/** A chave de uma filial só abre com o contexto dela: copiada para outra filial no banco, não abre. */
const keyContext = (branchId: string) => `catalog:${branchId}`;

/**
 * Cópia do Catálogo externo para o Catálogo do FarmaERP. Cada filial é uma empresa no Catálogo,
 * com a própria chave: de hora em hora, cada filial com chave faz a própria verificação (com a
 * ETag; os dados são os mesmos para todas e ficam gravados uma vez só, e só os itens que mudaram vão
 * ao banco). As imagens dos itens vinculados vêm aos poucos. O código de barras que a cópia não tem
 * é consultado na hora, com a chave da filial principal do usuário. Sem CATALOG_URL, fica
 * desligada; CATALOG_WORKER=off desliga só a rotina.
 */
@Injectable()
export class CatalogSyncService implements OnApplicationBootstrap, OnModuleDestroy {
  private timers: NodeJS.Timeout[] = [];
  private url: string | null = catalogUrl();
  private fetcher: Fetcher = fetch;
  private imagesRunning = false;

  /**
   * Chave salva começa a cópia na hora (e as imagens e a tributação depois), sem esperar a próxima
   * hora. Desligada com CATALOG_WORKER=off, como a rotina; os testes ligam quando precisam.
   */
  startAfterKey = process.env.CATALOG_WORKER !== 'off';

  /** Última rodada começada por uma chave salva (para os testes esperarem). */
  afterKey: Promise<void> = Promise.resolve();
  private taxesRunning = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  /** Para os testes: outro endereço (ou nenhum) e outro cliente HTTP. */
  useCatalog(url: string | null, fetcher: Fetcher = fetch): void {
    this.url = url;
    this.fetcher = fetcher;
  }

  get configured(): boolean {
    return this.url !== null;
  }

  private client(key: string): CatalogClient {
    if (!this.url) throw new AppError('FA228');
    return new CatalogClient({ url: this.url, key }, this.fetcher);
  }

  onApplicationBootstrap(): void {
    if (process.env.CATALOG_WORKER === 'off' || !this.url) return;
    const later = (fn: () => Promise<unknown>, ms: number, repeat: boolean) => {
      const timer = repeat ? setInterval(() => void fn(), ms) : setTimeout(() => void fn(), ms);
      timer.unref();
      this.timers.push(timer);
    };
    later(() => this.sync('schedule'), FIRST_SYNC_MS, false);
    later(() => this.sync('schedule'), SYNC_EVERY_MS, true);
    later(() => this.syncImages(), IMAGES_EVERY_MS, true);
    later(() => this.syncTaxes(), TAXES_EVERY_MS, true);
  }

  onModuleDestroy(): void {
    for (const timer of this.timers) clearTimeout(timer);
  }

  // ===== Chave da filial =====

  /**
   * Confere a chave no Catálogo e guarda cifrada. A permissão é conferida antes de tudo: quem não
   * pode trocar a chave da filial não chega a falar com o Catálogo.
   */
  async setBranchKey(branchId: string, key: string): Promise<{ keyPrefix: string }> {
    if (!CATALOG_KEY.test(key)) throw new AppError('FA231');
    await this.database.withContext((db) => db.query("SELECT app.require_branch_permission('fiscal.certificate', $1)", [branchId]));
    let verdict: Awaited<ReturnType<CatalogClient['verify']>>;
    try {
      verdict = await this.client(key).verify();
    } catch (error) {
      if (error instanceof AppError) throw error;
      throw new AppError('FA230', { cause: error });
    }
    if (verdict !== 'ok') throw new AppError('FA229');
    const keyPrefix = key.slice(0, 8);
    await this.database.withContext((db) =>
      db.query('SELECT app.set_branch_catalog_key($1, $2, $3)', [branchId, seal(Buffer.from(key, 'utf8'), keyContext(branchId)), keyPrefix]),
    );
    if (this.startAfterKey) this.afterKey = this.refreshAll();
    return { keyPrefix };
  }

  /** Cópia, imagens e tributação, uma depois da outra, em segundo plano (falha fica na situação da cópia). */
  private async refreshAll(): Promise<void> {
    try {
      await this.sync('manual');
      await this.syncImages();
      await this.syncTaxes();
    } catch (error) {
      this.logger.pino.warn({ context: 'CatalogSyncService', err: error }, 'Atualização do Catálogo depois da chave falhou');
    }
  }

  // ===== Cópia =====

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

  /** Verificação de todas as filiais com chave, uma depois da outra. */
  async sync(trigger: 'schedule' | 'manual'): Promise<SyncResult> {
    if (!this.url) return 'failed';
    const keys = await this.database.withContext(
      async (db) => (await db.query<{ branch_id: string; encrypted_key: Buffer }>('SELECT * FROM app.catalog_branch_keys()')).rows,
      WORKER,
    );
    if (keys.length === 0) return 'no_key';
    const results: SyncResult[] = [];
    for (const key of keys) results.push(await this.syncBranch(trigger, key.branch_id, key.encrypted_key));
    for (const result of ['updated', 'unchanged', 'failed', 'busy'] as const) {
      if (results.includes(result)) return result;
    }
    return 'failed';
  }

  private async syncBranch(trigger: 'schedule' | 'manual', branchId: string, encrypted: Buffer): Promise<SyncResult> {
    const start = await this.database.withContext(async (db) => {
      const { rows } = await db.query<{ s: { runId: string; etag: string | null; hashes: Record<string, string> } | null }>(
        'SELECT app.catalog_sync_start($1, $2) AS s',
        [trigger, branchId],
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
      let key: string;
      try {
        key = open(encrypted, keyContext(branchId)).toString('utf8');
      } catch {
        throw new CatalogUnavailable('A chave desta filial não abre. Cadastre a chave de novo em Fiscal, na aba Catálogo.');
      }
      const client = this.client(key);
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
      this.logger.pino.info({ context: 'CatalogSyncService', branchId, items: mapped.length, changed, failed: failures.length }, 'Cópia do Catálogo concluída');
      return 'updated';
    } catch (error) {
      const message = error instanceof CatalogUnavailable ? error.message : 'Erro ao gravar a cópia do Catálogo.';
      this.logger.pino.warn({ context: 'CatalogSyncService', branchId, err: error }, 'Cópia do Catálogo falhou');
      await finish({ status: 'failed', message }, null).catch(() => undefined);
      return 'failed';
    }
  }

  /** Traz as imagens de um lote de itens vinculados (os arquivos não pedem chave). Devolve quantos ficaram em dia. */
  async syncImages(limit = 50): Promise<number> {
    if (!this.url || this.imagesRunning) return 0;
    this.imagesRunning = true;
    const client = this.client('');
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
   * Tributação de um lote de itens vinculados, em cada estado onde o grupo tem filial com chave (com a
   * chave de uma filial dali). O banco monta a regra dos dois regimes e diz o que não fecha.
   * Devolve quantas buscas foram feitas.
   */
  async syncTaxes(limit = 200): Promise<number> {
    if (!this.url || this.taxesRunning) return 0;
    this.taxesRunning = true;
    let done = 0;
    try {
      const due = await this.database.withContext(
        async (db) =>
          (await db.query<{ catalog_product_id: string; external_id: string; state: string; branch_id: string; encrypted_key: Buffer; item_hash: string }>(
            'SELECT * FROM app.catalog_tax_due($1)',
            [limit],
          )).rows,
        WORKER,
      );
      for (const row of due) {
        let result: Record<string, unknown>;
        try {
          const key = open(row.encrypted_key, keyContext(row.branch_id)).toString('utf8');
          const values = await this.client(key).tax(row.external_id, row.state);
          result = values ? { status: 'ok', values } : { status: 'not_found', message: 'O item não está mais no Catálogo.' };
        } catch (error) {
          result = {
            status: 'failed',
            message: error instanceof CatalogUnavailable ? error.message : 'A chave desta filial não abre. Cadastre a chave de novo em Fiscal, na aba Catálogo.',
          };
          this.logger.pino.warn({ context: 'CatalogSyncService', branchId: row.branch_id, err: error }, 'Tributação do Catálogo não veio');
        }
        await this.database.withContext(
          (db) => db.query('SELECT app.catalog_tax_apply($1, $2, $3, $4, $5::jsonb)', [
            row.catalog_product_id, row.state, row.branch_id, row.item_hash, JSON.stringify(result),
          ]),
          WORKER,
        );
        done += 1;
      }
    } finally {
      this.taxesRunning = false;
    }
    return done;
  }

  /**
   * Código de barras que a cópia não tem: consulta o Catálogo com a chave da filial principal de
   * quem está cadastrando (no contexto da requisição) e grava o item (pendente, se o Catálogo
   * acabou de criar o cadastro provisório). Sem chave ou sem resposta, a busca segue sem ele.
   */
  async lookup(code: string): Promise<boolean> {
    if (!this.url) return false;
    try {
      const keys = await this.database.withContext(
        async (db) => (await db.query<{ branch_id: string; encrypted_key: Buffer }>('SELECT * FROM app.user_catalog_key()')).rows,
      );
      if (keys.length === 0) return false;
      const client = this.client(open(keys[0].encrypted_key, keyContext(keys[0].branch_id)).toString('utf8'));
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
