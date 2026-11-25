"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface CreditState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

/** Aceita vírgula e milhar com ponto. O que não for número segue como texto para a API recusar. */
function numberValue(raw: string): number | string | null {
  if (raw === "") return null;
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return Number.isNaN(parsed) ? raw : parsed;
}

async function send(path: string, body: unknown, back: string): Promise<CreditState> {
  const result = await apiFetch(path, { method: "POST", body });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect(`/login?next=${encodeURIComponent(back)}&expired=1`);
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}

const back = (form: FormData) => text(form, "back") || "/crediario";

export async function openCredit(_previous: CreditState, form: FormData): Promise<CreditState> {
  return send(
    `/admin/credit/customers/${encodeURIComponent(text(form, "customerId"))}/open`,
    { homeBranchId: text(form, "homeBranchId"), creditLimit: numberValue(text(form, "creditLimit")), reason: text(form, "reason") || null },
    back(form),
  );
}

export async function changeLimit(_previous: CreditState, form: FormData): Promise<CreditState> {
  return send(
    `/admin/credit/accounts/${encodeURIComponent(text(form, "accountId"))}/limit`,
    { creditLimit: numberValue(text(form, "creditLimit")), reason: text(form, "reason") },
    back(form),
  );
}

export async function changeStatus(_previous: CreditState, form: FormData): Promise<CreditState> {
  return send(
    `/admin/credit/accounts/${encodeURIComponent(text(form, "accountId"))}/status`,
    { status: text(form, "status"), reason: text(form, "reason") },
    back(form),
  );
}

export async function changeTerms(_previous: CreditState, form: FormData): Promise<CreditState> {
  const mode = text(form, "dueMode");
  return send(
    `/admin/credit/accounts/${encodeURIComponent(text(form, "accountId"))}/terms`,
    {
      dueMode: mode === "" ? null : mode,
      closingDay: mode === "closing" ? numberValue(text(form, "closingDay")) : null,
      dueDay: mode === "closing" ? numberValue(text(form, "dueDay")) : null,
      intervalDays: mode === "days" ? numberValue(text(form, "intervalDays")) : null,
    },
    back(form),
  );
}

export async function changeDependent(_previous: CreditState, form: FormData): Promise<CreditState> {
  return send(
    `/admin/credit/dependents/${encodeURIComponent(text(form, "dependentId"))}`,
    { allowed: text(form, "allowed") === "true" },
    back(form),
  );
}

export async function savePolicy(_previous: CreditState, form: FormData): Promise<CreditState> {
  const mode = text(form, "dueMode");
  return send(
    `/admin/credit/policies/${encodeURIComponent(text(form, "branchId"))}`,
    {
      lateFeePercent: numberValue(text(form, "lateFeePercent")),
      monthlyInterestPercent: numberValue(text(form, "monthlyInterestPercent")),
      maxInstallments: numberValue(text(form, "maxInstallments")),
      limitFactor: numberValue(text(form, "limitFactor")),
      blockAfterDays: numberValue(text(form, "blockAfterDays")),
      dueMode: mode || null,
      closingDay: numberValue(text(form, "closingDay")),
      dueDay: numberValue(text(form, "dueDay")),
      intervalDays: numberValue(text(form, "intervalDays")),
    },
    "/crediario",
  );
}
