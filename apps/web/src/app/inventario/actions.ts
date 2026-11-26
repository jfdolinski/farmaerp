"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, type ApiError } from "@/lib/api";

export interface CountFormState {
  error?: ApiError;
  done?: boolean;
  /** Resultado da planilha. */
  loaded?: { accepted: number; rejected_total: number; rejected: { line: number; lookup: string; reason: string }[] };
  applied?: { counted_lines: number; raised: number; lowered: number; zeroed: number };
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

function failure(error: ApiError, next: string): CountFormState {
  if (error.code === "FA402") redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

/** Aceita vírgula. O que não for número segue como está para a API recusar. */
function quantityValue(raw: string): number | string {
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return value === "" || Number.isNaN(parsed) ? raw : parsed;
}

/** Abre o inventário da filial. A hora de corte vem da tela no horário de Brasília. */
export async function createCount(_previous: CountFormState, form: FormData): Promise<CountFormState> {
  const local = text(form, "cutoffAt");
  const result = await apiFetch<{ id: string }>("/admin/stock-counts", {
    method: "POST",
    body: { branchId: text(form, "branchId"), cutoffAt: local ? `${local}:00-03:00` : "", note: text(form, "note") || null },
  });
  if (!result.ok) return failure(result.error, "/inventario");
  redirect(`/inventario/${result.data.id}`);
}

export async function loadFile(_previous: CountFormState, form: FormData): Promise<CountFormState> {
  const id = text(form, "id");
  const file = form.get("file");
  if (!(file instanceof File) || file.size === 0) {
    return { error: { code: "FA005", message: "Escolha a planilha (.csv).", action: "Salve a planilha como CSV e envie.", retryable: false, traceId: null } };
  }
  const result = await apiFetch<CountFormState["loaded"]>(`/admin/stock-counts/${encodeURIComponent(id)}/file`, {
    method: "POST",
    csv: await file.text(),
    timeoutMs: 120_000,
  });
  if (!result.ok) return failure(result.error, `/inventario/${id}`);
  refresh();
  return { loaded: result.data };
}

export async function setItem(_previous: CountFormState, form: FormData): Promise<CountFormState> {
  const id = text(form, "id");
  const result = await apiFetch(`/admin/stock-counts/${encodeURIComponent(id)}/items`, {
    method: "PUT",
    body: {
      lookup: text(form, "lookup"),
      quantity: quantityValue(text(form, "quantity")),
      batch: text(form, "batch") || null,
      expiresOn: text(form, "expiresOn") || null,
    },
  });
  if (!result.ok) return failure(result.error, `/inventario/${id}`);
  refresh();
  return { done: true };
}

export async function removeItem(_previous: CountFormState, form: FormData): Promise<CountFormState> {
  const id = text(form, "id");
  const result = await apiFetch(
    `/admin/stock-counts/${encodeURIComponent(id)}/items/${encodeURIComponent(text(form, "itemId"))}/remove`,
    { method: "POST" },
  );
  if (!result.ok) return failure(result.error, `/inventario/${id}`);
  refresh();
  return { done: true };
}

export async function applyCount(_previous: CountFormState, form: FormData): Promise<CountFormState> {
  const id = text(form, "id");
  const result = await apiFetch<CountFormState["applied"]>(`/admin/stock-counts/${encodeURIComponent(id)}/apply`, {
    method: "POST",
    timeoutMs: 120_000,
  });
  if (!result.ok) return failure(result.error, `/inventario/${id}`);
  refresh();
  return { applied: result.data };
}

export async function cancelCount(_previous: CountFormState, form: FormData): Promise<CountFormState> {
  const id = text(form, "id");
  const result = await apiFetch(`/admin/stock-counts/${encodeURIComponent(id)}/cancel`, { method: "POST" });
  if (!result.ok) return failure(result.error, `/inventario/${id}`);
  refresh();
  return { done: true };
}
