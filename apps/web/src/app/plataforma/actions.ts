"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface TenantState {
  error?: ApiError;
  created?: { name: string; email: string; temporaryPassword: string };
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();
const optional = (form: FormData, field: string) => text(form, field) || null;

/** Cadastra a empresa como cliente separado. A senha temporária volta só nesta resposta. */
export async function createTenant(_previous: TenantState, form: FormData): Promise<TenantState> {
  const body = {
    groupName: text(form, "groupName"),
    cnpj: text(form, "cnpj"),
    legalName: text(form, "legalName"),
    tradeName: text(form, "tradeName"),
    branch: {
      name: optional(form, "name"),
      phone: optional(form, "phone"),
      postalCode: optional(form, "postalCode"),
      street: optional(form, "street"),
      streetNumber: optional(form, "streetNumber"),
      complement: optional(form, "complement"),
      district: optional(form, "district"),
      city: optional(form, "city"),
      cityCode: optional(form, "cityCode"),
      state: optional(form, "state"),
      pmcRegion: optional(form, "pmcRegion"),
    },
    admin: { name: text(form, "adminName"), email: text(form, "adminEmail") },
  };
  const result = await apiFetch<{ temporaryPassword: string }>("/platform/tenants", { method: "POST", body });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/plataforma&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { created: { name: body.groupName, email: body.admin.email.toLowerCase(), temporaryPassword: result.data.temporaryPassword } };
}

export interface IssuerDecisionState {
  error?: ApiError;
  done?: { decision: "create" | "refuse"; notes: number };
}

/** Destino do CNPJ que veio nas notas importadas: cria a empresa e a filial (ou só a filial) ou recusa. */
export async function decideIssuer(_previous: IssuerDecisionState, form: FormData): Promise<IssuerDecisionState> {
  const choice = text(form, "decision");
  if (choice !== "create" && choice !== "refuse") return { error: { code: "FA005", message: "Alguns dados informados são inválidos.", action: "Escolha criar ou recusar.", retryable: false, traceId: null } };
  const decision: "create" | "refuse" = choice;
  const body = {
    decision,
    legalName: optional(form, "legalName"),
    tradeName: optional(form, "tradeName"),
    taxRegime: optional(form, "taxRegime"),
  };
  const result = await apiFetch<{ notes: number }>(`/platform/import-issuers/${encodeURIComponent(text(form, "id"))}/decision`, {
    method: "POST",
    body,
  });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/plataforma&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  // Sem atualizar a lista agora: o cartão mostra o resultado até a página ser recarregada.
  return { done: { decision, notes: result.data.notes } };
}

export interface LoginImageState {
  error?: ApiError;
  cleared?: boolean;
}

/** Tira a imagem da tela de entrada: ela volta para a cor da marca. */
export async function clearLoginImage(): Promise<LoginImageState> {
  const result = await apiFetch<{ status: string }>("/platform/login-image", { method: "DELETE" });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/plataforma&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { cleared: true };
}

export interface CatalogSyncState {
  error?: ApiError;
  started?: boolean;
}

/** Começa a cópia do Catálogo agora; a tela acompanha pela situação. */
export async function runCatalogSync(): Promise<CatalogSyncState> {
  const result = await apiFetch<{ started: boolean }>("/platform/catalog-sync/run", { method: "POST" });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/plataforma%3Faba%3Dcatalogo&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { started: true };
}
