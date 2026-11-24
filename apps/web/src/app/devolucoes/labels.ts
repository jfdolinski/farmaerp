// Textos das devoluções, usados na lista, no detalhe e na venda.

export const DESTINATION_LABELS: Record<string, string> = {
  credit: "Crédito para nova compra",
  agreement: "Abatimento na fatura do convênio",
  cash: "Dinheiro ao cliente",
};

/** Situação do valor devolvido: em dinheiro, pago pela sangria ou esperando. */
export function payoutText(destination: string, paid: boolean): string {
  if (destination === "cash") return paid ? "Pago na sangria" : "Esperando a sangria";
  if (destination === "credit") return "Crédito aberto";
  return "Abater na próxima fatura";
}
