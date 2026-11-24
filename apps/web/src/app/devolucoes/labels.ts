// Textos das devoluções, usados na lista, no detalhe e na venda.

export const DESTINATION_LABELS: Record<string, string> = {
  credit: "Crédito para nova compra",
  agreement: "Abatimento na fatura do convênio",
  cash: "Dinheiro ao cliente",
};

/** Filtro da URL (em português) para o destino da API. */
export const DESTINATION_FILTERS = { todos: "all", credito: "credit", convenio: "agreement", dinheiro: "cash" } as const;
export type DestinationFilter = keyof typeof DESTINATION_FILTERS;

const money = (value: number) => value.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

/** Situação do valor devolvido: em dinheiro, pago pela sangria ou esperando; crédito, o saldo. */
export function payoutText(destination: string, paid: boolean, total?: number, creditUsed?: number | null): string {
  if (destination === "cash") return paid ? "Pago na sangria" : "Esperando a sangria";
  if (destination === "credit") {
    if (total === undefined || creditUsed === undefined || creditUsed === null) return "Crédito aberto";
    const balance = total - creditUsed;
    return balance <= 0 ? "Crédito usado" : `Saldo de ${money(balance)}`;
  }
  return "Abater na próxima fatura do convênio";
}
