import {
  codeFromDbError,
  FALLBACK_CODE,
  getError,
} from '@farmaerp/error-catalog';
import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  Inject,
} from '@nestjs/common';
import type { Response } from 'express';
import { AppError } from './app-error.js';
import { AppLogger } from './app-logger.js';
import {
  currentContext,
  resolveTraceId,
  TRACE_HEADER,
} from './request-context.js';

function codeFromHttpStatus(status: number): string {
  if (status === 403 || status === 401) return 'FA002';
  if (status === 404) return 'FA006';
  if (status === 429) return 'FA009';
  // O leitor do corpo recusa o arquivo grande antes de chegar à rota.
  if (status === 413) return 'FA933';
  if (status === 503) return 'FA001';
  if (status >= 400 && status < 500) return 'FA007';
  return FALLBACK_CODE;
}

function resolveCode(exception: unknown): string {
  if (exception instanceof AppError) {
    return exception.code;
  }
  if (exception instanceof HttpException) {
    return codeFromHttpStatus(exception.getStatus());
  }
  return codeFromDbError(exception) ?? FALLBACK_CODE;
}

/** Transforma qualquer erro na resposta padrão. O detalhe técnico vai só para o log. */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  constructor(@Inject(AppLogger) private readonly logger: AppLogger) {}

  catch(exception: unknown, host: ArgumentsHost): void {
    const response = host.switchToHttp().getResponse<Response>();
    const entry = getError(resolveCode(exception));

    // Erros anteriores ao middleware, como JSON malformado, ainda não têm contexto.
    const traceId = currentContext()?.traceId ?? resolveTraceId(undefined);
    if (!response.getHeader(TRACE_HEADER)) {
      response.setHeader(TRACE_HEADER, traceId);
    }

    // A mensagem de erros HTTP pode trazer a URL e trechos do corpo: só o tipo e o status vão para o log.
    const err =
      exception instanceof HttpException
        ? { type: exception.name, status: exception.getStatus() }
        : exception;

    (response.locals as { errorCode?: string }).errorCode = entry.code;
    this.logger.pino[entry.severity === 'error' ? 'error' : 'warn'](
      { error_code: entry.code, trace_id: traceId, err },
      entry.message,
    );

    response.status(entry.httpStatus).json({
      code: entry.code,
      message: entry.message,
      action: entry.action,
      retryable: entry.retryable,
      traceId,
    });
  }
}
