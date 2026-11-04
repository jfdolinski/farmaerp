const MASK = '[protegido]';
const MAX_DEPTH = 8;

// Dados que nunca podem ir para o log (LGPD e segurança).
const SENSITIVE_KEY =
  /^(cpf|cnh|rg|senha|password|passwd|pass|pin|token|access_?token|refresh_?token|secret|authorization|cookie|set-cookie|api_?key|private_?key|cert|certificate|certificado|csc|biometric|biometria|face|face_?code|fingerprint|digital|card|cartao|cvv|body|email|e_?mail|temporary_?password|current_?password|new_?password|password_?hash)$/i;

const CPF_IN_TEXT = /\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b/g;
const EMAIL_IN_TEXT = /[^\s@"'<>]+@[^\s@"'<>]+\.[^\s@"'<>]+/g;

/** Copia um valor mascarando campos sensíveis e CPFs dentro de textos. */
export function sanitize(value: unknown, depth = 0): unknown {
  if (typeof value === 'string') {
    return value.replace(CPF_IN_TEXT, MASK).replace(EMAIL_IN_TEXT, MASK);
  }
  if (value === null || typeof value !== 'object') {
    return value;
  }
  if (depth >= MAX_DEPTH) {
    return MASK;
  }
  if (value instanceof Date) {
    return value;
  }
  // O pino aplica o formatter antes dos serializadores: o Error precisa ser tratado aqui.
  if (value instanceof Error) {
    return serializeError(value);
  }
  if (Array.isArray(value)) {
    return value.map((item) => sanitize(item, depth + 1));
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      SENSITIVE_KEY.test(key) ? MASK : sanitize(item, depth + 1),
    ]),
  );
}

interface DriverError extends Error {
  code?: unknown;
  constraint?: unknown;
  table?: unknown;
  detail?: unknown;
  cause?: unknown;
}

/**
 * Serializa um erro para o log. O campo detail do Postgres pode trazer valores de
 * colunas, por isso só é mantido nos erros do catálogo, cujo texto nós controlamos.
 */
export function serializeError(error: unknown, depth = 0): unknown {
  if (!(error instanceof Error)) {
    return sanitize(error);
  }
  const driverError = error as DriverError;
  const isCatalogError =
    typeof driverError.code === 'string' &&
    /^FA[0-9]{3}$/.test(driverError.code);

  // Erros de dado inválido do Postgres (classe 22) repetem o valor recebido.
  const repeatsValue =
    typeof driverError.code === 'string' && driverError.code.startsWith('22');

  return sanitize({
    type: error.name,
    message: repeatsValue
      ? 'Dado inválido (valor omitido do log)'
      : error.message,
    code: driverError.code,
    constraint: driverError.constraint,
    table: driverError.table,
    detail: isCatalogError ? driverError.detail : undefined,
    stack: repeatsValue ? undefined : error.stack,
    cause:
      driverError.cause !== undefined && depth < 3
        ? serializeError(driverError.cause, depth + 1)
        : undefined,
  });
}
