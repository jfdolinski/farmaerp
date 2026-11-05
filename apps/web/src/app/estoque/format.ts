// Fica fora dos componentes de cliente porque as páginas do servidor também usam estes textos.

export interface BalanceRow {
  balance_id: string;
  branch_id: string;
  branch_name: string;
  product_id: string;
  product_code: string;
  product_name: string;
  batch_id: string | null;
  batch_number: string | null;
  expires_on: string | null;
  ms_registration: string | null;
  ms_original: string | null;
  base_ms: string | null;
  quantity: string;
  is_expired: boolean;
  days_to_expire: number | null;
  ms_diverges: boolean;
  needs_batch: boolean;
}

export const MOVEMENT_LABELS: Record<string, string> = {
  invoice: "Nota",
  sale: "Venda",
  return: "Devolução",
  transfer: "Transferência",
  adjustment: "Ajuste",
  loss: "Perda",
  inventory: "Inventário",
};

/** Só estes tipos são estornados pela retaguarda. */
export const REVERSIBLE = ["adjustment", "loss", "inventory"];

export const quantityText = (value: string | number) =>
  Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

/** A validade chega como AAAA-MM-DD: trocar a ordem evita qualquer conversão de fuso. */
export const dayText = (value: string | null) =>
  value ? value.split("-").reverse().join("/") : "";
