// Fica fora dos componentes de cliente porque as páginas do servidor também formatam estes valores.

export const STATUS_LABELS: Record<string, string> = {
  active: "Ativo",
  on_order: "Somente encomenda",
  blocked: "Bloqueado",
  inactive: "Inativo",
};

export const REGION_LABELS: Record<string, string> = {
  free_trade_area: "Área de livre comércio",
  manaus_free_zone: "Zona Franca de Manaus",
};

export const statusLabel = (status: string) => STATUS_LABELS[status] ?? status;

export const regionLabel = (region: string | null) =>
  region ? (REGION_LABELS[region] ?? region) : "Estado inteiro";

export const moneyText = (value: string | number | null) =>
  value === null
    ? "Não informado"
    : Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
