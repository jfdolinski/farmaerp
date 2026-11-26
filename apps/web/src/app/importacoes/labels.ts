// Textos da importação das notas, usados na lista e no relatório.

export interface ImportTotals {
  entries?: number;
  models?: Record<string, number>;
  imported?: number;
  duplicate?: number;
  ignored?: number;
  failed?: number;
  canceled?: number;
}

export interface ImportRow {
  id: string;
  file_name: string;
  size_bytes: number;
  received_bytes: number;
  status: string;
  totals: ImportTotals | null;
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

export const STATUS_LABELS: Record<string, string> = {
  uploading: "Enviando",
  queued: "Na fila",
  processing: "Processando",
  done: "Concluída",
  failed: "Falhou",
};

/** Situações em que a tela se atualiza sozinha. */
export const RUNNING = new Set(["queued", "processing"]);

export const MODEL_LABELS: Record<string, string> = {
  "65": "NFC-e (65)",
  "55": "NF-e (55)",
  "57": "CT-e (57)",
  "59": "SAT (59)",
  evento: "Eventos",
};

export const moment = (value: string | null) =>
  value
    ? new Date(value).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short", timeZone: "America/Sao_Paulo" })
    : "—";

export function fileSize(value: number | string): string {
  // bigint da lista chega como texto.
  const bytes = Number(value);
  if (bytes >= 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

export const count = (value: number | undefined) => (value ?? 0).toLocaleString("pt-BR");
