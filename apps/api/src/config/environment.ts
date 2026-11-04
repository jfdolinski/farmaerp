export type AppEnvironment = 'development' | 'homologation' | 'production';

const ENVIRONMENTS: readonly string[] = [
  'development',
  'homologation',
  'production',
];
const MIN_SECRET_LENGTH = 32;

type Env = Record<string, string | undefined>;

/** Ambiente da aplicação. Sem valor reconhecido, nada é liberado. */
export function appEnvironment(env: Env = process.env): AppEnvironment {
  const value = env.APP_ENV;
  if (!value || !ENVIRONMENTS.includes(value)) {
    throw new Error(
      `A variável APP_ENV precisa ser development, homologation ou production (recebido: ${value ?? 'nada'}).`,
    );
  }
  return value as AppEnvironment;
}

/**
 * Confere a configuração ao iniciar, para falhar com mensagem clara
 * antes de rodar migrations ou aceitar requisições.
 */
export function assertEnvironment(env: Env = process.env): void {
  const environment = appEnvironment(env);
  const problems: string[] = [];

  const required = ['FARMAERP_APP_PASSWORD'];
  if (environment !== 'development') {
    required.push('DB_HOST', 'DB_NAME');
  }
  for (const name of required) {
    if (!env[name]) problems.push(`${name} não está definida`);
  }

  if ((env.TERMINAL_TOKEN_SECRET?.length ?? 0) < MIN_SECRET_LENGTH) {
    problems.push(
      `TERMINAL_TOKEN_SECRET precisa ter ao menos ${MIN_SECRET_LENGTH} caracteres`,
    );
  }

  if (problems.length > 0) {
    throw new Error(`Configuração inválida: ${problems.join('; ')}.`);
  }
}
