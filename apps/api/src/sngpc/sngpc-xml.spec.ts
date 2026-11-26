import { describe, expect, it } from 'vitest';
import { sngpcEndpoint } from './sngpc-gateway.js';
import { buildSubmissionXml, SubmissionData, SubmissionMovement } from './sngpc-xml.js';

const base: Omit<SubmissionMovement, 'kind'> = {
  id: 'm', reported_on: '2026-11-20', quantity: '2.000', ms_registration: '1000000000004', batch_number: 'L<1>',
  expires_on: '2030-01-31', product_name: 'Clonazepam', controlled_class: 'B1', loss_code: null, counterpart_cnpj: null,
  invoice_number: null, prescription: null,
};
const data = (kind: SubmissionData['kind'], movements: SubmissionMovement[]): SubmissionData => ({
  id: 's', kind, period_start: '2026-11-20', period_end: '2026-11-21',
  branch: { id: 'b', name: 'Loja', cnpj: '11222333000181' }, movements,
});

describe('arquivo do SNGPC', () => {
  it('inventário: mensagem própria, cabeçalho e lote com o texto escapado', () => {
    const xml = buildSubmissionXml(data('inventory', [{ ...base, kind: 'inventory' }]), '12345678901');
    expect(xml).toContain('<mensagemSNGPCInventario xmlns="urn:sngpc-schema">');
    expect(xml).toContain('<cabecalho><cnpjEmissor>11222333000181</cnpjEmissor><cpfTransmissor>12345678901</cpfTransmissor>');
    expect(xml).toContain('<dataInicio>2026-11-20</dataInicio><dataFim>2026-11-21</dataFim>');
    expect(xml).toContain('<medicamentoInventario><registroMSMedicamento>1000000000004</registroMSMedicamento><numeroLoteMedicamento>L&lt;1&gt;</numeroLoteMedicamento><quantidadeMedicamento>2</quantidadeMedicamento>');
  });

  it('movimentações na ordem que vieram, com receita, prescritor e comprador na venda', () => {
    const xml = buildSubmissionXml(data('movements', [
      { ...base, kind: 'purchase', counterpart_cnpj: '33444555000166', invoice_number: 123 },
      { ...base, kind: 'sale', prescription: {
        type: 'notification_b', number: 'SP-1', date: '2026-11-19', prescriber_name: 'Dra. Ana & Cia', prescriber_number: '123',
        prescriber_council: 'CRM', prescriber_state: 'SP', buyer_name: 'João', buyer_document_type: 'rg', buyer_document: '12.345',
        buyer_issuer: 'SSP', buyer_state: 'SP', patient_name: null, patient_age: null, patient_sex: null,
      } },
      { ...base, kind: 'loss', loss_code: '2' },
      { ...base, kind: 'transfer_out', counterpart_cnpj: '11222333000262' },
    ]), 'usuario-sem-cpf');
    expect(xml).toContain('<mensagemSNGPC xmlns="urn:sngpc-schema">');
    expect(xml).not.toContain('cpfTransmissor');
    const order = ['<entradaMedicamento>', '<saidaMedicamentoVendaAoConsumidor>', '<saidaMedicamentoPerda>', '<saidaMedicamentoTransferencia>']
      .map((t) => xml.indexOf(t));
    expect(order.every((index, i) => index > 0 && (i === 0 || index > order[i - 1]))).toBe(true);
    expect(xml).toContain('<tipoOperacao>1</tipoOperacao><numeroNotaFiscal>123</numeroNotaFiscal><cnpjOrigem>33444555000166</cnpjOrigem>');
    expect(xml).toContain('<tipoReceituario>2</tipoReceituario><numeroNotificacao>SP-1</numeroNotificacao><dataPrescricao>2026-11-19</dataPrescricao>');
    expect(xml).toContain('<nomePrescritor>Dra. Ana &amp; Cia</nomePrescritor>');
    expect(xml).not.toContain('<paciente>');
    expect(xml).toContain('<motivoPerda>2</motivoPerda>');
    expect(xml).toContain('<cnpjDestino>11222333000262</cnpjDestino>');
  });

  it('envio real só com SNGPC_LIVE e endereço HTTPS fora do desenvolvimento', () => {
    expect(sngpcEndpoint({ APP_ENV: 'development', SNGPC_URL: 'http://localhost:9000' })).toBeNull();
    expect(sngpcEndpoint({ APP_ENV: 'development', SNGPC_LIVE: 'true', SNGPC_URL: 'http://localhost:9000/' })).toBe('http://localhost:9000');
    expect(sngpcEndpoint({ APP_ENV: 'homologation', SNGPC_LIVE: 'true', SNGPC_URL: 'http://anvisa.test' })).toBeNull();
    expect(sngpcEndpoint({ APP_ENV: 'production', SNGPC_LIVE: 'true', SNGPC_URL: 'https://anvisa.test' })).toBe('https://anvisa.test');
  });
});
