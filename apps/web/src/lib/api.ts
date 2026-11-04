import { getError } from "@farmaerp/error-catalog";
import { cookies } from "next/headers";
import { DEV_USER_COOKIE, DEV_USERS } from "./dev-users";

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

function unavailable(): ApiError {
  const { code, message, action, retryable } = getError("FA001");
  return { code, message, action, retryable, traceId: null };
}

/** Usuário atual. Identidade só de desenvolvimento, até o login da Etapa 2. */
export async function currentDevUserId(): Promise<string> {
  const store = await cookies();
  const selected = store.get(DEV_USER_COOKIE)?.value;
  return DEV_USERS.some((user) => user.id === selected)
    ? (selected as string)
    : DEV_USERS[0].id;
}

/** Chama a API. Toda falha volta como erro do catálogo, pronto para mostrar. */
export async function apiFetch<T>(
  path: string,
  options: { method?: "GET" | "POST"; body?: unknown } = {},
): Promise<ApiResult<T>> {
  let response: Response;
  try {
    const apiUrl = process.env.API_URL ?? "http://127.0.0.1:3001";
    const internalToken = process.env.ADMIN_INTERNAL_SECRET;
    response = await fetch(`${apiUrl}${path}`, {
      method: options.method ?? "GET",
      cache: "no-store",
      signal: AbortSignal.timeout(10_000),
      headers: {
        "Content-Type": "application/json",
        "X-Dev-User-Id": await currentDevUserId(),
        ...(internalToken ? { "X-Internal-Token": internalToken } : {}),
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
