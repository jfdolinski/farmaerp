"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface FiscalFormState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, name: string) => {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
};

function finish(result: { ok: true } | { ok: false; error: ApiError }): FiscalFormState {
  if (!result.ok) {
    if (result.error.code === "FA402") {
      redirect("/login?next=%2Ffiscal&expired=1");
    }
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}

export async function setDfe(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(
    await apiFetch(`/admin/branches/${id}/dfe`, { method: "POST", body: { enabled: text(form, "enabled") === "true" } }),
  );
}

export async function setRegime(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "companyId"));
  return finish(
    await apiFetch(`/admin/fiscal/companies/${id}/regime`, {
      method: "PATCH",
      body: { regime: Number(text(form, "regime")) },
    }),
  );
}

export async function setStateRegistration(
  _previous: FiscalFormState,
  form: FormData,
): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(
    await apiFetch(`/admin/fiscal/branches/${id}/state-registration`, {
      method: "PATCH",
      body: { stateRegistration: text(form, "stateRegistration") },
    }),
  );
}

/** O arquivo e a senha só passam por aqui a caminho da API; nada fica guardado na retaguarda. */
export async function uploadCertificate(
  _previous: FiscalFormState,
  form: FormData,
): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  const file = form.get("file");
  const content = file instanceof File ? Buffer.from(await file.arrayBuffer()).toString("base64") : "";
  return finish(
    await apiFetch(`/admin/fiscal/branches/${id}/certificate`, {
      method: "POST",
      body: { file: content, password: text(form, "password") },
    }),
  );
}

export async function copyCertificate(
  _previous: FiscalFormState,
  form: FormData,
): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(
    await apiFetch(`/admin/fiscal/branches/${id}/certificate/copy`, {
      method: "POST",
      body: { targets: form.getAll("targets").map(String) },
    }),
  );
}

export async function setCsc(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(
    await apiFetch(`/admin/fiscal/branches/${id}/csc`, {
      method: "PUT",
      body: { cscId: text(form, "cscId"), token: text(form, "token") },
    }),
  );
}

export async function setSeries(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "id"));
  // Só dígitos: "1.234" é mil duzentos e trinta e quatro. Vazio vira um valor que o banco recusa com clareza.
  const whole = (name: string) => {
    const digits = text(form, name).replace(/\D/g, "");
    return digits === "" ? 0 : Number(digits);
  };
  return finish(
    await apiFetch(`/admin/fiscal/series/${id}`, {
      method: "PATCH",
      body: { series: whole("series"), initialNumber: whole("initialNumber") },
    }),
  );
}

export async function setNfce(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(
    await apiFetch(`/admin/fiscal/branches/${id}/nfce`, {
      method: "PUT",
      body: {
        enabled: text(form, "enabled") === "true",
        environment: Number(text(form, "environment")),
        contingencyHours: Number(text(form, "contingencyHours")),
      },
    }),
  );
}

const RETURN_TAX_FIELDS = [
  "cfop_internal",
  "cfop_interstate",
  "cfop_st_internal",
  "cfop_st_interstate",
  "simples_csosn",
  "simples_csosn_st",
  "normal_cst",
  "normal_cst_st",
  "pis_cst",
  "cofins_cst",
  "transfer_cfop_internal",
  "transfer_cfop_interstate",
  "transfer_cfop_st_internal",
  "transfer_cfop_st_interstate",
];

/** Padrões fiscais da NF-e de devolução da filial. O banco confere a permissão e os valores. */
export async function setReturnTax(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  const body = Object.fromEntries(RETURN_TAX_FIELDS.map((field) => [field, text(form, field).trim()]));
  return finish(await apiFetch(`/admin/fiscal/return-tax/${id}`, { method: "PATCH", body }));
}

export async function resetReturnTax(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(await apiFetch(`/admin/fiscal/return-tax/${id}/reset`, { method: "POST" }));
}

/** Chave da filial no Catálogo: a API confere no Catálogo antes de guardar. */
export async function setCatalogKey(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(await apiFetch(`/admin/catalog-keys/${id}`, { method: "PUT", body: { key: text(form, "key") } }));
}

export async function clearCatalogKey(_previous: FiscalFormState, form: FormData): Promise<FiscalFormState> {
  const id = encodeURIComponent(text(form, "branchId"));
  return finish(await apiFetch(`/admin/catalog-keys/${id}`, { method: "DELETE" }));
}
