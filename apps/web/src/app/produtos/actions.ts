"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface ProductFormState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();
const optional = (form: FormData, field: string) => text(form, field) || null;
const checked = (form: FormData, field: string) => form.get(field) === "on";

/** Aceita vírgula. O que não for número segue como texto para a API recusar, em vez de virar o padrão. */
function fraction(form: FormData, field: string): number | string | null {
  const value = text(form, field).replace(",", ".");
  if (value === "") return null;
  const parsed = Number(value);
  return Number.isNaN(parsed) ? value : parsed;
}

function handleFailure(error: ApiError, next: string): ProductFormState {
  if (error.code === "FA402") {
    redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  }
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

const productBody = (form: FormData) => ({
  catalogProductId: optional(form, "catalogProductId"),
  displayName: text(form, "displayName"),
  ownManufacturer: optional(form, "ownManufacturer"),
  categoryId: optional(form, "categoryId"),
  commissionGroupId: optional(form, "commissionGroupId"),
  pricingGroupId: optional(form, "pricingGroupId"),
  priceFamilyId: optional(form, "priceFamilyId"),
  usesPmc: checked(form, "usesPmc"),
  onlineSaleBlocked: checked(form, "onlineSaleBlocked"),
  fractionQuantity: fraction(form, "fractionQuantity"),
});

export async function createProduct(
  _previous: ProductFormState,
  form: FormData,
): Promise<ProductFormState> {
  const result = await apiFetch<{ id: string }>("/admin/products", {
    method: "POST",
    body: {
      ...productBody(form),
      barcode: text(form, "barcode"),
      barcodeIsInternal: checked(form, "barcodeIsInternal"),
    },
  });
  if (!result.ok) return handleFailure(result.error, "/produtos/novo");
  redirect(`/produtos/${result.data.id}`);
}

export async function updateProduct(
  _previous: ProductFormState,
  form: FormData,
): Promise<ProductFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result = await apiFetch(`/admin/products/${id}`, {
    method: "PATCH",
    body: productBody(form),
  });
  if (!result.ok) return handleFailure(result.error, `/produtos/${id}`);
  // Um vínculo com o Catálogo acabou de ser confirmado: tira a escolha do endereço.
  if (text(form, "linking")) redirect(`/produtos/${id}`);
  refresh();
  return { done: true };
}

const barcodeOptions = (form: FormData) => ({
  sendsToSupplier: checked(form, "sendsToSupplier"),
  scanEnabled: checked(form, "scanEnabled"),
  fractionQuantity: fraction(form, "fractionQuantity"),
  channels: form.getAll("channels").map(String),
});

export async function addBarcode(
  _previous: ProductFormState,
  form: FormData,
): Promise<ProductFormState> {
  const id = encodeURIComponent(text(form, "productId"));
  const result = await apiFetch(`/admin/products/${id}/barcodes`, {
    method: "POST",
    body: {
      ...barcodeOptions(form),
      code: text(form, "code"),
      isInternal: checked(form, "isInternal"),
    },
  });
  if (!result.ok) return handleFailure(result.error, `/produtos/${id}`);
  refresh();
  return { done: true };
}

/** Salvar, tornar principal e remover ficam no mesmo formulário: o botão clicado decide. */
export async function changeBarcode(
  _previous: ProductFormState,
  form: FormData,
): Promise<ProductFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const product = text(form, "productId");
  const intent = text(form, "intent");
  const result =
    intent === "primary"
      ? await apiFetch(`/admin/barcodes/${id}/primary`, { method: "POST" })
      : intent === "remove"
        ? await apiFetch(`/admin/barcodes/${id}/remove`, { method: "POST" })
        : await apiFetch(`/admin/barcodes/${id}`, {
            method: "PATCH",
            body: barcodeOptions(form),
          });
  if (!result.ok) return handleFailure(result.error, `/produtos/${product}`);
  refresh();
  return { done: true };
}

const ENTITY_PATHS: Record<string, string> = {
  category: "product-categories",
  group: "product-groups",
  channel: "sales-channels",
};

const entityPath = (form: FormData) => ENTITY_PATHS[text(form, "entity")];

export async function createEntry(
  _previous: ProductFormState,
  form: FormData,
): Promise<ProductFormState> {
  const path = entityPath(form);
  if (!path) return {};
  const result = await apiFetch(`/admin/${path}`, {
    method: "POST",
    body: {
      name: text(form, "name"),
      parentId: optional(form, "parentId"),
      kind: optional(form, "kind"),
    },
  });
  if (!result.ok) return handleFailure(result.error, "/produtos/estrutura");
  refresh();
  return { done: true };
}

export async function changeEntry(
  _previous: ProductFormState,
  form: FormData,
): Promise<ProductFormState> {
  const path = entityPath(form);
  if (!path) return {};
  const id = encodeURIComponent(text(form, "id"));
  const result =
    text(form, "intent") === "delete"
      ? await apiFetch(`/admin/${path}/${id}/delete`, { method: "POST" })
      : await apiFetch(`/admin/${path}/${id}`, {
          method: "PATCH",
          body: { name: text(form, "name") },
        });
  if (!result.ok) return handleFailure(result.error, "/produtos/estrutura");
  refresh();
  return { done: true };
}
