"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface InvoiceState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

async function send(
  path: string,
  method: "POST" | "PATCH",
  body: unknown,
  back: string,
): Promise<{ ok: true; data: unknown } | { ok: false; state: InvoiceState }> {
  const result = await apiFetch(path, { method, body });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect(`/login?next=${encodeURIComponent(back)}&expired=1`);
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { ok: false, state: { error: result.error } };
  }
  return { ok: true, data: result.data };
}

/** Dia do mês em que a fatura fecha. O que não for número segue como texto para a API recusar. */
export async function setClosingDay(_previous: InvoiceState, form: FormData): Promise<InvoiceState> {
  const id = text(form, "agreementId");
  const raw = text(form, "day");
  const day = /^\d+$/.test(raw) ? Number(raw) : raw;
  const result = await send(`/admin/agreements/${encodeURIComponent(id)}/closing-day`, "PATCH", { day }, `/convenios/${id}`);
  if (!result.ok) return result.state;
  refresh();
  return { done: true };
}

/** Fecha a fatura e abre a tela dela. */
export async function closeInvoice(_previous: InvoiceState, form: FormData): Promise<InvoiceState> {
  const id = text(form, "agreementId");
  const result = await send(
    `/admin/agreements/${encodeURIComponent(id)}/invoices`,
    "POST",
    { until: text(form, "until") },
    `/convenios/${id}`,
  );
  if (!result.ok) return result.state;
  redirect(`/convenios/faturas/${(result.data as { id: string }).id}`);
}

export async function payInvoice(_previous: InvoiceState, form: FormData): Promise<InvoiceState> {
  const id = text(form, "invoiceId");
  const result = await send(
    `/admin/agreement-invoices/${encodeURIComponent(id)}/pay`,
    "POST",
    { paidOn: text(form, "paidOn"), note: text(form, "note") || null },
    `/convenios/faturas/${id}`,
  );
  if (!result.ok) return result.state;
  refresh();
  return { done: true };
}

export async function cancelInvoice(_previous: InvoiceState, form: FormData): Promise<InvoiceState> {
  const id = text(form, "invoiceId");
  const result = await send(
    `/admin/agreement-invoices/${encodeURIComponent(id)}/cancel`,
    "POST",
    { reason: text(form, "reason") },
    `/convenios/faturas/${id}`,
  );
  if (!result.ok) return result.state;
  refresh();
  return { done: true };
}
