import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import type { Request } from 'express';
import { requireUuid } from '../common/parse.js';
import { AppError } from '../observability/app-error.js';
import { currentContext } from '../observability/request-context.js';

export const DEV_USER_HEADER = 'x-dev-user-id';

/**
 * IDENTIDADE SÓ DE DESENVOLVIMENTO: aceita o usuário informado no cabeçalho, sem senha.
 * Fica até o login da Etapa 2. Impede a API de iniciar em produção, para esta
 * autenticação provisória nunca ser publicada por engano.
 */
@Injectable()
export class DevUserGuard implements CanActivate {
  constructor() {
    if (process.env.NODE_ENV === 'production') {
      throw new Error(
        'A identidade de desenvolvimento não pode rodar em produção. Implemente o login antes de publicar a API.',
      );
    }
  }

  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<Request>();
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
}
