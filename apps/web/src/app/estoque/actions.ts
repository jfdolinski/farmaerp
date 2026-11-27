"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface StockFormState {
  error?: ApiError;
  done?: boolean;
  unchanged?: boolean;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();
const optional = (form: FormData, field: string) => text(form, field) || null;

function handleFailure(error: ApiError, next: string): StockFormState {
  if (error.code === "FA402") {
    redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  }
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

/** Aceita vírgula. O que não for número segue como texto para a API recusar. */
function quantityValue(raw: string): number | string {
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return value === "" || Number.isNaN(parsed) ? raw : parsed;
}

/** Liberação do supervisor, quando a tela pediu: código ou e-mail, senha e motivo. */
function releaseOf(form: FormData) {
  const identifier = text(form, "supervisorIdentifier");
  if (!identifier) return undefined;
  return {
    identifier,
    password: String(form.get("supervisorPassword") ?? ""),
    reason: optional(form, "releaseReason"),
  };
}

export async function registerMovement(
  _previous: StockFormState,
  form: FormData,
): Promise<StockFormState> {
  const kind = text(form, "kind");
  const release = releaseOf(form);
  const common = {
    productLookup: text(form, "productLookup"),
    branchId: text(form, "branchId"),
    quantity: quantityValue(text(form, "quantity")),
    batchNumber: optional(form, "batchNumber"),
    reason: optional(form, "reason"),
  };
  if (kind === "transfer") {
    const result = await apiFetch("/admin/stock/transfers", {
      method: "POST",
      body: {
        productLookup: common.productLookup,
        fromBranchId: common.branchId,
        toBranchId: text(form, "toBranchId"),
        quantity: common.quantity,
        batchNumber: common.batchNumber,
        reason: common.reason,
      },
    });
    if (!result.ok) return handleFailure(result.error, "/estoque");
    refresh();
    return { done: true };
  }
  if (kind === "count") {
    const result = await apiFetch<{ changed: boolean }>("/admin/stock/counts", {
      method: "POST",
      body: {
        productLookup: common.productLookup,
        branchId: common.branchId,
        countedQuantity: common.quantity,
        batchNumber: common.batchNumber,
        expiresOn: optional(form, "expiresOn"),
        msRegistration: optional(form, "msRegistration"),
        reason: common.reason,
        release,
      },
    });
    if (!result.ok) return handleFailure(result.error, "/estoque");
    refresh();
    return { done: true, unchanged: !result.data.changed };
  }
  const result =
    kind === "loss"
      ? await apiFetch("/admin/stock/losses", { method: "POST", body: { ...common, release } })
      : await apiFetch("/admin/stock/adjustments", {
          method: "POST",
          body: {
            ...common,
            direction: kind === "out" ? "out" : "in",
            expiresOn: optional(form, "expiresOn"),
            msRegistration: optional(form, "msRegistration"),
            release,
          },
        });
  if (!result.ok) return handleFailure(result.error, "/estoque");
  refresh();
  return { done: true };
}

export async function reverseMovement(
  _previous: StockFormState,
  form: FormData,
): Promise<StockFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result = await apiFetch(`/admin/stock/movements/${id}/reverse`, {
    method: "POST",
    body: { reason: optional(form, "reason") },
  });
  if (!result.ok) return handleFailure(result.error, "/estoque");
  refresh();
  return { done: true };
}

export async function updateBatch(
  _previous: StockFormState,
  form: FormData,
): Promise<StockFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result = await apiFetch(`/admin/stock/batches/${id}`, {
    method: "PATCH",
    body: {
      batchNumber: text(form, "batchNumber"),
      expiresOn: optional(form, "expiresOn"),
      msRegistration: optional(form, "msRegistration"),
      reason: optional(form, "reason"),
    },
  });
  if (!result.ok) return handleFailure(result.error, "/estoque");
  refresh();
  return { done: true };
}

export async function setBatchTracking(
  _previous: StockFormState,
  form: FormData,
): Promise<StockFormState> {
  const id = encodeURIComponent(text(form, "productId"));
  const result = await apiFetch(`/admin/products/${id}/batch-tracking`, {
    method: "POST",
    body: { branchId: text(form, "branchId"), tracks: text(form, "tracks") === "1" },
  });
  if (!result.ok) return handleFailure(result.error, `/produtos/${id}`);
  refresh();
  return { done: true };
}

export interface TransferNfeState {
  error?: ApiError;
  notice?: string;
}

const NFE_RESULT: Record<string, string> = {
  authorized: "NF-e autorizada pela Sefaz.",
  pending: "A Sefaz não respondeu. A NF-e ficou pendente: tente transmitir de novo em alguns minutos.",
  rejected: "A Sefaz recusou a NF-e. Veja o motivo, corrija e emita de novo.",
};

/** Emite a NF-e da transferência entre filiais (ou transmite de novo a pendente). */
export async function emitTransferNfe(_previous: TransferNfeState, form: FormData): Promise<TransferNfeState> {
  const transferId = text(form, "transferId");
  const result = await apiFetch<{ id: string; status: string }>(
    `/admin/stock-transfers/${encodeURIComponent(transferId)}/nfe`,
    { method: "POST", timeoutMs: 90_000 },
  );
  if (!result.ok) return handleFailure(result.error, "/estoque?aba=movimentacoes");
  refresh();
  return { notice: NFE_RESULT[result.data.status] ?? "NF-e processada." };
}
