"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { SngpcProblem } from "./format";

export interface SngpcState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();
const back = "/sngpc";

function expired(error: ApiError): void {
  if (error.code === "FA402") redirect(`/login?next=${encodeURIComponent(back)}&expired=1`);
  if (error.code === "FA403") redirect("/trocar-senha");
}

async function send(path: string, method: "POST" | "PATCH", body: unknown): Promise<SngpcState> {
  const result = await apiFetch(path, { method, body });
  if (!result.ok) {
    expired(result.error);
    return { error: result.error };
  }
  refresh();
  return { done: true };
}

/** Quantidade com vírgula. O que não for número segue como texto para a API recusar. */
function numberValue(raw: string): number | string {
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return raw === "" || Number.isNaN(parsed) ? raw : parsed;
}

export async function openSngpc(_previous: SngpcState, form: FormData): Promise<SngpcState> {
  const branchId = text(form, "branchId");
  const result = await apiFetch<{ inventory_lines: number; unbatched: unknown[] }>(
    `/admin/sngpc/branches/${encodeURIComponent(branchId)}/open`,
    { method: "POST" },
  );
  if (!result.ok) {
    expired(result.error);
    return { error: result.error };
  }
  // A página troca o formulário pelo inventário: o resumo da abertura vai pela URL.
  redirect(
    `/sngpc?filial=${encodeURIComponent(branchId)}&aberto=${result.data.inventory_lines}&semlote=${result.data.unbatched.length}`,
  );
}

/** Ajustes da pendência: só os campos que vieram no formulário. */
export async function updateMovement(_previous: SngpcState, form: FormData): Promise<SngpcState> {
  const body: Record<string, unknown> = {};
  if (form.has("reportedOn")) body.reportedOn = text(form, "reportedOn");
  if (form.has("lossReason")) body.lossReason = text(form, "lossReason");
  if (form.has("batchId")) body.batchId = text(form, "batchId");
  if (form.has("quantity")) body.quantity = numberValue(text(form, "quantity"));
  return send(`/admin/sngpc/movements/${encodeURIComponent(text(form, "movementId"))}`, "PATCH", body);
}

export async function completeSale(_previous: SngpcState, form: FormData): Promise<SngpcState> {
  const fields = [
    "batchId", "prescriptionType", "prescriptionNumber", "prescriptionDate", "prescriberName", "prescriberCouncil",
    "prescriberNumber", "prescriberState", "buyerName", "buyerDocumentType", "buyerDocument", "buyerIssuer", "buyerState",
    "patientName", "patientSex",
  ];
  const body: Record<string, unknown> = {};
  for (const field of fields) body[field] = text(form, field) || null;
  const age = text(form, "patientAge");
  if (age !== "") body.patientAge = /^\d+$/.test(age) ? Number(age) : age;
  return send(`/admin/sngpc/movements/${encodeURIComponent(text(form, "movementId"))}/complete`, "POST", body);
}

export async function disregardMovement(_previous: SngpcState, form: FormData): Promise<SngpcState> {
  return send(`/admin/sngpc/movements/${encodeURIComponent(text(form, "movementId"))}/disregard`, "POST", {
    reason: text(form, "reason"),
  });
}

export async function checkMovements(
  branchId: string,
  ids: string[],
): Promise<{ problems?: SngpcProblem[]; error?: ApiError }> {
  const result = await apiFetch<SngpcProblem[]>(`/admin/sngpc/branches/${encodeURIComponent(branchId)}/check`, {
    method: "POST",
    body: { ids },
  });
  if (!result.ok) {
    expired(result.error);
    return { error: result.error };
  }
  return { problems: result.data };
}

export async function confirmMovements(
  branchId: string,
  ids: string[],
  sendOn: string,
  password: string,
): Promise<{ confirmed?: number; error?: ApiError }> {
  const result = await apiFetch<{ confirmed: number }>(`/admin/sngpc/branches/${encodeURIComponent(branchId)}/confirm`, {
    method: "POST",
    body: { ids, sendOn, password },
  });
  if (!result.ok) {
    expired(result.error);
    return { error: result.error };
  }
  refresh();
  return { confirmed: result.data.confirmed };
}
