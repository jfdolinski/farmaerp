import { getError } from "@farmaerp/error-catalog";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { SESSION_COOKIE } from "./session-cookie";

export interface ApiError {
  code: string;
  message: string;
  action: string;
  retryable: boolean;
  traceId: string | null;
}

export type ApiResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: ApiError };

export interface CurrentUser {
  userId: string;
  name: string;
  email: string | null;
  code: number;
  isAdmin: boolean;
  mustChangePassword: boolean;
}

function unavailable(): ApiError {
  const { code, message, action, retryable } = getError("FA001");
  return { code, message, action, retryable, traceId: null };
}

/** O último endereço é o que o proxy do servidor viu, e não pode ser forjado pelo navegador. */
async function clientIp(): Promise<string | null> {
  const forwarded = (await headers()).get("x-forwarded-for");
  return forwarded?.split(",").at(-1)?.trim() || null;
}

/** Chama a API. Toda falha volta como erro do catálogo, pronto para mostrar. */
export async function apiFetch<T>(
  path: string,
  options: { method?: "GET" | "POST" | "PATCH" | "PUT"; body?: unknown } = {},
): Promise<ApiResult<T>> {
  let response: Response;
  try {
    const apiUrl = process.env.API_URL ?? "http://127.0.0.1:3001";
    const token = (await cookies()).get(SESSION_COOKIE)?.value;
    const ip = await clientIp();
    response = await fetch(`${apiUrl}${path}`, {
      method: options.method ?? "GET",
      cache: "no-store",
      signal: AbortSignal.timeout(10_000),
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        // O limite de tentativas precisa ver o IP de quem usa, não o da retaguarda.
        ...(ip ? { "X-Forwarded-For": ip } : {}),
      },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });
  } catch {
    return { ok: false, error: unavailable() };
  }

  try {
    const payload: unknown = await response.json();
    return response.ok
      ? { ok: true, data: payload as T }
      : { ok: false, error: payload as ApiError };
  } catch {
    return { ok: false, error: unavailable() };
  }
}

/** Sessão expirada, ou troca de senha pendente, levam direto à tela certa. */
export function redirectIfNeeded(error: ApiError, next = "/terminais"): void {
  if (error.code === "FA402") {
    redirect(`/login?next=${encodeURIComponent(next)}&expired=1`);
  }
  if (error.code === "FA403") {
    redirect("/trocar-senha");
  }
}

/** Usuário da sessão. A API confere no banco a cada requisição, por isso não há cache. */
export async function requireUser(next?: string): Promise<CurrentUser> {
  const result = await apiFetch<CurrentUser>("/auth/me");
  if (!result.ok) {
    redirectIfNeeded(result.error, next);
    throw new Error(result.error.message);
  }
  if (result.data.mustChangePassword) {
    redirect("/trocar-senha");
  }
  return result.data;
}
