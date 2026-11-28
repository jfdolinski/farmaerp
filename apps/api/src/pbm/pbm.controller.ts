import { Body as RequestBody, Controller, Get, HttpCode, Inject, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { TerminalGuard } from '../terminals/terminal.guard.js';
import type { PbmItemRequest } from './pbm-connector.js';
import { PbmService } from './pbm.service.js';

const DAY = /^\d{4}-\d{2}-\d{2}$/;

function optionalDay(value?: string): string | null {
  if (value === undefined || value === '') return null;
  if (!DAY.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) throw new AppError('FA005');
  return value;
}

/** CPF ou cartão do beneficiário: só letras e números, em maiúsculas (4 a 30). */
export function beneficiaryOf(value: unknown): string {
  if (typeof value !== 'string') throw new AppError('FA005');
  const document = value.replace(/[^0-9A-Za-z]/g, '').toUpperCase();
  if (document.length < 4 || document.length > 30) throw new AppError('FA005');
  return document;
}

/** Itens do carrinho: produto, quantidade (até 3 casas) e preço unitário (2 casas). */
export function itemsOf(value: unknown): PbmItemRequest[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 200) throw new AppError('FA005');
  const seen = new Set<string>();
  return value.map((raw) => {
    const item = asBody(raw);
    const productId = requireUuid(item.productId);
    const { quantity, unitPrice } = item;
    if (seen.has(productId)) throw new AppError('FA005');
    seen.add(productId);
    if (typeof quantity !== 'number' || !Number.isFinite(quantity) || quantity <= 0 || quantity > 9999 || Number(quantity.toFixed(3)) !== quantity) {
      throw new AppError('FA005');
    }
    if (typeof unitPrice !== 'number' || !Number.isFinite(unitPrice) || unitPrice <= 0 || unitPrice > 999_999 || Number(unitPrice.toFixed(2)) !== unitPrice) {
      throw new AppError('FA005');
    }
    return { productId, quantity, unitPrice };
  });
}

/** Dados de acesso do programa na filial: campos de texto, guardados cifrados. */
function credentialsOf(value: unknown): Record<string, string> {
  const body = asBody(value);
  const entries = Object.entries(body);
  if (entries.length === 0 || entries.length > 20) throw new AppError('FA005');
  for (const [key, text] of entries) {
    if (!/^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(key) || typeof text !== 'string' || text.length === 0 || text.length > 500) throw new AppError('FA005');
  }
  return body as Record<string, string>;
}

/** PBM na retaguarda: programas, filiais, dados de acesso, regras de teste e conferência. Regras e permissões no banco. */
@Controller('admin/pbm')
@UseGuards(SessionGuard)
export class PbmAdminController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(PbmService) private readonly pbm: PbmService,
  ) {}

  @Get('programs')
  programs() {
    return this.database.withContext(async (client) => (await client.query<{ x: unknown }>('SELECT app.pbm_programs() AS x')).rows[0].x);
  }

  @Post('programs')
  @HttpCode(201)
  async create(@RequestBody() rawBody: unknown) {
    const name = requireText(asBody(rawBody), 'name', 80).trim();
    const id = await this.database.withContext(async (client) =>
      (await client.query<{ id: string }>('SELECT app.save_pbm_program($1::jsonb) AS id', [JSON.stringify({ name, connector: 'test' })])).rows[0].id,
    );
    return { id };
  }

  @Patch('programs/:id')
  async update(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const name = optionalText(body, 'name', 80);
    if (body.active !== undefined && typeof body.active !== 'boolean') throw new AppError('FA005');
    const programId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.save_pbm_program($1::jsonb)', [JSON.stringify({ id: programId, name: name?.trim(), active: body.active })]),
    );
    return { id: programId };
  }

  @Post('programs/:id/branches/:branchId')
  @HttpCode(200)
  async setBranch(@Param('id') id: string, @Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    const active = asBody(rawBody).active;
    if (typeof active !== 'boolean') throw new AppError('FA005');
    await this.database.withContext((client) =>
      client.query('SELECT app.set_pbm_program_branch($1, $2, $3)', [requireUuid(id), requireUuid(branchId), active]),
    );
    return { active };
  }

  @Post('programs/:id/branches/:branchId/credentials')
  @HttpCode(200)
  async setCredentials(@Param('id') id: string, @Param('branchId') branchId: string, @RequestBody() rawBody: unknown) {
    await this.pbm.setCredentials(requireUuid(id), requireUuid(branchId), credentialsOf(asBody(rawBody).credentials));
    return { saved: true };
  }

  /** Regra do programa de teste: percentual do produto (null tira o produto). */
  @Post('programs/:id/rules')
  @HttpCode(200)
  async setRule(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    const percent = body.percent;
    if (percent !== null && (typeof percent !== 'number' || !Number.isFinite(percent) || Number(percent.toFixed(2)) !== percent)) {
      throw new AppError('FA005');
    }
    // Produto pelo id (a lista) ou pelo código ou código de barras (a tela).
    const lookup = body.productId === undefined ? requireText(body, 'productLookup', 30).trim() : null;
    const productId = lookup === null ? requireUuid(body.productId) : null;
    const programId = requireUuid(id);
    await this.database.withContext((client) =>
      lookup === null
        ? client.query('SELECT app.set_pbm_test_rule($1, $2, $3)', [programId, productId, percent])
        : client.query('SELECT app.set_pbm_test_rule_by_lookup($1, $2, $3)', [programId, lookup, percent]),
    );
    return { percent };
  }

  @Get('authorizations')
  authorizations(@Query('from') from?: string, @Query('to') to?: string, @Query('branch') branch?: string) {
    const params = [optionalDay(from), optionalDay(to), branch ? requireUuid(branch) : null];
    return this.database.withContext(async (client) =>
      (await client.query<{ x: unknown }>('SELECT app.pbm_authorizations($1, $2, $3) AS x', params)).rows[0].x,
    );
  }
}

/** PBM no caixa, só com internet: programas da loja, autorização, confirmação e desfazer. */
@Controller('terminals/pbm')
@UseGuards(TerminalGuard)
export class TerminalPbmController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(PbmService) private readonly pbm: PbmService,
  ) {}

  @Get('programs')
  programs() {
    return this.database.withContext(async (client) => (await client.query<{ x: unknown }>('SELECT app.terminal_pbm_programs() AS x')).rows[0].x);
  }

  @Post('authorize')
  @HttpCode(200)
  authorize(@RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    return this.pbm.authorize(requireUuid(body.programId), beneficiaryOf(body.beneficiary), itemsOf(body.items));
  }

  @Post(':id/confirm')
  @HttpCode(200)
  confirm(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.pbm.confirm(requireUuid(id), requireUuid(asBody(rawBody).saleId));
  }

  @Post(':id/undo')
  @HttpCode(200)
  undo(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const reason = optionalText(asBody(rawBody), 'reason', 255)?.trim() || 'Venda não concluída';
    return this.pbm.undo(requireUuid(id), reason);
  }
}
