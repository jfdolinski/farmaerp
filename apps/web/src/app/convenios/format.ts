export interface InvoiceItem {
  kind: "sale" | "return";
  customer_name: string | null;
  registration: string | null;
  occurred_at: string;
  sale_code: string | null;
  return_code: string | null;
  amount: number;
}

export const STATUS: Record<string, string> = {
  closed: "Fechada, a receber",
  paid: "Paga",
  cancelled: "Cancelada",
};

export const moneyText = (value: number | string) =>
  Number(value).toLocaleString("pt-BR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** AAAA-MM-DD para DD/MM/AAAA, sem passar por fuso. */
export const dayText = (value: string | null | undefined) => {
  if (!value) return "";
  const [year, month, day] = value.slice(0, 10).split("-");
  return `${day}/${month}/${year}`;
};

export const momentText = (value: string) =>
  new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" });

/** Hoje no fuso da rede, AAAA-MM-DD. */
export const todayText = () => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date());

export const itemLabel = (item: InvoiceItem) =>
  item.kind === "sale"
    ? `Venda ${item.sale_code ?? ""}`
    : `Devolução ${item.return_code ?? ""} (venda ${item.sale_code ?? ""})`;

export interface InvoiceDetail {
  id: string;
  agreement_id: string;
  agreement_name: string;
  agreement_cnpj: string | null;
  period_start: string;
  period_end: string;
  status: string;
  total: number;
  closed_by_name: string;
  created_at: string;
  paid_on: string | null;
  paid_note: string | null;
  cancel_reason: string | null;
  items: InvoiceItem[];
  customers: { customer_name: string | null; registration: string | null; total: number }[];
}
