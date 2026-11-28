import { Inject, Injectable } from '@nestjs/common';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { AppLogger } from '../observability/app-logger.js';
import { EventContext, NfceActionsService } from './nfce-actions.service.js';

/** Nota da carta: a NF-e de venda (emitida no caixa) ou a da central (devolução ou transferência). */
export type CorrectionKind = 'sale' | 'central';

/** Texto da carta numa linha só: quebras e espaços repetidos viram um espaço (o banco confere o resto). */
export const correctionText = (value: string) => value.replace(/\s+/g, ' ').trim();

/**
 * Carta de correção (CC-e) da NF-e 55 pela retaguarda: o banco diz se a nota aceita, qual a próxima
 * sequência e guarda a carta registrada; a Sefaz registra o evento assinado com o certificado da filial.
 */
@Injectable()
export class NfeCorrectionService {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(AppLogger) private readonly logger: AppLogger,
    @Inject(NfceActionsService) private readonly actions: NfceActionsService,
  ) {}

  async send(kind: CorrectionKind, id: string, text: string): Promise<{ id: string; sequence: number; status: string; sefaz: string }> {
    const context = await this.database.withContext(async (client) =>
      (await client.query<EventContext & { sequence: number }>('SELECT * FROM app.nfe_correction_context($1, $2, $3)', [kind, id, text])).rows[0],
    );
    const result = await this.actions.sendCorrection(context, context.sequence, text);
    const correctionId = await this.database.withContext(async (client) =>
      (await client.query<{ id: string }>('SELECT app.nfe_correction_register($1, $2, $3::jsonb) AS id', [kind, id, JSON.stringify({
        sequence: result.sequence, correction: result.text, protocol: result.protocol, status_code: result.status, xml: result.xml,
        registered_at: result.registeredAt,
      })])).rows[0].id,
    );
    this.logger.pino.info({ context: 'NfeCorrectionService', kind, documentId: id, sequence: result.sequence }, 'carta de correção registrada');
    // A Sefaz já tinha outra carta com essa sequência (outro envio ao mesmo tempo): ela fica registrada aqui, e a
    // pessoa confere antes de mandar de novo.
    if (result.text !== text) throw new AppError('FA791', { detail: `Sequência ${result.sequence} já registrada com outro texto.` });
    return { id: correctionId, sequence: result.sequence, status: result.status, sefaz: result.sefaz };
  }
}
