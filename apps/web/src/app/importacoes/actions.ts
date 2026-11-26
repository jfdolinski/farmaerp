"use server";

import { apiFetch, type ApiResult } from "@/lib/api";

/** Abre a importação (nome e tamanho); as partes seguem pela rota de envio. */
export async function startImport(fileName: string, size: number): Promise<ApiResult<{ id: string; partBytes: number }>> {
  return apiFetch<{ id: string; partBytes: number }>("/admin/imports", { method: "POST", body: { fileName, size } });
}

/** Todas as partes chegaram: o arquivo entra na fila. */
export async function completeImport(id: string): Promise<ApiResult<{ status: string }>> {
  return apiFetch<{ status: string }>(`/admin/imports/${encodeURIComponent(id)}/complete`, { method: "POST" });
}
