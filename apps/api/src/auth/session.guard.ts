import {
  CanActivate,
  ExecutionContext,
  Inject,
  Injectable,
  SetMetadata,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Request } from 'express';
import { DatabaseService } from '../database.service.js';
import { AppError } from '../observability/app-error.js';
import { currentContext } from '../observability/request-context.js';
import { hashSessionToken } from './password.js';

export interface SessionUser {
  userId: string;
  name: string;
  email: string | null;
  code: number;
  isAdmin: boolean;
  mustChangePassword: boolean;
}

export type AuthenticatedRequest = Request & {
  sessionUser?: SessionUser;
  sessionTokenHash?: string;
};

const ALLOW_PENDING_PASSWORD_CHANGE = 'allowPendingPasswordChange';

/** Rotas que funcionam mesmo com a troca de senha pendente. */
export const AllowPendingPasswordChange = () =>
  SetMetadata(ALLOW_PENDING_PASSWORD_CHANGE, true);

/**
 * Autentica pela sessão. O banco é consultado a cada requisição:
 * é isso que faz a revogação e a desativação valerem na hora.
 */
@Injectable()
export class SessionGuard implements CanActivate {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
    @Inject(Reflector) private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const [scheme, token] = (request.headers.authorization ?? '').split(' ');
    if (scheme?.toLowerCase() !== 'bearer' || !token) {
      throw new AppError('FA402');
    }

    const tokenHash = hashSessionToken(token);
    const user = await this.database.withContext(async (client) => {
      const { rows } = await client.query<{ result: SessionUser | null }>(
        'SELECT app.validate_session($1) AS result',
        [tokenHash],
      );
      return rows[0].result;
    });
    if (!user) {
      throw new AppError('FA402');
    }

    const requestContext = currentContext();
    if (requestContext) {
      requestContext.userId = user.userId;
    }
    request.sessionUser = user;
    request.sessionTokenHash = tokenHash;

    const allowed = this.reflector.getAllAndOverride<boolean>(
      ALLOW_PENDING_PASSWORD_CHANGE,
      [context.getHandler(), context.getClass()],
    );
    if (user.mustChangePassword && !allowed) {
      throw new AppError('FA403');
    }
    return true;
  }
}
