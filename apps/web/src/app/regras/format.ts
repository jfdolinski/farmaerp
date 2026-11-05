// Fica fora dos componentes de cliente porque as páginas do servidor também usam estes textos.

export const LEVELS: { code: string; label: string }[] = [
  { code: "product", label: "Produto" },
  { code: "price_family", label: "Grupo de preço (família)" },
  { code: "manufacturer", label: "Fabricante" },
  { code: "subcategory", label: "Subcategoria" },
  { code: "category", label: "Categoria" },
  { code: "department", label: "Departamento" },
  { code: "pricing_group", label: "Grupo de precificação" },
  { code: "commission_group", label: "Grupo de comissão" },
  { code: "store_default", label: "Padrão da loja" },
];

export const levelLabel = (code: string | null) =>
  LEVELS.find((level) => level.code === code)?.label ?? code ?? "";

export const STATE_LABELS: Record<string, string> = {
  active: "Em vigor",
  scheduled: "Agendada",
  expired: "Vencida",
  ended: "Encerrada",
};

export const valueText = (value: string | number, unit: string) => {
  const number = Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 4 });
  return unit === "percent" ? `${number}%` : number;
};

/** Dia no fuso da operação, para a data da tela não mudar conforme o servidor. */
export const dayText = (value: string | null) =>
  value
    ? new Date(value).toLocaleDateString("pt-BR", { timeZone: "America/Sao_Paulo" })
    : "";

/** O mesmo dia, no formato do campo de data. */
export const dayInput = (value: string | null) =>
  value
    ? new Date(value).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" })
    : "";
