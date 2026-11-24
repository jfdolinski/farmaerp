import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  UseGuards,
} from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, optionalText, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

/** Rotas da retaguarda. As permissões são decididas pelo banco. */
@Controller('admin')
@UseGuards(SessionGuard)
export class TerminalAdminController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get('branches')
  branches() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT id, name, state, pmc_region, offline_zero_stock_minutes, quote_validity_days, seller_pin_required, return_days FROM v_branch ORDER BY name',
      );
      return rows;
    });
  }

  @Get('terminals')
  terminals() {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        'SELECT * FROM v_terminal_monitor ORDER BY branch_name, name NULLS FIRST, created_at',
      );
      return rows;
    });
  }

  @Get('terminals/:id/events')
  events(@Param('id') id: string) {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query(
        `SELECT event_type, from_status, to_status, reason, updated_by, created_at
           FROM v_terminal_event WHERE terminal_id = $1 ORDER BY created_at, id`,
        [requireUuid(id)],
      );
      return rows;
    });
  }

  // Limite por IP: dificulta testar códigos em sequência.
  @Get('pairing/:code')
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  findPairing(@Param('code') code: string) {
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: unknown }>(
        'SELECT app.find_pairing_request($1) AS result',
        [code],
      );
      return rows[0].result;
    });
  }

  @Post('pairing/:code/claim')
  @Throttle({ default: { limit: 20, ttl: 60_000 } })
  claim(@Param('code') code: string, @RequestBody() rawBody: unknown) {
    const branchId = requireUuid(asBody(rawBody).branchId);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT app.claim_pairing_request($1, $2) AS id',
        [code, branchId],
      );
      return { terminalId: rows[0].id };
    });
  }

  @Post('terminals/:id/approve')
  @HttpCode(200)
  async approve(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const body = asBody(rawBody);
    await this.database.withContext((client) =>
      client.query('SELECT app.approve_terminal($1, $2, $3)', [
        requireUuid(id),
        optionalText(body, 'name', 100),
        optionalText(body, 'profile', 20),
      ]),
    );
    return { status: 'active' };
  }

  /** Caixa, orçamento ou autoatendimento. O PDV muda de modo na próxima sincronização. */
  @Post('terminals/:id/profile')
  @HttpCode(200)
  async profile(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const terminalId = requireUuid(id);
    const value = asBody(rawBody).profile;
    if (typeof value !== 'string') throw new AppError('FA218');
    await this.database.withContext((client) => client.query('SELECT app.set_terminal_profile($1, $2)', [terminalId, value]));
    return { status: 'ok' };
  }

  @Post('terminals/:id/block')
  @HttpCode(200)
  block(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.setStatus(id, 'blocked', rawBody);
  }

  @Post('terminals/:id/unblock')
  @HttpCode(200)
  unblock(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.setStatus(id, 'active', rawBody);
  }

  @Post('terminals/:id/revoke')
  @HttpCode(200)
  revoke(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    return this.setStatus(id, 'revoked', rawBody);
  }

  private async setStatus(id: string, status: string, rawBody: unknown) {
    const reason = optionalText(asBody(rawBody ?? {}), 'reason');
    await this.database.withContext((client) =>
      client.query('SELECT app.set_terminal_status($1, $2, $3)', [
        requireUuid(id),
        status,
        reason,
      ]),
    );
    return { status };
  }
}
