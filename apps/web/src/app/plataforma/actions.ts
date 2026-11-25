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
