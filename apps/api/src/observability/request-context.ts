import { AsyncLocalStorage } from 'node:async_hooks';
import { v7 as uuidv7 } from 'uuid';

export interface RequestContext {
  traceId: string;
  userId?: string;
  branchId?: string;
  terminalId?: string;
}

const storage = new AsyncLocalStorage<RequestContext>();

const UUID_V7 =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const TRACE_HEADER = 'x-trace-id';

/** Mantém o ID recebido se for um UUID v7; caso contrário, gera outro. */
export function resolveTraceId(received: unknown): string {
  return typeof received === 'string' && UUID_V7.test(received)
    ? received.toLowerCase()
    : uuidv7();
}

export function runWithContext<T>(context: RequestContext, fn: () => T): T {
  return storage.run(context, fn);
}

export function currentContext(): RequestContext | undefined {
  return storage.getStore();
}
