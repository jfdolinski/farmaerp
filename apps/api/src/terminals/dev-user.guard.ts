import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import type { Request } from 'express';
import { createHash, timingSafeEqual } from 'node:crypto';
import { requireUuid } from '../common/parse.js';
import { AppEnvironment, appEnvironment } from '../config/environment.js';
import { AppError } from '../observability/app-error.js';
import { currentContext } from '../observability/request-context.js';

export const DEV_USER_HEADER = 'x-dev-user-id';
export const INTERNAL_TOKEN_HEADER = 'x-internal-token';

const sha256 = (value: string) => createHash('sha256').update(value).digest();

/**
 * IDENTIDADE PROVISÓRIA: aceita o usuário informado no cabeçalho, sem senha.
 * Fica até o login da Etapa 2 e impede a API de iniciar em produção.
 * Na homologação, que é acessível pela internet, também exige um segredo
 * que só a retaguarda conhece: sem ele, qualquer pessoa agiria como administrador.
 */
@Injectable()
export class DevUserGuard implements CanActivate {
  private readonly environment: AppEnvironment;

  constructor() {
    this.environment = appEnvironment();
    if (this.environment === 'production') {
      throw new Error(
        'A identidade de desenvolvimento não pode rodar em produção. Implemente o login antes de publicar a API.',
      );
    }
  }

  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<Request>();

    if (this.environment === 'homologation') {
      this.requireInternalToken(request);
    }

    const header = request.headers[DEV_USER_HEADER];
    if (!header) {
      throw new AppError('FA002');
    }
    const requestContext = currentContext();
    if (requestContext) {
      requestContext.userId = requireUuid(header);
    }
    return true;
  }

  private requireInternalToken(request: Request): void {
    const expected = process.env.ADMIN_INTERNAL_SECRET;
    const received = request.headers[INTERNAL_TOKEN_HEADER];
    if (
      !expected ||
      typeof received !== 'string' ||
      !timingSafeEqual(sha256(received), sha256(expected))
    ) {
      throw new AppError('FA002');
    }
  }
}
