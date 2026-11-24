"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface ResolveState {
  error?: ApiError;
  done?: boolean;
}

export async function resolveConflict(_previous: ResolveState, form: FormData): Promise<ResolveState> {
  const id = String(form.get("id") ?? "");
  const note = String(form.get("note") ?? "");
  const result = await apiFetch(`/admin/sync/conflicts/${encodeURIComponent(id)}/resolve`, {
    method: "POST",
    body: { note },
  });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/sincronizacao&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}

export interface RetryState {
  error?: ApiError;
  outcome?: { status: "applied" | "conflict"; code?: string };
}

/** Aplica de novo o item do conflito; o banco decide se agora passa. */
export async function retryConflict(_previous: RetryState, form: FormData): Promise<RetryState> {
  const id = String(form.get("id") ?? "");
  const result = await apiFetch<{ status: "applied" | "conflict"; code?: string }>(
    `/admin/sync/conflicts/${encodeURIComponent(id)}/retry`,
    { method: "POST" },
  );
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/sincronizacao&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { outcome: result.data };
}
