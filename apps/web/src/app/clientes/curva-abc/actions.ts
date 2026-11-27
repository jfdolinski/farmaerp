"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface AbcState {
  error?: ApiError;
  saved?: boolean;
  changed?: number;
}

const number = (form: FormData, field: string) => Number(String(form.get(field) ?? "").trim());

function handleSession(error: ApiError) {
  if (error.code === "FA402") redirect("/login?next=/clientes/curva-abc&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
}

/** Parâmetros da curva ABC da filial. */
export async function saveAbcSettings(_previous: AbcState, form: FormData): Promise<AbcState> {
  const branchId = String(form.get("branchId") ?? "");
  const body = {
    periodDays: number(form, "periodDays"),
    aMinSales: number(form, "aMinSales"),
    bMinSales: number(form, "bMinSales"),
    aIntervalDays: number(form, "aIntervalDays"),
    bIntervalDays: number(form, "bIntervalDays"),
    cIntervalDays: number(form, "cIntervalDays"),
  };
  const result = await apiFetch(`/admin/abc/settings/${encodeURIComponent(branchId)}`, { method: "PUT", body });
  if (!result.ok) {
    handleSession(result.error);
    return { error: result.error };
  }
  refresh();
  return { saved: true };
}

/** Recalcula as três curvas da filial agora. */
export async function recalculateAbc(_previous: AbcState, form: FormData): Promise<AbcState> {
  const branchId = String(form.get("branchId") ?? "");
  const result = await apiFetch<{ changed: number }>(`/admin/abc/recalculate/${encodeURIComponent(branchId)}`, { method: "POST" });
  if (!result.ok) {
    handleSession(result.error);
    return { error: result.error };
  }
  refresh();
  return { changed: result.data.changed };
}
