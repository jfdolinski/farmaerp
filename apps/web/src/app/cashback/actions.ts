"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface CashbackPolicyState {
  error?: ApiError;
  done?: boolean;
}

const numberValue = (raw: FormDataEntryValue | null): number | string | null => {
  const text = String(raw ?? "").trim();
  if (text === "") return null;
  const value = Number(text.includes(",") ? text.replaceAll(".", "").replace(",", ".") : text);
  return Number.isNaN(value) ? text : value;
};

/** Parâmetros do cashback da rede: carência, validade e quanto da compra o cashback pode pagar. */
export async function saveCashbackPolicy(_previous: CashbackPolicyState, form: FormData): Promise<CashbackPolicyState> {
  const result = await apiFetch("/admin/cashback-policy", {
    method: "POST",
    body: {
      waitingDays: numberValue(form.get("waitingDays")),
      validityDays: numberValue(form.get("validityDays")),
      maxUsePercent: numberValue(form.get("maxUsePercent")),
    },
  });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/descontos&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}
