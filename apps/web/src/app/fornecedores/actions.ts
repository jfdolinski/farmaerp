"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface SupplierFormState {
  error?: ApiError;
  done?: boolean;
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

/** Aceita vírgula. O que não for número segue como texto para a API recusar, em vez de virar o padrão. */
function fraction(form: FormData, field: string): number | string | null {
  const value = text(form, field).replace(",", ".");
  if (value === "") return null;
  const parsed = Number(value);
  return Number.isNaN(parsed) ? value : parsed;
}

function failure(error: ApiError, next: string): SupplierFormState {
  if (error.code === "FA402") redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

const supplierBody = (form: FormData) => ({
  legalName: text(form, "legalName"),
  tradeName: text(form, "tradeName"),
  stateRegistration: text(form, "stateRegistration"),
  phone: text(form, "phone"),
  email: text(form, "email"),
  postalCode: text(form, "postalCode"),
  street: text(form, "street"),
  streetNumber: text(form, "streetNumber"),
  complement: text(form, "complement"),
  district: text(form, "district"),
  city: text(form, "city"),
  cityCode: text(form, "cityCode"),
  state: text(form, "state"),
});

/** Só preenche a tela: nada é gravado até a pessoa conferir e salvar. */
export async function lookupCnpj(_previous: LookupState, form: FormData): Promise<LookupState> {
  const document = text(form, "document");
  const clean = document.replace(/[^0-9A-Za-z]/g, "");
  const result = await apiFetch<CnpjData>(`/admin/customers/cnpj/${encodeURIComponent(clean)}`);
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=%2Ffornecedores%2Fnovo&expired=1");
    return { error: result.error, document };
  }
  return { data: result.data, document };
}

export async function createSupplier(_previous: SupplierFormState, form: FormData): Promise<SupplierFormState> {
  const result = await apiFetch<{ id: string }>("/admin/suppliers", {
    method: "POST",
    body: { cnpj: text(form, "cnpj"), ...supplierBody(form) },
  });
  if (!result.ok) return failure(result.error, "/fornecedores/novo");
  redirect(`/fornecedores/${result.data.id}`);
}

/** Salvar ou encerrar o fornecedor: o botão clicado decide. */
export async function changeSupplier(_previous: SupplierFormState, form: FormData): Promise<SupplierFormState> {
  const id = text(form, "id");
  const path = `/fornecedores/${id}`;
  if (text(form, "intent") === "delete") {
    const removed = await apiFetch(`/admin/suppliers/${encodeURIComponent(id)}/delete`, { method: "POST" });
    if (!removed.ok) return failure(removed.error, path);
    redirect("/fornecedores");
  }
  const result = await apiFetch(`/admin/suppliers/${encodeURIComponent(id)}`, {
    method: "PATCH",
    body: supplierBody(form),
  });
  if (!result.ok) return failure(result.error, path);
  refresh();
  return { done: true };
}

export async function addProductSupplier(_previous: SupplierFormState, form: FormData): Promise<SupplierFormState> {
  const productId = text(form, "productId");
  const result = await apiFetch(`/admin/products/${encodeURIComponent(productId)}/suppliers`, {
    method: "POST",
    body: {
      supplierId: text(form, "supplierId"),
      supplierCode: text(form, "supplierCode"),
      fractionQuantity: fraction(form, "fractionQuantity"),
    },
  });
  if (!result.ok) return failure(result.error, `/produtos/${productId}`);
  refresh();
  return { done: true };
}

/** Salvar o fracionamento ou remover o código: o botão clicado decide. */
export async function changeProductSupplier(_previous: SupplierFormState, form: FormData): Promise<SupplierFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const next = text(form, "next") || "/fornecedores";
  const result =
    text(form, "intent") === "remove"
      ? await apiFetch(`/admin/product-suppliers/${id}/remove`, { method: "POST" })
      : await apiFetch(`/admin/product-suppliers/${id}`, {
          method: "PATCH",
          body: { fractionQuantity: fraction(form, "fractionQuantity") },
        });
  if (!result.ok) return failure(result.error, next);
  refresh();
  return { done: true };
}
