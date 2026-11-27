import { randomInt } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { buildNfe, type NfeInput } from '@farmaerp/fiscal-js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { ACTIONS, authorizationEnvelope, parseAuthorization } from '../sefaz/nfce-sefaz.js';
import { nfeAuthorizationUrl } from '../sefaz/nfe-sefaz.js';
import { sefazEndpoints, sefazEnvironment } from '../sefaz/sefaz-config.js';
import { ClientCertificate, postSoap } from '../sefaz/soap.js';
import { signingMaterial } from './certificate.js';
import { open } from './secret-box.js';

interface Prepared {
  returnId: string;
  state: string | null;
  series: number;
  number: number;
  totalValue: number;
  input: Omit<NfeInput, 'emittedAt' | 'environment' | 'numericCode' | 'appVersion'>;
}

interface Sealed {
  company_id: string;
  encrypted_pfx: Buffer | null;
  encrypted_password: Buffer | null;
}

export type CentralNfeStatus = 'pending' | 'authorized' | 'rejected';

/**
 * NF-e modelo 55 emitida pela central (começando pela devolução ao fornecedor). Monta e assina com o
 * mesmo motor do PDV, guarda a nota pendente com o número reservado e transmite à Sefaz da UF. Sem
 * resposta, a nota fica pendente e pode ser transmitida de novo com o mesmo XML.
 */
@Injectable()
export class CentralNfeService {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
  ) {}

  private certificate(row: Sealed | undefined): ClientCertificate {
    if (!row?.encrypted_pfx || !row.encrypted_password) throw new AppError('FA943');
    const context = `certificate:${row.company_id}`;
    return { pfx: open(row.encrypted_pfx, context), passphrase: open(row.encrypted_password, context).toString('utf8') };
  }

  /** Emite a NF-e da devolução (ou transmite de novo a que ficou pendente). */
  async emitReturn(returnId: string): Promise<{ id: string; status: CentralNfeStatus }> {
    const environment = sefazEnvironment();
    // Já existe pendente: só transmite de novo.
    const pending = await this.database.withContext(async (client) =>
      (await client.query<{ id: string; xml: string; state: string; environment: number }>('SELECT * FROM app.return_nfe_pending($1)', [returnId])).rows[0],
    );
    if (pending) return { id: pending.id, status: await this.transmit(returnId, pending.id, pending.xml, pending.state, pending.environment) };

    // Monta, assina e guarda na mesma transação que reserva o número: se algo falhar, o número volta.
    const created = await this.database.withContext(async (client) => {
      const prepared = (await client.query<{ x: Prepared }>('SELECT app.return_nfe_prepare($1) AS x', [returnId])).rows[0].x;
      const sealed = (await client.query<Sealed>('SELECT * FROM app.return_nfe_certificate($1)', [returnId])).rows[0];
      const certificate = this.certificate(sealed);
      // Chave em PKCS#8, como o motor (o mesmo do caixa) espera.
      const pem = signingMaterial(certificate.pfx, certificate.passphrase);
      const emittedAt = new Date().toISOString();
      const nfe = buildNfe(
        { ...prepared.input, emittedAt, environment, numericCode: String(randomInt(10_000_000, 99_999_999)), appVersion: 'central' },
        pem.privateKey,
        pem.certificate,
      );
      if (nfe.error) {
        // O código vai para a tela; o detalhe técnico só para o log.
        this.logger.pino.warn({ context: 'CentralNfeService', returnId, code: nfe.error.code, detail: nfe.error.detail }, 'NF-e da devolução não montou');
        throw new AppError(nfe.error.code);
      }
      const id = (
        await client.query<{ id: string }>('SELECT app.return_nfe_store($1, $2, $3, $4, $5, $6, $7, $8) AS id', [
          returnId, prepared.series, prepared.number, nfe.accessKey, environment, nfe.xml, emittedAt, nfe.totalCents / 100,
        ])
      ).rows[0].id;
      return { id, xml: nfe.xml, state: prepared.state };
    });
    return { id: created.id, status: await this.transmit(returnId, created.id, created.xml, created.state, environment) };
  }

  private async transmit(returnId: string, id: string, xml: string, state: string | null, environment: number): Promise<CentralNfeStatus> {
    if (environment !== sefazEnvironment()) throw new AppError('FA753', { cause: new Error('ambiente da nota diferente do da central') });
    const url = state ? nfeAuthorizationUrl(state, environment as 1 | 2) : null;
    if (!url) throw new AppError('FA754', { cause: new Error(`UF ${state ?? '?'} sem serviço da NF-e`) });
    const sealed = await this.database.withContext(async (client) =>
      (await client.query<Sealed>('SELECT * FROM app.return_nfe_certificate($1)', [returnId])).rows[0],
    );
    let outcome: Record<string, unknown>;
    try {
      const response = await postSoap(url, ACTIONS.authorization, authorizationEnvelope(xml, String(Date.now()).slice(-15)), this.certificate(sealed), sefazEndpoints().ca);
      const result = parseAuthorization(response, xml);
      outcome = result.kind === 'authorized'
        ? { kind: 'authorized', protocol: result.protocol, authorized_at: result.authorizedAt, xml: result.procXml, status_code: result.status, reason: result.reason }
        : result.kind === 'rejected'
          ? { kind: 'rejected', status_code: result.status, reason: result.reason }
          // Duplicidade (204) e serviço parado: continua pendente; a próxima tentativa resolve.
          : { kind: 'unavailable', reason: `${result.status} ${result.reason}` };
    } catch (error) {
      if (error instanceof AppError && error.code !== 'FA944') throw error;
      this.logger.pino.warn({ context: 'CentralNfeService', documentId: id, code: 'FA944', err: error }, 'Sefaz sem resposta na NF-e da central');
      outcome = { kind: 'unavailable', reason: 'Sem resposta da Sefaz' };
    }
    return this.database.withContext(async (client) =>
      (await client.query<{ s: CentralNfeStatus }>('SELECT app.central_nfe_result($1, $2::jsonb) AS s', [id, JSON.stringify(outcome)])).rows[0].s,
    );
  }
}
