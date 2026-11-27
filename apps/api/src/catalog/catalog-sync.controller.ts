import { Controller, Get, HttpCode, Inject, Post, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
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

  /** Começa a cópia e responde na hora; a tela acompanha pela situação. */
  @Post('run')
  @HttpCode(202)
  async run() {
    await this.database.withContext((client) => client.query('SELECT app.require_platform_admin()'));
    if (!this.catalog.configured) throw new AppError('FA228');
    void this.catalog.sync('manual').then(() => this.catalog.syncImages());
    return { started: true };
  }
}
