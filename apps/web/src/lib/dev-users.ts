// Identidade só de desenvolvimento: usuários do seed em db/seeds/dev.sql.
// A API não inicia em produção enquanto este modo existir.
export const DEV_USER_COOKIE = "farmaerp_dev_user";

export const DEV_USERS = [
  { id: "019a0000-0000-7000-8000-000000000008", name: "Administrador" },
  { id: "019a0000-0000-7000-8000-000000000009", name: "Operador Centro" },
] as const;
