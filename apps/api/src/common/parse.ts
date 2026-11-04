import { AppError } from '../observability/app-error.js';

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type Body = Record<string, unknown>;

export function asBody(value: unknown): Body {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new AppError('FA005');
  }
  return value as Body;
}

export function requireText(body: Body, field: string, maxLength = 200): string {
  const value = body[field];
  if (
    typeof value !== 'string' ||
    value.trim() === '' ||
    value.length > maxLength
  ) {
    throw new AppError('FA005');
  }
  return value;
}

export function optionalText(
  body: Body,
  field: string,
  maxLength = 500,
): string | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'string' || value.length > maxLength) {
    throw new AppError('FA005');
  }
  return value;
}

export function requireUuid(value: unknown): string {
  if (typeof value !== 'string' || !UUID.test(value)) {
    throw new AppError('FA005');
  }
  return value;
}

export function optionalInstant(body: Body, field: string): string | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new AppError('FA005');
  }
  return value;
}

export function optionalCount(body: Body, field: string): number | null {
  const value = body[field];
  if (value === undefined || value === null) {
    return null;
  }
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new AppError('FA005');
  }
  return value;
}
