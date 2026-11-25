// Textos das vendas, usados na lista e no detalhe.

export const PAYMENT_LABELS: Record<string, string> = {
  cash: "Dinheiro",
  credit_card: "Cartão de crédito",
  debit_card: "Cartão de débito",
  pix: "PIX",
  agreement: "Convênio",
  return_credit: "Crédito de devolução",
  store_credit: "Crediário",
  return: "Devolução",
};

export const FISCAL_LABELS: Record<string, string> = {
  pending: "Nota pendente de emissão",
};

export const ALERT_LABELS: Record<string, string> = {
  price_divergence: "Preço diferente do da central",
  discount_above_rule: "Desconto acima do máximo do produto",
  discount_above_limit: "Desconto acima do limite, sem liberação válida",
  operator_permission: "Operador sem permissão de venda",
  negative_stock: "Estoque ficou negativo",
  product_status: "Produto não estava ativo na filial",
  agreement_link: "Convênio sem o cliente vinculado",
  offline_zero_stock: "Vendido sem estoque com o PDV sem internet",
  controlled_missing: "Controlado vendido sem os dados da receita",
  controlled_release: "Controlado liberado por quem não tinha a permissão",
  controlled_pending: "Controlado vendido com estoque negativo, pendente de dados para o SNGPC",
  prescription_expired: "Receita vencida ou com data no futuro",
  prescription_type: "Tipo de receita diferente do exigido pela lista do produto",
  seller_permission: "Vendedor sem permissão de orçar ou vender na filial",
  quote_status: "Venda de orçamento que já não estava aberto",
  return_permission: "Devolução feita sem a permissão",
  return_credit: "Crédito de devolução usado sem saldo ou fora das regras",
  auto_discount: "Desconto automático acima do que as regras davam",
  credit_limit: "Crediário acima do limite disponível",
  credit_blocked: "Crediário bloqueado",
  credit_overdue: "Crediário com parcela em atraso além do prazo",
  credit_schedule: "Parcelas do crediário diferentes do cálculo da central",
  credit_dependent: "Dependente sem autorização no crediário",
  credit_release: "Crediário acima do limite do operador, sem liberação válida",
};

export const brl = (value: number | string | null) =>
  value === null ? "—" : Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

export const dateTimeText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

/** Explicação curta do alerta, com os números que ele trouxe. */
export function alertText(kind: string, detail: Record<string, unknown>): string {
  const label = ALERT_LABELS[kind] ?? kind;
  const percent = (value: unknown) =>
    value === null || value === undefined
      ? "sem teto"
      : `${Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 1 })}%`;
  switch (kind) {
    case "price_divergence":
      return `${label}: PDV ${brl(detail.pdv_price as number)}, central ${brl((detail.central_price as number) ?? null)}.`;
    case "discount_above_rule":
      return `${label}: ${percent(detail.percent)} com máximo de ${percent(detail.rule_max)}.`;
    case "discount_above_limit":
      return `${label}: ${percent(detail.percent)}, limite do operador ${percent(detail.operator_limit)}.`;
    case "offline_zero_stock":
      return `${label}: ${detail.minutes_offline} min sem sincronizar${detail.supervisor_allowed ? ", autorizado pelo gerente" : ", autorizado por quem não tinha a permissão"}.`;
    case "quote_status": {
      const reasons: Record<string, string> = {
        converted: "já tinha virado outra venda",
        replaced: "a plaquinha tinha ido para outro orçamento",
        expired: "estava vencido",
        cancelled: "estava cancelado",
        other_branch: "é de outra loja",
      };
      return `Orçamento ${detail.quote_code}: ${reasons[detail.status as string] ?? detail.status}.`;
    }
    case "return_permission":
      return `${label}: ${detail.return_code}${detail.late ? ", fora do prazo da loja e sem a liberação de outra pessoa" : ", sem a permissão nem a liberação de quem tem"}.`;
    case "auto_discount":
      return `${label}: o PDV deu ${brl(detail.pdv_discount as number)}, as regras davam ${brl(detail.expected_discount as number)}.`;
    case "return_credit": {
      const problems: Record<string, string> = {
        balance: `passou do saldo (${brl(detail.balance as number)})`,
        not_credit: "o documento não é de crédito",
        other_branch: "o documento é de outra loja",
      };
      return `${label}: ${detail.return_code}, ${problems[detail.problem as string] ?? detail.problem}.`;
    }
    case "credit_limit":
      return `${label}: ${brl(detail.amount as number)} com ${brl(detail.available as number)} disponível (limite ${brl(detail.credit_limit as number)}).`;
    case "credit_release":
      return `${label}: ${brl(detail.amount as number)}, limite do operador ${brl(detail.operator_limit as number)}${detail.released_by ? `, quem liberou tinha ${brl((detail.releaser_limit as number) ?? null)}` : ""}.`;
    case "credit_overdue":
      return `${label}: ${detail.overdue_days} dias de atraso, bloqueio depois de ${detail.block_after_days}.`;
    case "negative_stock":
      return `${label}: saldo ${Number(detail.balance).toLocaleString("pt-BR")}.`;
    default:
      return `${label}.`;
  }
}
