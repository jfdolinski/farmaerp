import { Body } from '../common/parse.js';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { spendVerificationTime, verifyPassword } from './password.js';

interface SupervisorLookup {
  userId: string;
  passwordHash: string;
  locked: boolean;
}

export interface ReleaseData {
  supervisorId: string;
  reason: string | null;
}

/**
 * Liberação de supervisor pedida na tela: o supervisor presente informa o código ou o e-mail e a
 * senha. A senha é conferida aqui (o Argon2 fica na API); quem pode liberar e quanto, o banco decide.
 * Senha errada conta como erro de login da conta do supervisor, com o mesmo bloqueio. Sem o bloco
 * "release" no corpo, devolve vazio e o banco pede a liberação se o valor passar do limite.
 */
export async function resolveSupervisorRelease(
  database: DatabaseService,
  body: Body,
  ip: string,
): Promise<ReleaseData | undefined> {
  const raw = body.release;
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw !== 'object' || Array.isArray(raw)) throw new AppError('FA005');
  const release = raw as Body;
  const identifier = release.identifier;
  const password = release.password;
  const reason = release.reason;
  if (
    typeof identifier !== 'string' || identifier.trim() === '' || identifier.length > 254 ||
    typeof password !== 'string' || password === '' || password.length > 200 ||
    (reason !== undefined && reason !== null && (typeof reason !== 'string' || reason.length > 500))
  ) {
    throw new AppError('FA005');
  }

  const lookup = await database.withContext(async (client) => {
    const { rows } = await client.query<{ result: SupervisorLookup | null }>(
      'SELECT app.supervisor_lookup($1) AS result',
      [identifier],
    );
    return rows[0].result;
  });
  // Código desconhecido, conta bloqueada e senha errada: mesma resposta e mesmo tempo.
  let valid = false;
  if (lookup && !lookup.locked) {
    valid = await verifyPassword(lookup.passwordHash, password);
  } else {
    await spendVerificationTime(password);
  }
  if (!valid) {
    await database.withContext((client) =>
      client.query('SELECT app.auth_login_failed($1, $2)', [lookup?.userId ?? null, ip]),
    );
    throw new AppError('FA953');
  }
  return { supervisorId: lookup!.userId, reason: typeof reason === 'string' ? reason : null };
}
