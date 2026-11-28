import { Inject, Injectable } from '@nestjs/common';
import { DatabaseService, DbClient } from '../database.service.js';
import { open, seal } from '../fiscal/secret-box.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { PBM_CONNECTORS, PbmCall, PbmConnector, PbmItemRequest } from './pbm-connector.js';

interface Context {
  program_id: string;
  branch_id: string;
  connector: string;
  encrypted_credentials: Buffer | null;
}

interface ActionContext extends Context {
  id: string;
  status: string;
  external_id: string;
  expires_at: Date;
  sale_id: string | null;
}

/** Contexto do cifrado dos dados de acesso: o mesmo cifrado copiado para outro programa ou filial não abre. */
const credentialsContext = (programId: string, branchId: string) => `pbm:${programId}:${branchId}`;

/**
 * PBM pela central: o caixa pede, a API chama o conector do programa com os dados de acesso da filial
 * (abertos só na memória) e o banco registra. Duas fases: autoriza ao aplicar, confirma depois do
 * pagamento; a venda que não acontece desfaz. O documento do beneficiário nunca vai para o log.
 */
@Injectable()
export class PbmService {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  private connector(context: Context): PbmConnector {
    const connector = PBM_CONNECTORS[context.connector];
    if (!connector) throw new AppError('FA793', { cause: new Error(`conector ${context.connector} sem implementação`) });
    return connector;
  }

  private call(context: Context): PbmCall {
    const credentials = context.encrypted_credentials
      ? (JSON.parse(open(context.encrypted_credentials, credentialsContext(context.program_id, context.branch_id)).toString('utf8')) as Record<string, string>)
      : null;
    return {
      credentials,
      testRules: async (productIds) => {
        const rows = await this.database.withContext(async (client: DbClient) =>
          (await client.query<{ product_id: string; discount_percent: string }>(
            'SELECT * FROM app.terminal_pbm_test_rules($1, $2)', [context.program_id, productIds],
          )).rows,
        );
        return new Map(rows.map((row) => [row.product_id, Number(row.discount_percent)]));
      },
    };
  }

  /** Grava os dados de acesso da filial, cifrados (a retaguarda nunca lê de volta). */
  async setCredentials(programId: string, branchId: string, credentials: Record<string, string>): Promise<void> {
    const sealed = seal(Buffer.from(JSON.stringify(credentials), 'utf8'), credentialsContext(programId, branchId));
    await this.database.withContext((client) =>
      client.query('SELECT app.set_pbm_branch_credentials($1, $2, $3)', [programId, branchId, sealed]),
    );
  }

  /** Consulta o programa e registra a autorização com o preço de cada item aceito. */
  async authorize(programId: string, beneficiary: string, items: PbmItemRequest[]) {
    const context = await this.database.withContext(async (client) =>
      (await client.query<Context>('SELECT * FROM app.terminal_pbm_context($1)', [programId])).rows[0],
    );
    const connector = this.connector(context);
    const call = this.call(context);
    const quote = await connector.authorize(call, beneficiary, items);
    try {
      const registered = await this.database.withContext(async (client) =>
        (await client.query<{ r: Record<string, unknown> }>('SELECT app.terminal_pbm_register($1, $2::jsonb) AS r', [programId, JSON.stringify({
          beneficiary, external_id: quote.externalId,
          items: quote.items.map((item) => ({ product_id: item.productId, quantity: item.quantity, list_price: item.listPrice, pbm_price: item.pbmPrice })),
        })])).rows[0].r,
      );
      this.logger.pino.info({ context: 'PbmService', programId, authorizationId: registered.id, items: quote.items.length }, 'PBM autorizado');
      return { ...registered, items: quote.items };
    } catch (error) {
      // O programa autorizou, mas o registro falhou: desfaz lá para não deixar benefício solto.
      await connector.undo(call, quote.externalId, 'Falha ao registrar na central').catch((cause: unknown) =>
        this.logger.pino.warn({ context: 'PbmService', programId, err: cause }, 'PBM: desfazer depois da falha não concluiu'),
      );
      throw error;
    }
  }

  private actionContext(id: string): Promise<ActionContext> {
    return this.database.withContext(async (client) =>
      (await client.query<ActionContext>('SELECT * FROM app.terminal_pbm_action_context($1)', [id])).rows[0],
    );
  }

  /** Confirma no programa e registra a venda. Repetido com a mesma venda: já está feito. */
  async confirm(id: string, saleId: string): Promise<{ status: string }> {
    const context = await this.actionContext(id);
    if (context.status === 'confirmed' && context.sale_id === saleId) return { status: 'confirmed' };
    if (context.status !== 'authorized' || context.expires_at.getTime() < Date.now()) {
      throw new AppError('FA795', { detail: `Autorização em ${context.status}.` });
    }
    await this.connector(context).confirm(this.call(context), context.external_id, saleId);
    const status = await this.database.withContext(async (client) =>
      (await client.query<{ s: string }>('SELECT app.terminal_pbm_confirm($1, $2) AS s', [id, saleId])).rows[0].s,
    );
    this.logger.pino.info({ context: 'PbmService', authorizationId: id }, 'PBM confirmado');
    return { status };
  }

  /** Desfaz no programa a autorização da venda que não aconteceu. Repetido: já está feito. */
  async undo(id: string, reason: string): Promise<{ status: string }> {
    const context = await this.actionContext(id);
    if (context.status === 'undone' || context.status === 'expired') return { status: context.status };
    if (context.status !== 'authorized') throw new AppError('FA795', { detail: `Autorização em ${context.status}.` });
    await this.connector(context).undo(this.call(context), context.external_id, reason);
    const status = await this.database.withContext(async (client) =>
      (await client.query<{ s: string }>('SELECT app.terminal_pbm_undo($1, $2) AS s', [id, reason])).rows[0].s,
    );
    return { status };
  }
}
