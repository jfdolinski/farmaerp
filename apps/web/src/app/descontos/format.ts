// Textos dos descontos automáticos, usados pelas páginas do servidor e pelos formulários.

export const DISCOUNT_KINDS: { code: string; label: string; hint: string }[] = [
  { code: "product", label: "Percentual fixo", hint: "Desconto fixo para o alvo escolhido." },
  { code: "promotion", label: "Promoção", hint: "Percentual com início e fim." },
  { code: "buy_x_pay_y", label: "Leve X, pague Y", hint: "A cada X unidades, o cliente paga Y." },
  { code: "quantity", label: "Progressivo por quantidade", hint: "Percentual a partir da unidade escolhida (por exemplo, a 2ª)." },
  { code: "payment_method", label: "Forma de pagamento", hint: "Vale quando a venda inteira é paga nesta forma." },
  { code: "customer_group", label: "Grupo de clientes", hint: "Vale para os clientes do grupo." },
  { code: "agreement", label: "Convênio", hint: "Vale quando a venda usa o convênio." },
  { code: "birthday", label: "Aniversariante do mês", hint: "Vale no mês do aniversário do cliente." },
  { code: "cart_total", label: "Faixa de valor da compra", hint: "Vale a partir do valor da compra, sem os descontos." },
  { code: "coupon", label: "Cupom", hint: "Vale quando o caixa digita o código do cupom." },
];

export const kindLabel = (code: string) => DISCOUNT_KINDS.find((kind) => kind.code === code)?.label ?? code;

export const PAYMENT_METHODS: Record<string, string> = {
  cash: "Dinheiro",
  credit_card: "Cartão de crédito",
  debit_card: "Cartão de débito",
  pix: "PIX",
  agreement: "Convênio",
};

export const STACKING_LABELS: Record<string, string> = {
  cumulative: "Acumulável",
  exclusive: "Exclusiva",
};

export const STATUS_LABELS: Record<string, string> = {
  active: "Em vigor",
  scheduled: "Agendado",
  expired: "Vencido",
  ended: "Encerrado",
};

const brl = (value: string | number) => Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const percent = (value: string | number) => `${Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 4 })}%`;

export interface DiscountRow {
  id: string;
  name: string;
  kind: string;
  level: string;
  target_name: string | null;
  branch_id: string | null;
  branch_name: string | null;
  percent: string | null;
  buy_quantity: number | null;
  pay_quantity: number | null;
  min_quantity: number | null;
  payment_method: string | null;
  customer_group_name: string | null;
  agreement_name: string | null;
  min_total: string | null;
  coupon: string | null;
  stacking: string;
  valid_from: string;
  valid_to: string | null;
  ended_at: string | null;
  reason: string | null;
  status: string;
}

/** O que o desconto dá, em uma frase. */
export function discountText(row: DiscountRow): string {
  switch (row.kind) {
    case "buy_x_pay_y":
      return `Leve ${row.buy_quantity}, pague ${row.pay_quantity}`;
    case "quantity":
      return `${percent(row.percent ?? 0)} a partir da ${row.min_quantity}ª unidade`;
    case "payment_method":
      return `${percent(row.percent ?? 0)} pagando em ${PAYMENT_METHODS[row.payment_method ?? ""]?.toLowerCase() ?? row.payment_method}`;
    case "customer_group":
      return `${percent(row.percent ?? 0)} para o grupo ${row.customer_group_name ?? ""}`;
    case "agreement":
      return `${percent(row.percent ?? 0)} no convênio ${row.agreement_name ?? ""}`;
    case "birthday":
      return `${percent(row.percent ?? 0)} no mês do aniversário`;
    case "cart_total":
      return `${percent(row.percent ?? 0)} em compras a partir de ${brl(row.min_total ?? 0)}`;
    case "coupon":
      return `${percent(row.percent ?? 0)} com o cupom ${row.coupon}`;
    default:
      return percent(row.percent ?? 0);
  }
}
