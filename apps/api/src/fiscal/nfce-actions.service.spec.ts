import { describe, expect, it } from 'vitest';
import type { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import type { AppLogger } from '../observability/app-logger.js';
import { type DocumentContext, failureResult, NfceActionsService } from './nfce-actions.service.js';

describe('falhas do reenvio automático', () => {
  it('certificado, UF e ambiente viram aviso (saem do lote); o resto tenta na próxima hora', () => {
    expect(failureResult(new AppError('FA943'))).toEqual({ kind: 'blocked', reason: 'A filial não tem certificado digital válido. (FA943)' });
    expect(failureResult(new AppError('FA754'))).toMatchObject({ kind: 'blocked', reason: expect.stringContaining('(FA754)') });
    expect(failureResult(new AppError('FA753'))).toMatchObject({ kind: 'blocked', reason: expect.stringContaining('(FA753)') });
    expect(failureResult(new AppError('FA944'))).toEqual({ kind: 'unavailable', reason: 'Falha FA944.' });
    expect(failureResult(new Error('qualquer'))).toEqual({ kind: 'unavailable', reason: 'Falha FA944.' });
  });

  it('filial sem certificado: a tentativa para com FA943 antes de chamar a Sefaz', async () => {
    const service = new NfceActionsService({} as DatabaseService, {} as AppLogger);
    const context = {
      id: 'x', branch_id: 'b', sale_id: 's', company_id: 'c', status: 'contingency', access_key: '3'.repeat(44), environment: 2,
      protocol: null, xml: '<NFe/>', authorized_at: null, cnpj: '11222333000181', state: 'SP', encrypted_pfx: null, encrypted_password: null,
    } as DocumentContext;
    await expect(service.settle(context)).rejects.toMatchObject({ code: 'FA943' });
  });
});
