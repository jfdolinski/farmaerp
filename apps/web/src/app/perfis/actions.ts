"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface RoleFormState {
  error?: ApiError;
  done?: boolean;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();

function handleFailure(error: ApiError): RoleFormState {
  if (error.code === "FA402") redirect("/login?next=/perfis&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

const roleBody = (form: FormData) => ({
  name: text(form, "name"),
  description: text(form, "description") || null,
  permissions: form.getAll("permissions").map(String),
});

export async function createRole(
  _previous: RoleFormState,
  form: FormData,
): Promise<RoleFormState> {
  const result = await apiFetch("/admin/roles", {
    method: "POST",
    body: roleBody(form),
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function updateRole(
  _previous: RoleFormState,
  form: FormData,
): Promise<RoleFormState> {
  const result = await apiFetch(`/admin/roles/${text(form, "id")}`, {
    method: "PATCH",
    body: roleBody(form),
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function deleteRole(
  _previous: RoleFormState,
  form: FormData,
): Promise<RoleFormState> {
  const result = await apiFetch(`/admin/roles/${text(form, "id")}/delete`, {
    method: "POST",
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}
