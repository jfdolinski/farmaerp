import argon2 from 'argon2';
import { createHash, randomBytes, randomInt } from 'node:crypto';
import { AppError } from '../observability/app-error.js';

const MIN_LENGTH = 10;
const MAX_LENGTH = 200;

// Sem símbolos parecidos, para o administrador conseguir ditar a senha.
const TEMPORARY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
const TEMPORARY_LENGTH = 14;

export const hashPassword = (password: string) =>
  argon2.hash(password, { type: argon2.argon2id });

/** Hash malformado conta como senha errada: nunca libera o acesso. */
export async function verifyPassword(
  hash: string,
  password: string,
): Promise<boolean> {
  try {
    return await argon2.verify(hash, password);
  } catch {
    return false;
  }
}

let dummyHash: Promise<string> | undefined;

/**
 * Gasta o mesmo tempo de uma conferência real, para a resposta não revelar
 * se o e-mail existe ou se a conta está bloqueada.
 */
export async function spendVerificationTime(password: string): Promise<void> {
  dummyHash ??= hashPassword(randomBytes(32).toString('hex'));
  await verifyPassword(await dummyHash, password);
}

export function assertPasswordPolicy(
  password: string,
  email?: string | null,
): void {
  const tooShort = password.length < MIN_LENGTH;
  const tooLong = password.length > MAX_LENGTH;
  const sameAsEmail =
    !!email && password.trim().toLowerCase() === email.trim().toLowerCase();
  if (tooShort || tooLong || sameAsEmail) {
    throw new AppError('FA404');
  }
}

export function generateTemporaryPassword(): string {
  return Array.from(
    { length: TEMPORARY_LENGTH },
    () => TEMPORARY_ALPHABET[randomInt(TEMPORARY_ALPHABET.length)],
  ).join('');
}

export const generateSessionToken = () => randomBytes(32).toString('base64url');

/** O banco guarda só este hash: quem lê a tabela não consegue usar a sessão. */
export const hashSessionToken = (token: string) =>
  createHash('sha256').update(token).digest('hex');
