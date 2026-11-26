"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, type ApiError } from "@/lib/api";

export interface FiscalFormState {
  error?: ApiError;
  /** Resultado para mostrar (situação depois da consulta ou do reenvio, efeito do cancelamento). */
  result?: Record<string, unknown>;
  /** Sem resposta da API a tempo: a operação pode ter acontecido na Sefaz. */
  uncertain?: boolean;
}

/** Cada ida à Sefaz pode levar até 30 s, e o reenvio encadeia consulta, envio e consulta. */
const SEFAZ_TIMEOUT = 120_000;
const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

function failure(error: ApiError): FiscalFormState {
  if (error.code === "FA402") redirect("/login?next=%2Fnotas-fiscais&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  // Sem resposta: a Sefaz pode ter registrado. Consultar mostra a situação real.
  return { error, uncertain: error.code === "FA001" };
}

async function post(path: string, body?: unknown): Promise<FiscalFormState> {
  const result = await apiFetch<Record<string, unknown>>(path, { method: "POST", body, timeoutMs: SEFAZ_TIMEOUT });
  if (!result.ok) return failure(result.error);
  refresh();
  return { result: result.data };
}

export async function consultDocument(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  return post(`/admin/fiscal-documents/${encodeURIComponent(text(form, "id"))}/consult`);
}

export async function resendDocument(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  return post(`/admin/fiscal-documents/${encodeURIComponent(text(form, "id"))}/resend`);
}

export async function cancelDocument(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  return post(`/admin/fiscal-documents/${encodeURIComponent(text(form, "id"))}/cancel`, { reason: text(form, "reason") });
}

export async function dismissAlert(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  return post(`/admin/fiscal-documents/${encodeURIComponent(text(form, "id"))}/dismiss`);
}

export async function voidRange(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const number = (field: string) => Number(text(form, field));
  return post("/admin/fiscal-documents/voids", {
    branchId: text(form, "branchId"),
    series: number("series"),
    first: number("first"),
    last: number("last"),
    reason: text(form, "reason"),
  });
}
