"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface DiscountFormState {
  error?: ApiError;
  done?: boolean;
}

export interface SimulationLine {
  line: number;
  name: string;
  quantity: number;
  unit_price: number;
  total_cents: number;
  applied: { rule_id: string; name: string; kind: string; amount_cents: number }[];
}

export interface SimulationState {
  error?: ApiError;
  lines?: SimulationLine[];
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();
const optional = (form: FormData, field: string) => text(form, field) || null;

function handleFailure(error: ApiError) {
  if (error.code === "FA402") redirect("/login?next=/descontos&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

/** Aceita vírgula. O que não for número segue como texto para a API recusar. */
function numberValue(raw: string): number | string | null {
  if (raw === "") return null;
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return Number.isNaN(parsed) ? raw : parsed;
}

// Dias no fuso da operação: o início vale do primeiro instante, e o fim, até o último.
const startOfDay = (day: string) => (day ? `${day}T00:00:00.000-03:00` : null);
const endOfDay = (day: string) => (day ? `${day}T23:59:59.999-03:00` : null);

export async function createDiscount(_previous: DiscountFormState, form: FormData): Promise<DiscountFormState> {
  const kind = text(form, "kind");
  const result = await apiFetch("/admin/discount-rules", {
    method: "POST",
    body: {
      name: text(form, "name"),
      kind,
      level: text(form, "level"),
      stacking: text(form, "stacking"),
      productLookup: optional(form, "productLookup"),
      productGroupId: optional(form, "productGroupId"),
      manufacturerId: optional(form, "manufacturerId"),
      categoryId: optional(form, "categoryId"),
      branchId: optional(form, "branchId"),
      percent: kind === "buy_x_pay_y" ? null : numberValue(text(form, "percent")),
      buyQuantity: kind === "buy_x_pay_y" ? numberValue(text(form, "buyQuantity")) : null,
      payQuantity: kind === "buy_x_pay_y" ? numberValue(text(form, "payQuantity")) : null,
      minQuantity: kind === "quantity" ? numberValue(text(form, "minQuantity")) : null,
      paymentMethod: kind === "payment_method" ? optional(form, "paymentMethod") : null,
      customerGroupId: kind === "customer_group" ? optional(form, "customerGroupId") : null,
      agreementId: kind === "agreement" ? optional(form, "agreementId") : null,
      minTotal: kind === "cart_total" ? numberValue(text(form, "minTotal")) : null,
      coupon: kind === "coupon" ? optional(form, "coupon") : null,
      validFrom: startOfDay(text(form, "validFrom")),
      validTo: endOfDay(text(form, "validTo")),
      reason: optional(form, "reason"),
    },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function endDiscount(_previous: DiscountFormState, form: FormData): Promise<DiscountFormState> {
  const result = await apiFetch(`/admin/discount-rules/${encodeURIComponent(text(form, "id"))}/end`, { method: "POST" });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function simulateDiscounts(_previous: SimulationState, form: FormData): Promise<SimulationState> {
  const lines = [1, 2, 3]
    .map((n) => ({ product: text(form, `product${n}`), quantity: numberValue(text(form, `quantity${n}`)), unitPrice: numberValue(text(form, `price${n}`)) }))
    .filter((line) => line.product !== "");
  const method = optional(form, "paymentMethod");
  const result = await apiFetch<SimulationLine[]>("/admin/discount-rules/simulate", {
    method: "POST",
    body: {
      branchId: text(form, "branchId"),
      lines,
      paymentMethods: method ? [method] : [],
      agreementIds: optional(form, "agreementId") ? [text(form, "agreementId")] : [],
      coupon: optional(form, "coupon"),
    },
  });
  if (!result.ok) return handleFailure(result.error);
  return { lines: result.data };
}

export async function saveCustomerGroup(_previous: DiscountFormState, form: FormData): Promise<DiscountFormState> {
  const id = text(form, "id");
  const intent = text(form, "intent");
  const result =
    intent === "remove"
      ? await apiFetch(`/admin/customer-groups/${encodeURIComponent(id)}/delete`, { method: "POST" })
      : await apiFetch(id ? `/admin/customer-groups/${encodeURIComponent(id)}` : "/admin/customer-groups", {
          method: "POST",
          body: { name: text(form, "name") },
        });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function setCustomerGroup(_previous: DiscountFormState, form: FormData): Promise<DiscountFormState> {
  const result = await apiFetch(`/admin/customers/${encodeURIComponent(text(form, "customerId"))}/group`, {
    method: "POST",
    body: { groupId: optional(form, "groupId") },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}
