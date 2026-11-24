"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";

export interface UserFormState {
  error?: ApiError;
  done?: boolean;
  temporaryPassword?: string;
}

const text = (form: FormData, field: string) =>
  String(form.get(field) ?? "").trim();
const checked = (form: FormData, field: string) => form.get(field) === "on";

function handleFailure(error: ApiError): UserFormState {
  if (error.code === "FA402") redirect("/login?next=/usuarios&expired=1");
  if (error.code === "FA403") redirect("/trocar-senha");
  return { error };
}

export async function createUser(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch("/admin/users", {
    method: "POST",
    body: {
      name: text(form, "name"),
      email: text(form, "email") || null,
    },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function updateUser(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch(`/admin/users/${text(form, "id")}`, {
    method: "PATCH",
    body: {
      name: text(form, "name"),
      email: text(form, "email") || null,
      isActive: checked(form, "isActive"),
    },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function setUserBranches(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch(`/admin/users/${text(form, "id")}/branches`, {
    method: "PUT",
    body: { branchIds: form.getAll("branchIds").map(String) },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function assignRole(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch(`/admin/users/${text(form, "id")}/roles`, {
    method: "POST",
    body: {
      roleId: text(form, "roleId"),
      branchId: text(form, "branchId") || null,
    },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function removeRole(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch(`/admin/user-roles/${text(form, "userRoleId")}/remove`, {
    method: "POST",
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

/** PIN do PDV. Os dois campos precisam bater; as regras do PIN ficam na API. */
export async function setPdvPin(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const pin = String(form.get("pin") ?? "");
  if (pin !== String(form.get("confirmation") ?? "")) {
    return {
      error: {
        code: "FA965",
        message: "Os dois PINs digitados são diferentes.",
        action: "Digite o mesmo PIN nos dois campos.",
        retryable: false,
        traceId: null,
      },
    };
  }
  const result = await apiFetch(`/admin/users/${text(form, "id")}/pin`, {
    method: "POST",
    body: { pin },
  });
  if (!result.ok) return handleFailure(result.error);
  return { done: true };
}

export async function setPdvAuthMode(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch(`/admin/users/${text(form, "id")}/auth-mode`, {
    method: "POST",
    body: { mode: text(form, "mode") },
  });
  if (!result.ok) return handleFailure(result.error);
  refresh();
  return { done: true };
}

export async function issueTemporaryPassword(
  _previous: UserFormState,
  form: FormData,
): Promise<UserFormState> {
  const result = await apiFetch<{ temporaryPassword: string }>(
    `/admin/users/${text(form, "id")}/temporary-password`,
    { method: "POST" },
  );
  if (!result.ok) return handleFailure(result.error);
  return { temporaryPassword: result.data.temporaryPassword };
}
