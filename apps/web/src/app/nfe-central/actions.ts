"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, type ApiError } from "@/lib/api";

export interface CentralCancelState {
  error?: ApiError;
  done?: boolean;
  /** Sem resposta da API a tempo: a Sefaz pode ter registrado o cancelamento. */
  uncertain?: boolean;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

/** Cancela a NF-e da central (devolução ou transferência) na Sefaz: só a nota, a operação fica. */
export async function cancelCentralNfe(_previous: CentralCancelState, form: FormData): Promise<CentralCancelState> {
  const result = await apiFetch<{ status: string }>(`/admin/central-nfe/${encodeURIComponent(text(form, "id"))}/cancel`, {
    method: "POST",
    body: { reason: text(form, "reason") },
    timeoutMs: 120_000,
  });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect(`/login?next=${encodeURIComponent(text(form, "next") || "/")}&expired=1`);
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error, uncertain: result.error.code === "FA001" };
  }
  refresh();
  return { done: true };
}
