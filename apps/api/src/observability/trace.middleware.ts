import { Inject, Injectable, NestMiddleware } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { AppLogger } from './app-logger.js';
import {
  resolveTraceId,
  runWithContext,
  TRACE_HEADER,
} from './request-context.js';

/**
 * Abre o contexto de rastreio e grava um registro por requisição.
 * Nunca registra corpo nem query string, que podem trazer dados pessoais.
 */
@Injectable()
export class TraceMiddleware implements NestMiddleware {
  constructor(@Inject(AppLogger) private readonly logger: AppLogger) {}

  use(req: Request, res: Response, next: NextFunction): void {
    const traceId = resolveTraceId(req.headers[TRACE_HEADER]);
    const startedAt = process.hrtime.bigint();
    res.setHeader(TRACE_HEADER, traceId);

    const context = { traceId };
    runWithContext(context, () => {
      res.once('finish', () => {
        runWithContext(context, () => {
          const route = (req.route as { path?: unknown } | undefined)?.path;
          this.logger.pino.info(
            {
              method: req.method,
              route: typeof route === 'string' ? route : '(sem rota)',
              status: res.statusCode,
              duration_ms:
                Number(process.hrtime.bigint() - startedAt) / 1_000_000,
              error_code: (res.locals as { errorCode?: string }).errorCode,
            },
            'requisição concluída',
          );
        });
      });
      next();
    });
  }
}
