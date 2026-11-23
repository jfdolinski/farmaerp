import { Inject, Injectable, OnApplicationBootstrap, OnModuleDestroy } from '@nestjs/common';
import { v7 as uuidv7 } from 'uuid';
import { DatabaseService, DbClient } from '../database.service.js';
import { open } from '../fiscal/secret-box.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { runWithContext } from '../observability/request-context.js';
import { readAuthorizedNfe, sha256 } from '../purchases/nfe-xml.js';
import {
  awarenessEnvelope,
  CANCELLATION_EVENT,
  DIST_ACTION,
  DistDocument,
  distributionEnvelope,
  EVENT_ACTION,
  parseDistribution,
  parseEventResponse,
  pemFromPfx,
  readEvent,
  readSummary,
} from './dfe.js';
import {
  NFSE_BATCH_SIZE,
  NfseDocument,
  nfseDistributionUrl,
  parseNfseDistribution,
  readServiceEvent,
  readServiceInvoice,
} from './nfse.js';
import { sefazEndpoints, sefazEnvironment, UF_CODES } from './sefaz-config.js';
import { ClientCertificate, httpsCall, postSoap } from './soap.js';

const TICK_MS = 60_000;
// Uma rodada busca até 10 páginas (500 documentos) por filial; o resto fica para o minuto seguinte.
const MAX_PAGES = 10;
const HOUR = 60;
// Pausa entre chamadas seguidas ao ADN, como fazem os clientes conhecidos da API.
const ADN_PAUSE_MS = 1000;
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

interface SealedCertificate {
  company_id: string;
  encrypted_pfx: Buffer;
  encrypted_password: Buffer;
}

interface ClaimedBranch extends SealedCertificate {
  branch_id: string;
  cnpj: string;
  state: string | null;
  last_nsu: string;
}

interface ClaimedNfseBranch extends SealedCertificate {
  branch_id: string;
  cnpj: string;
  last_nsu: string;
}

interface ClaimedQuery extends SealedCertificate {
  branch_id: string;
  cnpj: string;
  state: string | null;
  access_key: string;
  kind: 'confirm' | 'xml';
}

/** Abre o certificado guardado só na memória e só para a chamada. */
function certificateOf(row: SealedCertificate): ClientCertificate {
  const context = `certificate:${row.company_id}`;
  return {
    pfx: open(row.encrypted_pfx, context),
    passphrase: open(row.encrypted_password, context).toString('utf8'),
  };
}

const codeOf = (error: unknown) => (error instanceof AppError ? error.code : 'FA944');

/**
 * Download automático das NF-e de compra (NFeDistribuicaoDFe) e ciência da operação.
 * A cada minuto busca as filiais ligadas que já podem buscar e consulta as chaves pendentes.
 * A espera de uma hora da Sefaz e a reserva de cada filial ficam no banco, então várias instâncias
 * da API podem rodar ao mesmo tempo sem repetir consulta.
 */
@Injectable()
export class DfeService implements OnApplicationBootstrap, OnModuleDestroy {
  private timer: NodeJS.Timeout | undefined;
  private running = false;

  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  onApplicationBootstrap(): void {
    if (process.env.DFE_WORKER === 'off') return;
    this.timer = setInterval(() => void this.tick(), TICK_MS);
    this.timer.unref();
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Uma rodada completa. Nunca lança: o erro de uma filial não para as outras. */
  async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await runWithContext({ traceId: uuidv7() }, async () => {
        await this.syncBranches();
        await this.runQueries();
        await this.syncServiceInvoices();
      });
    } catch (error) {
      this.logger.pino.error({ context: 'DfeService', err: error }, 'rodada do download falhou');
    } finally {
      this.running = false;
    }
  }

  private worker<T>(fn: (client: DbClient) => Promise<T>): Promise<T> {
    return this.database.withContext(fn, { worker: 'dfe' });
  }

  async syncBranches(): Promise<void> {
    const branches = await this.worker(async (client) =>
      (await client.query<ClaimedBranch>('SELECT * FROM app.dfe_claim_branches(10)')).rows,
    );
    for (const branch of branches) {
      await this.syncBranch(branch);
    }
  }

  private async syncBranch(branch: ClaimedBranch): Promise<void> {
    const finish = (result: Record<string, unknown>) =>
      this.worker((client) => client.query('SELECT app.dfe_finish_branch($1, $2::jsonb)', [branch.branch_id, JSON.stringify(result)]));
    const ufCode = UF_CODES[branch.state ?? ''];
    if (!ufCode) {
      await finish({ error: 'FA947', message: 'A filial está sem estado cadastrado.', waitMinutes: HOUR });
      return;
    }
    let lastNsu = branch.last_nsu;
    try {
      const certificate = certificateOf(branch);
      const endpoints = sefazEndpoints();
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const response = await postSoap(
          endpoints.distribution,
          DIST_ACTION,
          distributionEnvelope({ environment: sefazEnvironment(), ufCode, cnpj: branch.cnpj, lastNsu }),
          certificate,
          endpoints.ca,
        );
        const result = parseDistribution(response);
        for (const skipped of result.skipped) {
          this.logger.pino.warn({ context: 'DfeService', branchId: branch.branch_id, nsu: skipped.nsu, reason: skipped.reason }, 'documento da Sefaz ignorado');
        }
        await this.handleDocuments(branch.branch_id, result.documents);
        const base = { status: result.status, message: result.message, ultNsu: result.lastNsu ?? lastNsu, maxNsu: result.maxNsu };
        // 138: chegou documento. Continua enquanto houver mais; acabando, espera a hora que a Sefaz pede.
        if (result.status === '138' && result.lastNsu && result.maxNsu && result.lastNsu < result.maxNsu) {
          lastNsu = result.lastNsu;
          continue;
        }
        if (result.status === '138' || result.status === '137' || result.status === '656') {
          await finish({ ...base, waitMinutes: HOUR });
        } else {
          await finish({ ...base, error: 'FA944', waitMinutes: HOUR });
        }
        return;
      }
      // Ainda há documentos: volta no próximo minuto.
      await finish({ status: '138', message: 'Documentos localizados', ultNsu: lastNsu, waitMinutes: 1 });
    } catch (error) {
      this.logger.pino.warn({ context: 'DfeService', branchId: branch.branch_id, err: error }, 'download da filial falhou');
      await finish({ ultNsu: lastNsu, error: codeOf(error), message: null, waitMinutes: 15 }).catch(() => undefined);
    }
  }

  /** Cada documento em transação própria: um com problema não derruba os outros. */
  private async handleDocuments(branchId: string, documents: DistDocument[]): Promise<void> {
    for (const document of documents) {
      try {
        await this.worker(async (client) => {
          const summary = document.schema.startsWith('resNFe') ? readSummary(document.xml) : null;
          const event = document.schema.startsWith('resEvento') || document.schema.startsWith('procEventoNFe') ? readEvent(document.xml) : null;
          const key = summary?.accessKey ?? event?.accessKey ?? /<chNFe>([0-9A-Z]{44})<\/chNFe>/.exec(document.xml)?.[1] ?? null;
          await client.query('SELECT app.dfe_store_document($1, $2, $3, $4, $5)', [
            branchId, document.nsu, document.schema, key, document.xml,
          ]);
        });
        // Processar de novo é inofensivo (resumo, importação e cancelamento conferem o que já existe),
        // e a consulta por chave pode devolver um documento que já tinha chegado pelo NSU.
        await this.processDocument(branchId, document);
      } catch (error) {
        this.logger.pino.warn({ context: 'DfeService', branchId, nsu: document.nsu, schema: document.schema, err: error }, 'documento da Sefaz não processado');
      }
    }
  }

  private async processDocument(branchId: string, document: DistDocument): Promise<void> {
    if (document.schema.startsWith('resNFe')) {
      const summary = readSummary(document.xml);
      if (!summary) throw new AppError('FA931', { cause: new Error('resumo inválido') });
      await this.worker((client) => client.query('SELECT app.dfe_record_summary($1, $2::jsonb)', [branchId, JSON.stringify(summary)]));
    } else if (document.schema.startsWith('procNFe')) {
      const data = readAuthorizedNfe(document.xml);
      if (data.environment !== sefazEnvironment()) throw new AppError('FA928');
      await this.worker((client) =>
        client.query('SELECT app.dfe_import_invoice($1, $2::jsonb, $3, $4, $5)', [
          branchId, JSON.stringify(data), document.xml, sha256(document.xml), sefazEnvironment() === 1,
        ]),
      );
    } else if (document.schema.startsWith('resEvento') || document.schema.startsWith('procEventoNFe')) {
      const event = readEvent(document.xml);
      if (event?.type === CANCELLATION_EVENT) {
        await this.worker((client) => client.query('SELECT app.dfe_record_cancellation($1, $2)', [branchId, event.accessKey]));
      }
    }
  }

  /** Consulta pela chave: confirmação das notas importadas à mão e XML das que tiveram ciência. */
  async runQueries(): Promise<void> {
    const queries = await this.worker(async (client) =>
      (await client.query<ClaimedQuery>('SELECT * FROM app.dfe_claim_queries($1::smallint, 10)', [sefazEnvironment()])).rows,
    );
    const endpoints = sefazEndpoints();
    for (const query of queries) {
      const ufCode = UF_CODES[query.state ?? ''];
      if (!ufCode) continue;
      try {
        const response = await postSoap(
          endpoints.distribution,
          DIST_ACTION,
          distributionEnvelope({ environment: sefazEnvironment(), ufCode, cnpj: query.cnpj, accessKey: query.access_key }),
          certificateOf(query),
          endpoints.ca,
        );
        const result = parseDistribution(response);
        if (result.status === '138' && result.documents.length > 0) {
          await this.handleDocuments(query.branch_id, result.documents);
        } else {
          await this.worker((client) =>
            client.query('SELECT app.dfe_record_query_failure($1, $2, $3, $4)', [query.branch_id, query.access_key, result.status, result.message]),
          );
        }
      } catch (error) {
        this.logger.pino.warn({ context: 'DfeService', branchId: query.branch_id, err: error }, 'consulta por chave falhou');
      }
    }
  }

  /** NFS-e pelo Ambiente de Dados Nacional: mesma chave, mesma rotina, NSU próprio. */
  async syncServiceInvoices(): Promise<void> {
    const branches = await this.worker(async (client) =>
      (await client.query<ClaimedNfseBranch>('SELECT * FROM app.dfe_claim_nfse_branches(10)')).rows,
    );
    for (const branch of branches) {
      await this.syncServiceBranch(branch);
    }
  }

  private async syncServiceBranch(branch: ClaimedNfseBranch): Promise<void> {
    const finish = (result: Record<string, unknown>) =>
      this.worker((client) => client.query('SELECT app.dfe_finish_nfse_branch($1, $2::jsonb)', [branch.branch_id, JSON.stringify(result)]));
    let lastNsu = branch.last_nsu;
    try {
      const certificate = certificateOf(branch);
      const endpoints = sefazEndpoints();
      for (let page = 0; page < MAX_PAGES; page += 1) {
        if (page > 0) await pause(ADN_PAUSE_MS);
        const response = await httpsCall(
          nfseDistributionUrl(endpoints.nfse, lastNsu, branch.cnpj),
          { method: 'GET', headers: { Accept: 'application/json' } },
          certificate,
          endpoints.ca,
        );
        const result = parseNfseDistribution(response.status, response.body);
        for (const skipped of result.skipped) {
          this.logger.pino.warn({ context: 'DfeService', branchId: branch.branch_id, nsu: skipped.nsu, reason: skipped.reason }, 'documento do ADN ignorado');
        }
        if (result.rejected) {
          await finish({ status: result.status, message: result.message, lastNsu, error: 'FA948', waitMinutes: HOUR });
          return;
        }
        await this.handleServiceDocuments(branch.branch_id, result.documents);
        const advanced = result.lastNsu !== null && result.lastNsu > lastNsu;
        if (advanced) lastNsu = result.lastNsu as string;
        // Lote cheio: pode haver mais. Lote menor, vazio ou sem avanço: acabou, volta em uma hora.
        if (advanced && result.documents.length + result.skipped.length >= NFSE_BATCH_SIZE) continue;
        await finish({ status: result.status, message: result.message, lastNsu, waitMinutes: HOUR });
        return;
      }
      await finish({ status: 'DOCUMENTOS_LOCALIZADOS', message: null, lastNsu, waitMinutes: 1 });
    } catch (error) {
      this.logger.pino.warn({ context: 'DfeService', branchId: branch.branch_id, err: error }, 'download de NFS-e da filial falhou');
      await finish({ lastNsu, error: codeOf(error), message: null, waitMinutes: 15 }).catch(() => undefined);
    }
  }

  /** Cada documento em transação própria; processar de novo é inofensivo. */
  private async handleServiceDocuments(branchId: string, documents: NfseDocument[]): Promise<void> {
    for (const document of documents) {
      try {
        const documentId = await this.worker(async (client) => {
          const { rows } = await client.query<{ id: string }>(
            'SELECT app.dfe_store_nfse_document($1, $2, $3, $4, $5) AS id',
            [branchId, document.nsu, document.type, document.accessKey, document.xml],
          );
          return rows[0].id;
        });
        if (document.type === 'NFSE') {
          const data = readServiceInvoice(document.xml);
          await this.worker((client) =>
            client.query('SELECT app.nfse_record_invoice($1, $2, $3::jsonb)', [branchId, documentId, JSON.stringify(data)]),
          );
        } else if (document.type === 'EVENTO') {
          const event = readServiceEvent(document.xml, document.accessKey);
          if (event && event.kind !== 'other') {
            await this.worker((client) =>
              client.query('SELECT app.nfse_record_event($1, $2, $3, $4)', [branchId, event.accessKey, event.kind, event.substituteKey]),
            );
          }
        }
      } catch (error) {
        this.logger.pino.warn({ context: 'DfeService', branchId, nsu: document.nsu, type: document.type, err: error }, 'documento do ADN não processado');
      }
    }
  }

  /** Ciência da operação pedida na tela. Duas transações curtas, com a Sefaz no meio. */
  async giveAwareness(summaryId: string): Promise<{ protocol: string | null }> {
    const target = await this.database.withContext(async (client) => {
      const { rows } = await client.query<SealedCertificate & { access_key: string; cnpj: string; state: string | null }>(
        'SELECT * FROM app.awareness_target($1)',
        [summaryId],
      );
      return rows[0];
    });
    const certificate = certificateOf(target);
    const endpoints = sefazEndpoints();
    const response = await postSoap(
      endpoints.event,
      EVENT_ACTION,
      awarenessEnvelope(
        { environment: sefazEnvironment(), cnpj: target.cnpj, accessKey: target.access_key },
        pemFromPfx(certificate.pfx, certificate.passphrase),
      ),
      certificate,
      endpoints.ca,
    );
    const result = parseEventResponse(response);
    if (!result.registered) {
      throw new AppError('FA945', { cause: new Error(`cStat ${result.status}: ${result.message}`) });
    }
    await this.database.withContext((client) => client.query('SELECT app.record_awareness($1, $2)', [summaryId, result.protocol]));
    return { protocol: result.protocol };
  }
}
