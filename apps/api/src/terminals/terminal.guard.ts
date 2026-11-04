import {
  CanActivate,
  ExecutionContext,
  Inject,
  Injectable,
} from '@nestjs/common';
import type { Request } from 'express';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { currentContext } from '../observability/request-context.js';
import {
  assertTokenSecretConfigured,
  verifyAccessToken,
} from './terminal-crypto.js';

export interface TerminalAuthInfo {
  publicKey: string;
  status: string;
}

/** Busca o terminal e barra quem não pode operar, com a mensagem de cada situação. */
export async function requireActiveTerminal(
  database: DatabaseService,
  terminalId: string,
): Promise<TerminalAuthInfo> {
  const info = await database.withContext(async (client) => {
    const { rows } = await client.query<{ info: TerminalAuthInfo | null }>(
      'SELECT app.terminal_auth_info($1) AS info',
      [terminalId],
    );
    return rows[0].info;
  });
  if (!info) throw new AppError('FA306');
  if (info.status === 'pending') throw new AppError('FA307');
  if (info.status === 'blocked') throw new AppError('FA304');
  if (info.status === 'revoked') throw new AppError('FA305');
  return info;
}

/**
 * Autentica o terminal pelo token. A situação é consultada a cada requisição:
 * é isso que faz o bloqueio valer na hora, mesmo com o token ainda válido.
 */
@Injectable()
export class TerminalGuard implements CanActivate {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {
    assertTokenSecretConfigured();
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<Request>();
    const [scheme, token] = (request.headers.authorization ?? '').split(' ');
    const verified =
      scheme?.toLowerCase() === 'bearer' ? verifyAccessToken(token) : null;
    if (!verified) {
      throw new AppError('FA306');
    }

    await requireActiveTerminal(this.database, verified.terminalId);

    const requestContext = currentContext();
    if (requestContext) {
      requestContext.terminalId = verified.terminalId;
    }
    return true;
  }
}
