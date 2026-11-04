export const SESSION_COOKIE = "farmaerp_session";

/** Só caminhos internos: evita redirecionar para outro site depois do login. */
export function safeNextPath(value: unknown): string {
  return typeof value === "string" &&
    value.startsWith("/") &&
    !value.startsWith("//") &&
    !value.startsWith("/\\")
    ? value
    : "/terminais";
}
