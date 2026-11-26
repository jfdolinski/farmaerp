// Arquivo da remessa do SNGPC.
// LAYOUT PROVISÓRIO: segue a estrutura do SNGPC atual (mensagem com cabeçalho e corpo; inventário,
// entradas e saídas com MS, lote e quantidade; receita, prescritor e comprador na venda). Antes de
// ligar o envio real (SNGPC_LIVE=true), confira campo a campo com a documentação oficial da API nova
// da Anvisa e ajuste só este arquivo.

export interface SubmissionMovement {
  id: string;
  kind: string;
  reported_on: string;
  quantity: number | string;
  ms_registration: string;
  batch_number: string;
  expires_on: string | null;
  product_name: string;
  controlled_class: string | null;
  loss_code: string | null;
  counterpart_cnpj: string | null;
  invoice_number: number | string | null;
  prescription: Record<string, string | number | null> | null;
}

export interface SubmissionData {
  id: string;
  kind: 'inventory' | 'movements';
  period_start: string;
  period_end: string;
  branch: { id: string; name: string; cnpj: string };
  movements: SubmissionMovement[];
}

type Value = string | number | null | undefined;

const escape = (value: Value) =>
  String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

const tag = (name: string, value: Value) => `<${name}>${escape(value)}</${name}>`;
const optional = (name: string, value: Value) => (value === null || value === undefined || value === '' ? '' : tag(name, value));
const day = (value: Value) => String(value ?? '').slice(0, 10);
const quantity = (value: number | string) => String(Number(value));

/** Tipo de receituário (códigos do SNGPC atual; conferir com a documentação nova). */
const PRESCRIPTION_CODE: Record<string, string> = {
  special_control: '1',
  notification_b: '2',
  notification_a: '3',
  antimicrobial: '5',
  notification_b2: '2',
  notification_retinoid: '4',
  notification_thalidomide: '4',
};
const DOCUMENT_CODE: Record<string, string> = { rg: '1', cpf: '2', cnh: '3', passport: '4', other: '9' };

function medicine(m: SubmissionMovement): string {
  return (
    tag('registroMSMedicamento', m.ms_registration) +
    tag('numeroLoteMedicamento', m.batch_number) +
    tag('quantidadeMedicamento', quantity(m.quantity)) +
    tag('unidadeMedidaMedicamento', '1')
  );
}

function movement(m: SubmissionMovement): string {
  switch (m.kind) {
    case 'inventory':
      return `<medicamentoInventario>${medicine(m)}</medicamentoInventario>`;
    case 'purchase':
    case 'transfer_in':
    case 'return_in':
      return (
        `<entradaMedicamento>${tag('tipoOperacao', m.kind === 'purchase' ? '1' : m.kind === 'transfer_in' ? '2' : '3')}` +
        optional('numeroNotaFiscal', m.invoice_number) +
        optional('cnpjOrigem', m.counterpart_cnpj) +
        tag('dataRecebimento', day(m.reported_on)) +
        `${medicine(m)}</entradaMedicamento>`
      );
    case 'sale': {
      const p = m.prescription ?? {};
      return (
        `<saidaMedicamentoVendaAoConsumidor>` +
        tag('tipoReceituario', PRESCRIPTION_CODE[String(p.type)] ?? '1') +
        optional('numeroNotificacao', p.number) +
        tag('dataPrescricao', day(p.date)) +
        `<prescritor>${tag('nomePrescritor', p.prescriber_name)}${tag('numeroRegistroProfissional', p.prescriber_number)}` +
        `${tag('conselhoProfissional', p.prescriber_council)}${tag('UFConselho', p.prescriber_state)}</prescritor>` +
        `<comprador>${tag('nomeComprador', p.buyer_name)}${tag('tipoDocumento', DOCUMENT_CODE[String(p.buyer_document_type)] ?? '9')}` +
        `${tag('numeroDocumento', p.buyer_document)}${tag('orgaoExpedidor', p.buyer_issuer)}${tag('UFEmissaoDocumento', p.buyer_state)}</comprador>` +
        (p.patient_name || p.patient_age !== null
          ? `<paciente>${optional('nome', p.patient_name)}${optional('idade', p.patient_age)}${optional('sexo', p.patient_sex)}</paciente>`
          : '') +
        tag('dataVenda', day(m.reported_on)) +
        `${medicine(m)}</saidaMedicamentoVendaAoConsumidor>`
      );
    }
    case 'transfer_out':
      return (
        `<saidaMedicamentoTransferencia>${optional('cnpjDestino', m.counterpart_cnpj)}` +
        `${tag('dataTransferencia', day(m.reported_on))}${medicine(m)}</saidaMedicamentoTransferencia>`
      );
    default:
      // Perda (e ajuste de saída conferido como perda).
      return (
        `<saidaMedicamentoPerda>${tag('motivoPerda', m.loss_code ?? '5')}` +
        `${tag('dataPerda', day(m.reported_on))}${medicine(m)}</saidaMedicamentoPerda>`
      );
  }
}

/** Monta o arquivo. A ordem das movimentações já vem do banco (data, inventário, entradas, saídas). */
export function buildSubmissionXml(data: SubmissionData, transmitterCpf: string): string {
  const root = data.kind === 'inventory' ? 'mensagemSNGPCInventario' : 'mensagemSNGPC';
  const header =
    `<cabecalho>${tag('cnpjEmissor', data.branch.cnpj)}${optional('cpfTransmissor', /^\d{11}$/.test(transmitterCpf) ? transmitterCpf : '')}` +
    `${tag('dataInicio', day(data.period_start))}${tag('dataFim', day(data.period_end))}</cabecalho>`;
  const body = data.movements.map(movement).join('');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<${root} xmlns="urn:sngpc-schema">${header}<corpo>${body}</corpo></${root}>\n`;
}
