"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface RuleFormState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();
const optional = (form: FormData, field: string) => text(form, field) || null;

function handleFailure(error: ApiError): RuleFormState {
  if (error.code === "FA402") redirect("/login?next=/regras&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

/** Aceita vírgula. O que não for número segue como texto para a API recusar. */
function numberValue(raw: string): number | string {
  const value = raw.includes(",") ? raw.replaceAll(".", "").replace(",", ".") : raw;
  const parsed = Number(value);
  return value === "" || Number.isNaN(parsed) ? raw : parsed;
}

function priorityValue(raw: string): number | string | null {
  return raw === "" ? null : numberValue(raw);
}

// A tela trabalha com dias no fuso da operação: o início vale do primeiro instante, e o fim, até o último.
const startOfDay = (day: string) => (day ? `${day}T00:00:00.000-03:00` : null);
const endOfDay = (day: string) => (day ? `${day}T23:59:59.999-03:00` : null);

const editableFields = (form: FormData) => ({
  value: numberValue(text(form, "value")),
  priority: priorityValue(text(form, "priority")),
  validFrom: startOfDay(text(form, "validFrom")),
  validTo: endOfDay(text(form, "validTo")),
  reason: optional(form, "reason"),
});

export async function createRule(
  _previous: RuleFormState,
  form: FormData,
): Promise<RuleFormState> {
  const result = await apiFetch("/admin/rules", {
    method: "POST",
    body: {
      ...editableFields(form),
      typeCode: text(form, "typeCode"),
      level: text(form, "level"),
      productLookup: optional(form, "productLookup"),
      productGroupId: optional(form, "productGroupId"),
      manufacturerId: optional(form, "manufacturerId"),
      categoryId: optional(form, "categoryId"),
      branchId: optional(form, "branchId"),
    },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

/** Salvar e encerrar ficam no mesmo formulário: o botão clicado decide. */
export async function changeRule(
  _previous: RuleFormState,
  form: FormData,
): Promise<RuleFormState> {
  const id = encodeURIComponent(text(form, "id"));
  const result =
    text(form, "intent") === "end"
      ? await apiFetch(`/admin/rules/${id}/end`, { method: "POST" })
      : await apiFetch(`/admin/rules/${id}`, {
          method: "PATCH",
          body: editableFields(form),
        });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}
