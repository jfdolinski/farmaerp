import { Body as RequestBody, Controller, Delete, Get, HttpCode, Inject, Param, Post, Put, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { CatalogSyncService } from './catalog-sync.service.js';

/** Cópia do Catálogo externo, na Plataforma: situação e "Atualizar agora". Só o administrador da plataforma. */
@Controller('platform/catalog-sync')
@UseGuards(SessionGuard)
export class CatalogSyncController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(CatalogSyncService) private readonly catalog: CatalogSyncService,
  ) {}

  @Get()
  async status() {
    const status = await this.database.withContext(async (client) => (await client.query('SELECT app.catalog_sync_status() AS s')).rows[0].s);
    return { configured: this.catalog.configured, ...status };
  }

  /** Começa a verificação das filiais com chave e responde na hora; a tela acompanha pela situação. */
  @Post('run')
  @HttpCode(202)
  async run() {
    await this.database.withContext((client) => client.query('SELECT app.require_platform_admin()'));
    if (!this.catalog.configured) throw new AppError('FA228');
    void this.catalog.sync('manual').then(() => this.catalog.syncImages()).then(() => this.catalog.syncTaxes());
    return { started: true };
  }
}

/**
 * Chave do Catálogo de cada filial (cada filial é uma empresa no Catálogo, cobrada pelo que
 * consulta). Quem cuida do certificado da filial cadastra; a chave é conferida no Catálogo e fica
 * cifrada. A lista mostra só o começo dela.
 */
@Controller('admin/catalog-keys')
@UseGuards(SessionGuard)
export class CatalogKeysController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(CatalogSyncService) private readonly catalog: CatalogSyncService,
  ) {}

  @Get()
  async list() {
    const rows = await this.database.withContext(async (client) => (await client.query('SELECT * FROM app.branch_catalog_keys()')).rows);
    return { configured: this.catalog.configured, branches: rows };
  }

  @Put(':branchId')
  async set(@Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const id = requireUuid(branchId);
    const key = asBody(rawBody).key;
    if (typeof key !== 'string') throw new AppError('FA231');
    if (!this.catalog.configured) throw new AppError('FA228');
    return this.catalog.setBranchKey(id, key.trim());
  }

  @Delete(':branchId')
  @HttpCode(200)
  async clear(@Param('branchId') branchId: string) {
    const id = requireUuid(branchId);
    await this.database.withContext((client) => client.query('SELECT app.clear_branch_catalog_key($1)', [id]));
    return { status: 'ok' };
  }
}
