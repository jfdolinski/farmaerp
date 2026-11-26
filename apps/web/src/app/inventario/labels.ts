// Textos do inventário de abertura.

export interface CountRow {
  id: string;
  branch_id: string;
  branch_name: string;
  kind: string;
  status: string;
  cutoff_at: string;
  note: string | null;
  item_count: number;
  totals: { counted_lines: number; raised: number; lowered: number; zeroed: number } | null;
  created_at: string;
  created_by_name: string | null;
  applied_at: string | null;
  applied_by_name: string | null;
  can_change: boolean;
}

export const STATUS_LABELS: Record<string, string> = {
  counting: "Em contagem",
  applied: "Aplicado",
  canceled: "Cancelado",
};

export const quantityText = (value: number | string) =>
  Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 3 });

export const dayText = (value: string | null) => (value ? value.slice(0, 10).split("-").reverse().join("/") : "—");
