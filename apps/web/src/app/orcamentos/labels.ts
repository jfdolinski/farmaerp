// Textos dos orçamentos, usados na lista e no detalhe.

export const QUOTE_STATUS_LABELS: Record<string, string> = {
  open: "Aberto",
  converted: "Virou venda",
  replaced: "Substituído",
  expired: "Vencido",
  cancelled: "Cancelado",
};

/** Filtro da URL (em português) para a situação da API. */
export const QUOTE_FILTERS = {
  todos: "all",
  abertos: "open",
  convertidos: "converted",
  substituidos: "replaced",
  vencidos: "expired",
} as const;
export type QuoteFilter = keyof typeof QUOTE_FILTERS;
