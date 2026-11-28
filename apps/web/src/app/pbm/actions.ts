"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, type ApiError } from "@/lib/api";

export interface PbmState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) => String(form.get(field) ?? "").trim();

async function send(path: string, method: "POST" | "PATCH", body: unknown): Promise<PbmState> {
  const result = await apiFetch(path, { method, body });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=/pbm&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}

/** Novo programa (por enquanto, só o de teste). */
export async function createProgram(_previous: PbmState, form: FormData): Promise<PbmState> {
  return send("/admin/pbm/programs", "POST", { name: text(form, "name") });
}

/** Liga ou desliga o programa na rede inteira. */
export async function setProgramActive(_previous: PbmState, form: FormData): Promise<PbmState> {
  return send(`/admin/pbm/programs/${encodeURIComponent(text(form, "id"))}`, "PATCH", { active: text(form, "active") === "true" });
}

/** Liga ou desliga o programa numa filial. */
export async function setBranchActive(_previous: PbmState, form: FormData): Promise<PbmState> {
  const program = encodeURIComponent(text(form, "id"));
  const branch = encodeURIComponent(text(form, "branchId"));
  return send(`/admin/pbm/programs/${program}/branches/${branch}`, "POST", { active: text(form, "active") === "true" });
}

/** Dados de acesso do programa na filial: só os campos preenchidos vão, e nunca voltam para a tela. */
export async function setCredentials(_previous: PbmState, form: FormData): Promise<PbmState> {
  const program = encodeURIComponent(text(form, "id"));
  const branch = encodeURIComponent(text(form, "branchId"));
  const credentials: Record<string, string> = {};
  for (const field of ["usuario", "senha", "codigoLoja"]) {
    const value = String(form.get(field) ?? "");
    if (value !== "") credentials[field] = value;
  }
  return send(`/admin/pbm/programs/${program}/branches/${branch}/credentials`, "POST", { credentials });
}

/** Produto no programa de teste, com o percentual (vazio tira o produto). */
export async function setRule(_previous: PbmState, form: FormData): Promise<PbmState> {
  const raw = text(form, "percent").replace(",", ".");
  const percent = raw === "" ? null : Number(raw);
  const productId = text(form, "productId");
  return send(`/admin/pbm/programs/${encodeURIComponent(text(form, "id"))}/rules`, "POST", {
    ...(productId ? { productId } : { productLookup: text(form, "productLookup") }),
    percent: percent === null || Number.isNaN(percent) ? (raw === "" ? null : raw) : percent,
  });
}
