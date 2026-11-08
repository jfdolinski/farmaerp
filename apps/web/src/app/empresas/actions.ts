"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface StructureFormState {
  error?: ApiError;
  done?: boolean;
  /** O certificado da filial foi encerrado e precisa ser reenviado. */
  certificateEnded?: boolean;
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
}

export interface LookupState {
  error?: ApiError;
  data?: CnpjData;
  document?: string;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

function failure(error: ApiError): StructureFormState {
  if (error.code === "FA402") redirect("/login?next=%2Fempresas&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

const branchBody = (form: FormData) => ({
  name: text(form, "name"),
  cnpj: text(form, "cnpj"),
  state: text(form, "state"),
  pmcRegion: text(form, "region"),
  postalCode: text(form, "postalCode"),
  street: text(form, "street"),
  streetNumber: text(form, "streetNumber"),
  complement: text(form, "complement"),
  district: text(form, "district"),
  city: text(form, "city"),
  cityCode: text(form, "cityCode"),
  phone: text(form, "phone"),
});

/** Só preenche a tela: nada é gravado até a pessoa conferir e salvar. */
export async function lookupCnpj(_previous: LookupState, form: FormData): Promise<LookupState> {
  const document = text(form, "document");
  const clean = document.replace(/[^0-9A-Za-z]/g, "");
  const result = await apiFetch<CnpjData>(`/admin/customers/cnpj/${encodeURIComponent(clean)}`);
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=%2Fempresas&expired=1");
    return { error: result.error, document };
  }
  return { data: result.data, document };
}

export async function createCompany(
  _previous: StructureFormState,
  form: FormData,
): Promise<StructureFormState> {
  const withBranch = form.get("withBranch") === "on";
  const result = await apiFetch("/admin/structure/companies", {
    method: "POST",
    body: {
      cnpj: text(form, "cnpj"),
      legalName: text(form, "legalName"),
      tradeName: text(form, "tradeName"),
      branch: withBranch ? branchBody(form) : null,
    },
  });
  if (!result.ok) return failure(result.error);
  refresh();
  return { done: true };
}

/** Salvar ou encerrar a empresa: o botão clicado decide. */
export async function changeCompany(
  _previous: StructureFormState,
  form: FormData,
): Promise<StructureFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result =
    text(form, "intent") === "delete"
      ? await apiFetch(`/admin/structure/companies/${id}/delete`, { method: "POST" })
      : await apiFetch(`/admin/structure/companies/${id}`, {
          method: "PATCH",
          body: { legalName: text(form, "legalName"), tradeName: text(form, "tradeName") },
        });
  if (!result.ok) return failure(result.error);
  refresh();
  return { done: true };
}

export async function createBranch(
  _previous: StructureFormState,
  form: FormData,
): Promise<StructureFormState> {
  const companyId = encodeURIComponent(text(form, "companyId"));
  const result = await apiFetch(`/admin/structure/companies/${companyId}/branches`, {
    method: "POST",
    body: branchBody(form),
  });
  if (!result.ok) return failure(result.error);
  refresh();
  return { done: true };
}

/** Salvar ou encerrar a filial: o botão clicado decide. */
export async function changeBranch(
  _previous: StructureFormState,
  form: FormData,
): Promise<StructureFormState> {
  const id = encodeURIComponent(text(form, "id"));
  if (text(form, "intent") === "delete") {
    const removed = await apiFetch(`/admin/structure/branches/${id}/delete`, { method: "POST" });
    if (!removed.ok) return failure(removed.error);
    refresh();
    return { done: true };
  }
  const result = await apiFetch<{ certificateEnded: boolean }>(`/admin/structure/branches/${id}`, {
    method: "PATCH",
    body: branchBody(form),
  });
  if (!result.ok) return failure(result.error);
  refresh();
  return { done: true, certificateEnded: result.data.certificateEnded };
}

export async function moveBranch(
  _previous: StructureFormState,
  form: FormData,
): Promise<StructureFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result = await apiFetch(`/admin/structure/branches/${id}/move`, {
    method: "POST",
    body: { companyId: text(form, "companyId") },
  });
  if (!result.ok) return failure(result.error);
  refresh();
  return { done: true };
}
