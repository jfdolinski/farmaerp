export interface CatalogEntry {
  message: string;
  action: string;
  httpStatus: number;
  severity: 'warning' | 'error';
  retryable: boolean;
  dbConstraints: string[];
}

export interface CatalogError extends CatalogEntry {
  code: string;
}

export const catalog: Record<string, CatalogEntry>;
export const FALLBACK_CODE: string;
export function getError(code: string): CatalogError;
export function codeFromDbError(error: unknown): string | null;
