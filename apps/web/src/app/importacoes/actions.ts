"use server";

import { apiFetch, type ApiResult } from "@/lib/api";

/** Abre a importação (nome e tamanho); as partes seguem pela rota de envio. */
export async function startImport(
  fileName: string,
  size: number,
): Promise<ApiResult<{ id: string; partBytes: number }>> {
  return apiFetch<{ id: string; partBytes: number }>("/admin/imports", { method: "POST", body: { fileName, size } });
}

/** Importação pela Plataforma: o arquivo vai para o cliente escolhido (o banco confere quem pode). */
export async function startPlatformImport(
  groupId: string,
  fileName: string,
  size: number,
): Promise<ApiResult<{ id: string; partBytes: number }>> {
  return apiFetch<{ id: string; partBytes: number }>("/platform/imports", {
    method: "POST",
    body: { groupId, fileName, size },
  });
}

export async function completePlatformImport(id: string): Promise<ApiResult<{ status: string }>> {
  return apiFetch<{ status: string }>(`/platform/imports/${encodeURIComponent(id)}/complete`, { method: "POST" });
}

/** Todas as partes chegaram: o arquivo entra na fila. */
export async function completeImport(id: string): Promise<ApiResult<{ status: string }>> {
  return apiFetch<{ status: string }>(`/admin/imports/${encodeURIComponent(id)}/complete`, { method: "POST" });
}
