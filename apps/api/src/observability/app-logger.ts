import { LoggerService } from '@nestjs/common';
import pino, { DestinationStream, Logger } from 'pino';
import { currentContext } from './request-context.js';
import { sanitize, serializeError } from './sanitize.js';

export function createPinoLogger(destination?: DestinationStream): Logger {
  return pino(
    {
      level: process.env.LOG_LEVEL ?? 'info',
      base: {
        service: 'api',
        version: process.env.APP_VERSION ?? 'dev',
        env: process.env.APP_ENV ?? 'desconhecido',
      },
      timestamp: pino.stdTimeFunctions.isoTime,
      formatters: {
        level: (label) => ({ level: label }),
        log: (fields) => sanitize(fields) as Record<string, unknown>,
      },
      serializers: { err: serializeError },
      mixin: () => {
        const context = currentContext();
        return context
          ? {
              trace_id: context.traceId,
              user_id: context.userId,
              branch_id: context.branchId,
              terminal_id: context.terminalId,
            }
          : {};
      },
    },
    destination,
  );
}

/** Logger único da aplicação: grava JSON na saída padrão, que o EasyPanel coleta. */
export class AppLogger implements LoggerService {
  constructor(readonly pino: Logger) {}

  log(message: unknown, context?: string): void {
    this.write('info', message, context);
  }

  warn(message: unknown, context?: string): void {
    this.write('warn', message, context);
  }

  debug(message: unknown, context?: string): void {
    this.write('debug', message, context);
  }

  verbose(message: unknown, context?: string): void {
    this.write('trace', message, context);
  }

  fatal(message: unknown, context?: string): void {
    this.write('fatal', message, context);
  }

  // Assinatura do Nest: Logger.error(mensagem, erro ou stack, contexto).
  error(message: unknown, ...rest: unknown[]): void {
    const context =
      rest.length > 0 && typeof rest[rest.length - 1] === 'string'
        ? (rest.pop() as string)
        : undefined;
    const err = rest.find((item) => item !== undefined);
    this.pino.error({ context, err }, this.asText(message));
  }

  private write(
    level: 'info' | 'warn' | 'debug' | 'trace' | 'fatal',
    message: unknown,
    context?: string,
  ): void {
    this.pino[level]({ context }, this.asText(message));
  }

  private asText(message: unknown): string {
    if (typeof message === 'string') {
      return message;
    }
    return message instanceof Error ? message.message : JSON.stringify(message);
  }
}
