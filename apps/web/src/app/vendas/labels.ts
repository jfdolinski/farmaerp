// Textos das vendas, usados na lista e no detalhe.

export const PAYMENT_LABELS: Record<string, string> = {
  cash: "Dinheiro",
  credit_card: "Cartão de crédito",
  debit_card: "Cartão de débito",
  pix: "PIX",
  agreement: "Convênio",
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
    case "negative_stock":
      return `${label}: saldo ${Number(detail.balance).toLocaleString("pt-BR")}.`;
    default:
      return `${label}.`;
  }
}
