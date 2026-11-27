"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface CustomerFormState {
  error?: ApiError;
  done?: boolean;
  unchanged?: boolean;
}

export interface CnpjData {
  legalName: string | null;
  tradeName: string | null;
  active: boolean;
  statusText: string | null;
  postalCode: string | null;
  street: string | null;
  streetNumber: string | null;
  complement: string | null;
  district: string | null;
  city: string | null;
  cityCode: string | null;
  state: string | null;
  phone: string | null;
  email: string | null;
}

export interface LookupState {
  error?: ApiError;
  data?: CnpjData;
  document?: string;
}

/** Só preenche a tela: nada é gravado até a pessoa conferir e confirmar o cadastro. */
export async function lookupCnpj(_previous: LookupState, form: FormData): Promise<LookupState> {
  const document = text(form, "document");
  const clean = document.replace(/[^0-9A-Za-z]/g, "");
  const result = await apiFetch<CnpjData>(`/admin/customers/cnpj/${encodeURIComponent(clean)}`);
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/clientes/novo&expired=1");
    return { error: result.error, document };
  }
  return { data: result.data, document };
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
  stateRegistration: optional(form, "stateRegistration"),
  ieIndicator: optional(form, "ieIndicator"),
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

/** Aceita vírgula e milhar com ponto. O que não for número segue como texto para a API recusar. */
function moneyValue(raw: string): number | string {
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return value === "" || Number.isNaN(parsed) ? raw : parsed;
}

/** Vincular, salvar e remover: o botão clicado decide. */
export async function changeCustomerAgreement(
  _previous: CustomerFormState,
  form: FormData,
): Promise<CustomerFormState> {
  const customer = encodeURIComponent(text(form, "customerId"));
  const id = encodeURIComponent(text(form, "id"));
  const intent = text(form, "intent");
  const body = {
    agreementId: optional(form, "agreementId"),
    registration: optional(form, "registration"),
    creditLimit: moneyValue(text(form, "creditLimit")),
  };
  const result =
    intent === "add"
      ? await apiFetch(`/admin/customers/${customer}/agreements`, { method: "POST", body })
      : intent === "remove"
        ? await apiFetch(`/admin/customers/agreements/${id}/remove`, { method: "POST" })
        : await apiFetch(`/admin/customers/agreements/${id}`, { method: "PATCH", body });
  if (!result.ok) return handleFailure(result.error, `/clientes/${customer}`);
  refresh();
  return { done: true };
}

/** Criar, renomear e excluir convênio: o botão clicado decide. */
export async function changeAgreement(
  _previous: CustomerFormState,
  form: FormData,
): Promise<CustomerFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const intent = text(form, "intent");
  const body = { name: optional(form, "name"), cnpj: optional(form, "cnpj") };
  const result =
    intent === "add"
      ? await apiFetch("/admin/agreements", { method: "POST", body })
      : intent === "delete"
        ? await apiFetch(`/admin/agreements/${id}/delete`, { method: "POST" })
        : await apiFetch(`/admin/agreements/${id}`, { method: "PATCH", body });
  if (!result.ok) return handleFailure(result.error, "/convenios");
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
