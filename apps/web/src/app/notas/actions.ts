"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { CatalogRow } from "../produtos/catalog-results";

export interface ImportResult {
  id?: string;
  error?: ApiError;
}

export interface ItemFormState {
  error?: ApiError;
  done?: boolean;
  notice?: string;
}

export interface ProductOption {
  id: string;
  code: string;
  display_name: string;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

function failure(error: ApiError, next: string): { error: ApiError } {
  if (error.code === "FA402") redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

/** Um arquivo por chamada: assim cada nota tem seu próprio resultado na tela. */
export async function importXml(xml: string): Promise<ImportResult> {
  const result = await apiFetch<{ id: string }>("/admin/purchase-invoices", { method: "POST", xml });
  if (!result.ok) return failure(result.error, "/notas");
  return { id: result.data.id };
}

export async function refreshInvoices(): Promise<void> {
  refresh();
}

export async function searchProducts(query: string): Promise<{ rows?: ProductOption[]; error?: ApiError }> {
  const result = await apiFetch<ProductOption[]>(`/admin/products?q=${encodeURIComponent(query.trim())}`);
  return result.ok ? { rows: result.data.slice(0, 20) } : { error: result.error };
}

export async function searchCatalog(query: string): Promise<{ rows?: CatalogRow[]; error?: ApiError }> {
  const result = await apiFetch<CatalogRow[]>(`/admin/catalog?q=${encodeURIComponent(query.trim())}`);
  return result.ok ? { rows: result.data.slice(0, 20) } : { error: result.error };
}

/** Ligar, duplicar ou cadastrar pelo Catálogo: o botão clicado decide. */
export async function itemAction(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const itemId = encodeURIComponent(text(form, "itemId"));
  const next = `/notas/${text(form, "invoiceId")}`;
  const barcode = text(form, "barcode") || null;
  const barcodeIsInternal = form.get("barcodeIsInternal") === "on";
  const intent = text(form, "intent");

  if (intent === "link") {
    const result = await apiFetch<{ barcodeAdded: boolean; barcodeConflict: boolean }>(
      `/admin/purchase-invoice-items/${itemId}/link`,
      { method: "POST", body: { productId: text(form, "productId") } },
    );
    if (!result.ok) return failure(result.error, next);
    refresh();
    return {
      done: true,
      notice: result.data.barcodeConflict
        ? "Item ligado. O código de barras da nota já é de outro produto, então não foi acrescentado."
        : result.data.barcodeAdded
          ? "Item ligado. O código de barras da nota foi acrescentado ao produto."
          : "Item ligado.",
    };
  }
  const result =
    intent === "duplicate"
      ? await apiFetch(`/admin/purchase-invoice-items/${itemId}/duplicate`, {
          method: "POST",
          body: {
            sourceProductId: text(form, "productId"),
            displayName: text(form, "displayName") || null,
            barcode,
            barcodeIsInternal,
          },
        })
      : await apiFetch(`/admin/purchase-invoice-items/${itemId}/catalog`, {
          method: "POST",
          body: {
            catalogProductId: text(form, "catalogProductId"),
            displayName: text(form, "displayName"),
            barcode,
            barcodeIsInternal,
          },
        });
  if (!result.ok) return failure(result.error, next);
  refresh();
  return { done: true, notice: "Produto cadastrado e ligado ao item." };
}

/** Ciência da operação de uma nota. A tela chama uma por vez e mostra o resultado de cada. */
export async function giveAwareness(summaryId: string): Promise<{ error?: ApiError }> {
  const result = await apiFetch(`/admin/purchase-summaries/${encodeURIComponent(summaryId)}/awareness`, { method: "POST", body: {} });
  if (!result.ok) return failure(result.error, "/notas");
  return {};
}

export async function refreshSummaries(): Promise<void> {
  refresh();
}

export async function postInvoice(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const id = text(form, "id");
  const result = await apiFetch(`/admin/purchase-invoices/${encodeURIComponent(id)}/post`, { method: "POST", body: {} });
  if (!result.ok) return failure(result.error, `/notas/${id}`);
  refresh();
  return { done: true, notice: "Nota lançada no estoque." };
}

export async function reverseInvoice(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const id = text(form, "id");
  const result = await apiFetch(`/admin/purchase-invoices/${encodeURIComponent(id)}/reverse`, {
    method: "POST",
    body: { reason: text(form, "reason") },
  });
  if (!result.ok) return failure(result.error, `/notas/${id}`);
  refresh();
  return { done: true, notice: "Lançamento estornado. A nota voltou para a conferência." };
}

export async function cancelInvoice(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const id = text(form, "id");
  const result = await apiFetch(`/admin/purchase-invoices/${encodeURIComponent(id)}/cancel`, {
    method: "POST",
    body: { reason: text(form, "reason") },
  });
  if (!result.ok) return failure(result.error, `/notas/${id}`);
  refresh();
  return { done: true, notice: "Nota cancelada." };
}

/** Fracionamento digitado com vírgula ou ponto; o banco confere o valor. */
export async function changeItemFraction(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const itemId = text(form, "itemId");
  const next = `/notas/${text(form, "invoiceId")}`;
  const raw = text(form, "fraction").replace(",", ".");
  const fraction = raw === "" ? NaN : Number(raw);
  if (!Number.isFinite(fraction) || fraction <= 0) {
    return {
      error: { code: "FA005", message: "Informe o fracionamento com números, maior que zero.", action: "Exemplo: 10 ou 2,5.", traceId: null, retryable: false },
    };
  }
  const result = await apiFetch(`/admin/purchase-invoice-items/${encodeURIComponent(itemId)}/fraction`, {
    method: "POST",
    body: { fraction, reason: text(form, "reason") },
  });
  if (!result.ok) return failure(result.error, next);
  refresh();
  return { done: true, notice: "Fracionamento alterado. O estoque e o custo foram acertados." };
}

/** Lotes digitados: cada linha do formulário vira um lote; linha toda vazia é ignorada. */
export async function saveItemBatches(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const itemId = text(form, "itemId");
  const next = `/notas/${text(form, "invoiceId")}`;
  const column = (field: string) => form.getAll(field).map((value) => String(value).trim());
  const numbers = column("number");
  const quantities = column("quantity");
  const expires = column("expiresOn");
  const manufactured = column("manufacturedOn");
  const batches = numbers
    .map((number, index) => ({
      number,
      quantity: quantities[index] ? quantities[index].replace(",", ".") : "",
      expiresOn: expires[index] ?? "",
      manufacturedOn: manufactured[index] || null,
    }))
    .filter((batch) => batch.number || batch.quantity || batch.expiresOn);
  const result = await apiFetch(`/admin/purchase-invoice-items/${encodeURIComponent(itemId)}/batches`, {
    method: "POST",
    body: { batches },
  });
  if (!result.ok) return failure(result.error, next);
  refresh();
  return { done: true, notice: "Lotes salvos." };
}

export async function releaseItemCost(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const itemId = text(form, "itemId");
  const result = await apiFetch(`/admin/purchase-invoice-items/${encodeURIComponent(itemId)}/release-cost`, {
    method: "POST",
    body: { reason: text(form, "reason"), password: String(form.get("password") ?? "") },
  });
  if (!result.ok) return failure(result.error, `/notas/${text(form, "invoiceId")}`);
  refresh();
  return { done: true, notice: "Custo liberado." };
}

export async function discardInvoice(_previous: ItemFormState, form: FormData): Promise<ItemFormState> {
  const id = text(form, "id");
  const result = await apiFetch(`/admin/purchase-invoices/${encodeURIComponent(id)}/discard`, {
    method: "POST",
    body: { reason: text(form, "reason") },
  });
  if (!result.ok) return failure(result.error, `/notas/${id}`);
  redirect("/notas");
}
