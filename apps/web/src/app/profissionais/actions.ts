"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, type ApiError } from "@/lib/api";

export interface ProfessionalFormState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, name: string) => {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
};

/** Inclui (sem id) ou altera. As regras (repetido, formato) ficam no banco. */
export async function saveProfessional(_previous: ProfessionalFormState, form: FormData): Promise<ProfessionalFormState> {
  const id = text(form, "id");
  const body = {
    name: text(form, "name"),
    council: text(form, "council"),
    registration: text(form, "registration"),
    state: text(form, "state"),
    specialty: text(form, "specialty"),
    ...(id ? { active: text(form, "active") === "true" } : {}),
  };
  const result = id
    ? await apiFetch(`/admin/health-professionals/${encodeURIComponent(id)}`, { method: "PUT", body })
    : await apiFetch("/admin/health-professionals", { method: "POST", body });
  if (!result.ok) {
    if (result.error.code === "FA402") redirect("/login?next=%2Fprofissionais&expired=1");
    if (result.error.code === "FA403") redirect("/trocar-senha");
    return { error: result.error };
  }
  refresh();
  return { done: true };
}
