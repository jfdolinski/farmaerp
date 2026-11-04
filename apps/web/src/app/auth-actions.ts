"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import { safeNextPath, SESSION_COOKIE } from "@/lib/session-cookie";

export interface AuthFormState {
  error?: ApiError;
}

const SESSION_MAX_AGE_SECONDS = 12 * 60 * 60;

export async function login(
  _previous: AuthFormState,
  form: FormData,
): Promise<AuthFormState> {
  const result = await apiFetch<{ token: string; mustChangePassword: boolean }>(
    "/auth/login",
    {
      method: "POST",
      body: {
        email: String(form.get("email") ?? ""),
        password: String(form.get("password") ?? ""),
      },
    },
  );
  if (!result.ok) {
    return { error: result.error };
  }

  (await cookies()).set(SESSION_COOKIE, result.data.token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production" && process.env.APP_ENV !== "development",
    sameSite: "lax",
    path: "/",
    maxAge: SESSION_MAX_AGE_SECONDS,
  });

  redirect(
    result.data.mustChangePassword
      ? "/trocar-senha"
      : safeNextPath(form.get("next")),
  );
}

export async function logout(): Promise<void> {
  await apiFetch("/auth/logout", { method: "POST" });
  (await cookies()).delete(SESSION_COOKIE);
  redirect("/login");
}

export async function changePassword(
  _previous: AuthFormState,
  form: FormData,
): Promise<AuthFormState> {
  const result = await apiFetch("/auth/change-password", {
    method: "POST",
    body: {
      currentPassword: String(form.get("currentPassword") ?? ""),
      newPassword: String(form.get("newPassword") ?? ""),
    },
  });
  if (!result.ok) {
    if (result.error.code === "FA402") {
      redirect("/login?expired=1");
    }
    return { error: result.error };
  }
  redirect("/terminais");
}
