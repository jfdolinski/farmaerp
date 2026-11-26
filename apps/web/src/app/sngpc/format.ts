export interface SngpcMovement {
  id: string;
  kind: string;
  status: string;
  status_reason: string | null;
  reported_on: string;
  occurred_at: string;
  product_id: string;
  product_code: number;
  product_name: string;
  controlled_class: string | null;
  batch_id: string | null;
  batch_number: string | null;
  expires_on: string | null;
  ms_registration: string | null;
  quantity: string;
  loss_reason: string | null;
  origin_batch: boolean;
  counterpart: string | null;
  dispensing_status: "complete" | "pending" | "complemented" | null;
  prescription: string | null;
  buyer: string | null;
  send_on: string | null;
  confirmed_by_name: string | null;
  confirmed_at: string | null;
}

export interface SngpcBatch {
  id: string;
  batch_number: string;
  expires_on: string;
  ms_registration: string | null;
  quantity: string;
}

export interface SngpcProblem {
  movement_id: string;
  problem: string;
  suggested_on: string | null;
  balance: number | null;
}

export const KIND: Record<string, string> = {
  inventory: "Inventário inicial",
  purchase: "Entrada por compra",
  transfer_in: "Entrada por transferência",
  return_in: "Entrada por devolução",
  adjustment_in: "Ajuste de entrada",
  sale: "Venda",
  transfer_out: "Saída por transferência",
  loss: "Perda",
  adjustment_out: "Ajuste de saída",
};

export const LOSS_REASON: Record<string, string> = {
  theft: "Furto ou roubo",
  damage: "Avaria",
  expired: "Vencimento",
  seized: "Apreensão ou recolhimento pela Vigilância",
  quality_sample: "Amostra para controle de qualidade",
  recall: "Recolhimento pelo fabricante",
  other: "Outro",
};

export const PRESCRIPTION_TYPE: Record<string, string> = {
  notification_a: "Notificação A (amarela)",
  notification_b: "Notificação B (azul)",
  notification_b2: "Notificação B2",
  notification_retinoid: "Notificação de retinoide",
  notification_thalidomide: "Notificação de talidomida",
  special_control: "Receita de controle especial",
  antimicrobial: "Receita de antimicrobiano",
};

/** O que falta, em palavras do farmacêutico. */
export function problemText(problem: SngpcProblem): string {
  switch (problem.problem) {
    case "not_pending":
      return "Já não está pendente. Atualize a tela.";
    case "inventory_pending":
      return "Confira primeiro o inventário inicial da filial.";
    case "missing_batch":
      return "Falta o lote.";
    case "missing_ms":
      return "O lote está sem o registro no Ministério da Saúde (MS). Corrija o lote no estoque.";
    case "missing_prescription":
      return "Venda liberada sem receita: preencha os dados da receita.";
    case "missing_loss_reason":
      return "Informe o motivo da perda.";
    case "adjustment_in":
      return "Entrada por ajuste não existe no SNGPC: deixe fora com o motivo.";
    case "date_future":
      return "A data está no futuro.";
    case "date_before_start":
      return `A data é anterior à abertura do SNGPC na filial. Use ${dayText(problem.suggested_on)} ou depois.`;
    case "earlier_pending":
      return "Há movimentação anterior deste produto ainda pendente: confira na ordem.";
    case "out_before_entry":
      return problem.suggested_on
        ? `A saída fica antes da entrada do lote. Use ${dayText(problem.suggested_on)} ou depois.`
        : "O lote não tem entrada conferida antes desta saída.";
    case "negative_balance":
      return `O saldo do lote ficaria negativo (${Number(problem.balance ?? 0).toLocaleString("pt-BR")}).`;
    default:
      return problem.problem;
  }
}

/** AAAA-MM-DD para DD/MM/AAAA. */
export const dayText = (value: string | null | undefined) => (value ? value.slice(0, 10).split("-").reverse().join("/") : "");

export const quantityText = (value: string | number) => Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

export const todayText = () => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date());

/** "notification_b SP-1 de 10/11/2026" com o nome do tipo de receita. */
export const prescriptionText = (value: string | null) => {
  if (!value) return "";
  const [type, ...rest] = value.split(" ");
  return `${PRESCRIPTION_TYPE[type] ?? type} ${rest.join(" ")}`.trim();
};
