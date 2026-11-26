"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface ReleaseState {
  error?: ApiError;
  done?: boolean;
}

/** Libera a versão para a rede ou retira. A regra (só para a frente) é do banco. */
export async function setReleaseStatus(_previous: ReleaseState, form: FormData): Promise<ReleaseState> {
  const id = String(form.get("id") ?? "");
  const result = await apiFetch(`/platform/releases/${encodeURIComponent(id)}/status`, {
    method: "POST",
    body: { status: String(form.get("status") ?? "") },
  });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=%2Fplataforma%2Fversoes&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}
