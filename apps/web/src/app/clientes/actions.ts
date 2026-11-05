"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface CustomerFormState {
  error?: ApiError;
  done?: boolean;
  unchanged?: boolean;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();
const optional = (form: FormData, field: string) => text(form, field) || null;

function handleFailure(error: ApiError, next: string): CustomerFormState {
  if (error.code === "FA402") {
    redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  }
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

const customerBody = (form: FormData) => ({
  personType: optional(form, "personType"),
  document: optional(form, "document"),
  name: optional(form, "name"),
  tradeName: optional(form, "tradeName"),
  birthDate: optional(form, "birthDate"),
  phone: optional(form, "phone"),
  email: optional(form, "email"),
  postalCode: optional(form, "postalCode"),
  street: optional(form, "street"),
  streetNumber: optional(form, "streetNumber"),
  complement: optional(form, "complement"),
  district: optional(form, "district"),
  city: optional(form, "city"),
  cityCode: optional(form, "cityCode"),
  state: optional(form, "state"),
});

export async function createCustomer(
  _previous: CustomerFormState,
  form: FormData,
): Promise<CustomerFormState> {
  const result = await apiFetch<{ id: string }>("/admin/customers", {
    method: "POST",
    body: customerBody(form),
  });
  if (!result.ok) return handleFailure(result.error, "/clientes/novo");
  redirect(`/clientes/${result.data.id}`);
}

export async function updateCustomer(
  _previous: CustomerFormState,
  form: FormData,
): Promise<CustomerFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result = await apiFetch(`/admin/customers/${id}`, {
    method: "PATCH",
    body: customerBody(form),
  });
  if (!result.ok) return handleFailure(result.error, `/clientes/${id}`);
  refresh();
  return { done: true };
}

const dependentBody = (form: FormData) => ({
  name: optional(form, "name"),
  relationship: optional(form, "relationship"),
  birthDate: optional(form, "birthDate"),
  cpf: optional(form, "cpf"),
});

/** Incluir, salvar e remover dependente: o botão clicado decide. */
export async function changeDependent(
  _previous: CustomerFormState,
  form: FormData,
): Promise<CustomerFormState> {
  const customer = encodeURIComponent(text(form, "customerId"));
  const id = encodeURIComponent(text(form, "id"));
  const intent = text(form, "intent");
  const result =
    intent === "add"
      ? await apiFetch(`/admin/customers/${customer}/dependents`, { method: "POST", body: dependentBody(form) })
      : intent === "remove"
        ? await apiFetch(`/admin/customers/dependents/${id}/remove`, { method: "POST" })
        : await apiFetch(`/admin/customers/dependents/${id}`, { method: "PATCH", body: dependentBody(form) });
  if (!result.ok) return handleFailure(result.error, `/clientes/${customer}`);
  refresh();
  return { done: true };
}

export async function recordConsent(
  _previous: CustomerFormState,
  form: FormData,
): Promise<CustomerFormState> {
  const customer = encodeURIComponent(text(form, "customerId"));
  const result = await apiFetch<{ changed: boolean }>(`/admin/customers/${customer}/consents`, {
    method: "POST",
    body: {
      purpose: text(form, "purpose"),
      granted: text(form, "intent") === "grant",
      channel: optional(form, "channel"),
    },
  });
  if (!result.ok) return handleFailure(result.error, `/clientes/${customer}`);
  refresh();
  return { done: true, unchanged: !result.data.changed };
}
