import {
  Body as RequestBody,
  Controller,
  Get,
  HttpCode,
  Inject,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { SessionGuard } from '../auth/session.guard.js';
import { asBody, requireUuid } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';

const STATUSES = new Set(['open', 'resolved', 'all']);

/** Conflitos da sincronização. Quem pode ver e resolver é decidido no banco. */
@Controller('admin/sync/conflicts')
@UseGuards(SessionGuard)
export class SyncConflictsController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Get()
  list(@Query('status') status = 'open', @Query('branch') branch?: string) {
    if (!STATUSES.has(status)) throw new AppError('FA005');
    const params = [status === 'all' ? null : status, branch ? requireUuid(branch) : null];
    return this.database.withContext(
      async (client) => (await client.query('SELECT * FROM app.list_sync_conflicts($1, $2)', params)).rows,
    );
  }

  @Post(':id/resolve')
  @HttpCode(200)
  async resolve(@Param('id') id: string, @RequestBody() rawBody: unknown) {
    const note = asBody(rawBody).note;
    if (note !== undefined && note !== null && (typeof note !== 'string' || note.length > 2000)) {
      throw new AppError('FA005');
    }
    const conflictId = requireUuid(id);
    await this.database.withContext((client) =>
      client.query('SELECT app.resolve_sync_conflict($1, $2)', [conflictId, note ?? null]),
    );
    return { status: 'resolved' };
  }

  /** Aplica de novo o item do conflito. Devolve "applied" ou "conflict" com o código da nova recusa. */
  @Post(':id/retry')
  @HttpCode(200)
  async retry(@Param('id') id: string) {
    const conflictId = requireUuid(id);
    return this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: { status: 'applied' | 'conflict'; code?: string } }>(
        'SELECT app.retry_sync_conflict($1) AS result',
        [conflictId],
      );
      return rows[0].result;
    });
  }
}
