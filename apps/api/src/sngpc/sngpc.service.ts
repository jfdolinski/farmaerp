import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { v7 as uuidv7 } from 'uuid';
import { DatabaseService, DbClient } from '../database.service.js';
import { open } from '../fiscal/secret-box.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { runWithContext } from '../observability/request-context.js';
import { HttpSngpcGateway, SngpcCredential, SngpcGateway, sngpcEndpoint } from './sngpc-gateway.js';
import { buildSubmissionXml, SubmissionData } from './sngpc-xml.js';

const TICK_MS = 60_000;

interface ClaimedBranch {
  branch_id: string;
  cnpj: string;
  encrypted_username: Buffer;
  encrypted_password: Buffer;
}

interface OpenSubmission extends SubmissionData {
  status: 'built' | 'sent';
  protocol: string | null;
}

/** Contexto da criptografia da credencial: a de uma filial, copiada para outra, não abre. */
export const credentialContext = (branchId: string) => `sngpc:${branchId}`;

/**
 * Envio do SNGPC. A cada minuto pega as filiais com algo a fazer (reserva no banco, então várias
 * instâncias da API não repetem), consulta o resultado da remessa enviada ou monta e envia a próxima.
 * Com o envio real desligado (sem SNGPC_LIVE), só monta e espera.
 */
@Injectable()
export class SngpcService implements OnApplicationBootstrap, OnModuleDestroy {
  private timer: NodeJS.Timeout | undefined;
  private running = false;
  /** Troca nos testes (Anvisa falsa). */
  gateway: () => SngpcGateway | null = () => {
    const url = sngpcEndpoint();
    return url ? new HttpSngpcGateway(url) : null;
  };

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  onApplicationBootstrap(): void {
    if (process.env.SNGPC_WORKER === 'off') return;
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private worker<T>(fn: (client: DbClient) => Promise<T>): Promise<T> {
    return this.database.withContext(fn, { worker: 'sngpc' });
  }

  /** Uma rodada. Nunca lança: o erro de uma filial não para as outras. */
  async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await runWithContext({ traceId: uuidv7() }, async () => {
        const branches = await this.worker(async (client) =>
          (await client.query<ClaimedBranch>('SELECT * FROM app.sngpc_claim_branches(10)')).rows,
        );
        for (const branch of branches) {
          try {
            await this.handle(branch);
          } catch (error) {
            this.logger.pino.warn({ context: 'SngpcService', branchId: branch.branch_id, err: error }, 'rodada do SNGPC falhou na filial');
          } finally {
            await this.worker((client) => client.query('SELECT app.sngpc_release_branch($1)', [branch.branch_id]));
          }
        }
      });
    } catch (error) {
      this.logger.pino.error({ context: 'SngpcService', err: error }, 'rodada do SNGPC falhou');
    } finally {
      this.running = false;
    }
  }

  private async handle(branch: ClaimedBranch): Promise<void> {
    const submission = await this.worker(async (client) => {
      const { rows } = await client.query<{ s: OpenSubmission | null }>('SELECT app.sngpc_next_submission($1) AS s', [branch.branch_id]);
      return rows[0].s;
    });
    if (!submission) return;
    const gateway = this.gateway();
    if (!gateway) return;
    const context = credentialContext(branch.branch_id);
    const credential: SngpcCredential = {
      username: open(branch.encrypted_username, context).toString('utf8'),
      password: open(branch.encrypted_password, context).toString('utf8'),
    };
    try {
      if (submission.status === 'sent' && submission.protocol) {
        const result = await gateway.status(credential, submission.protocol);
        if (result.state === 'processing') return;
        await this.worker((client) =>
          client.query('SELECT app.sngpc_mark_result($1, $2, $3)', [
            submission.id,
            result.state === 'accepted',
            result.state === 'rejected' ? result.reason : null,
          ]),
        );
        this.logger.pino.info({ context: 'SngpcService', submissionId: submission.id, state: result.state }, 'resultado do SNGPC');
        return;
      }
      const xml = buildSubmissionXml(submission, credential.username);
      const sha256 = createHash('sha256').update(xml, 'utf8').digest('hex');
      const protocol = await gateway.send(credential, branch.cnpj, xml, sha256);
      await this.worker((client) => client.query('SELECT app.sngpc_mark_sent($1, $2, $3, $4)', [submission.id, xml, sha256, protocol]));
      this.logger.pino.info({ context: 'SngpcService', submissionId: submission.id, movements: submission.movements.length }, 'remessa do SNGPC enviada');
    } catch (error) {
      const code = error instanceof AppError ? error.code : 'FA721';
      const message = code === 'FA722' ? 'O SNGPC recusou a credencial da filial.' : 'Não foi possível falar com o SNGPC.';
      await this.worker((client) => client.query('SELECT app.sngpc_mark_failed($1, $2)', [submission.id, `${code}: ${message}`]));
      throw error;
    }
  }
}
