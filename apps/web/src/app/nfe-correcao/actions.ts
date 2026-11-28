"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, type ApiError } from "@/lib/api";

export interface CorrectionState {
  error?: ApiError;
  /** Sequência da carta registrada. */
  sequence?: number;
  /** Sem resposta da API a tempo: a Sefaz pode ter registrado a carta. */
  uncertain?: boolean;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

/** Envia a carta de correção à Sefaz (a nota de venda ou a da central). */
export async function sendCorrection(_previous: CorrectionState, form: FormData): Promise<CorrectionState> {
  const kind = text(form, "kind") === "central" ? "central" : "sale";
  const id = text(form, "id");
  const result = await apiFetch<{ sequence: number }>(`/admin/nfe-corrections/${kind}/${encodeURIComponent(id)}`, {
    method: "POST",
    body: { text: text(form, "text") },
    timeoutMs: 120_000,
  });
  if (!result.ok) {
    const next = `/nfe-correcao/${kind}/${encodeURIComponent(id)}`;
    if (result.error.code === "FA402") redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
    if (result.error.code === "FA403") redirect("/trocar-senha");
    // Outra carta foi registrada junto: a lista nova mostra qual.
    if (result.error.code === "FA791") refresh();
    return { error: result.error, uncertain: result.error.code === "FA001" };
  }
  refresh();
  return { sequence: result.data.sequence };
}
