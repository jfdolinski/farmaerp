import catalog from './catalog.json' with { type: 'json' };

export { catalog };

export const FALLBACK_CODE = 'FA000';

// Erros padrão do Postgres sem constraint de negócio.
const SQLSTATE_TO_CODE = {
  23502: 'FA005', // not_null_violation
  23503: 'FA004', // foreign_key_violation
  23505: 'FA003', // unique_violation
  23514: 'FA005', // check_violation
  '22P02': 'FA005', // invalid_text_representation
  22001: 'FA005', // string_data_right_truncation
  42501: 'FA002', // insufficient_privilege (inclui RLS)
  40001: 'FA008', // serialization_failure
  '40P01': 'FA008', // deadlock_detected
  '55P03': 'FA008', // lock_not_available
  57014: 'FA008', // query_canceled (timeout)
  '57P01': 'FA001', // admin_shutdown
  '57P03': 'FA001', // cannot_connect_now
  53300: 'FA001', // too_many_connections
};

const CONNECTION_ERRORS = new Set([
  'ECONNREFUSED',
  'ECONNRESET',
  'ETIMEDOUT',
  'ENOTFOUND',
  'EPIPE',
]);

const CONSTRAINT_TO_CODE = new Map(
  Object.entries(catalog).flatMap(([code, entry]) =>
    entry.dbConstraints.map((constraint) => [constraint, code]),
  ),
);

/** Retorna a entrada do catálogo; um código desconhecido vira o erro genérico. */
export function getError(code) {
  const known = Object.hasOwn(catalog, code) ? code : FALLBACK_CODE;
  return { code: known, ...catalog[known] };
}

/**
 * Traduz um erro do driver do Postgres para um código do catálogo.
 * Retorna null quando o erro não é reconhecido.
 */
export function codeFromDbError(error) {
  if (!error || typeof error !== 'object') {
    return null;
  }
  const { code, constraint, message } = error;

  if (constraint && CONSTRAINT_TO_CODE.has(constraint)) {
    return CONSTRAINT_TO_CODE.get(constraint);
  }
  if (typeof code === 'string') {
    if (Object.hasOwn(catalog, code)) {
      return code;
    }
    if (Object.hasOwn(SQLSTATE_TO_CODE, code)) {
      return SQLSTATE_TO_CODE[code];
    }
    if (CONNECTION_ERRORS.has(code)) {
      return 'FA001';
    }
    // Classe 08: falhas de conexão.
    if (/^08[0-9A-Z]{3}$/.test(code)) {
      return 'FA001';
    }
  }
  if (typeof message === 'string' && /timeout|Connection terminated/i.test(message)) {
    return 'FA001';
  }
  return null;
}
