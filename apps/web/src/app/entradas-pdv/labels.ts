/** Forma de entrar no PDV configurada para a pessoa. */
export const AUTH_MODE_LABELS: Record<string, string> = {
  any: "Qualquer uma (PIN, câmera ou digital)",
  pin: "Só PIN",
  face: "Só câmera",
  fingerprint: "Só digital",
};

/** Forma usada em cada entrada. */
export const AUTH_METHOD_LABELS: Record<string, string> = {
  pin: "PIN",
  face: "Câmera",
  fingerprint: "Digital",
  manager_release: "Liberação do gerente",
};

export const AUTH_PURPOSE_LABELS: Record<string, string> = {
  login: "Entrar no caixa",
  approval: "Liberar",
  seller: "Vendedor",
};

export const AUTH_EVENT_LABELS: Record<string, string> = {
  success: "Entrou",
  failure: "Errou",
  locked: "Bloqueado por tentativas",
};

export const AUTH_ALERT_LABELS: Record<string, string> = {
  outside_mode: "Entrou por uma forma que não é a dela",
  release_permission: "Liberada por quem não tinha a permissão",
};
