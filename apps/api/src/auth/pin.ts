import { pbkdf2, randomBytes } from 'node:crypto';
import { promisify } from 'node:util';

const pbkdf2Async = promisify(pbkdf2);

/** Rodadas do PBKDF2. O PDV confere o PIN em Dart: este número fica perto de 1 s lá. */
export const PIN_ITERATIONS = 210_000;

/**
 * PIN aceito: de 4 a 6 números, sem todos iguais (1111) e sem sequência (1234, 9876). Com poucos
 * dígitos, esses são os primeiros que alguém tenta.
 */
export function isAcceptablePin(pin: unknown): pin is string {
  if (typeof pin !== 'string' || !/^\d{4,6}$/.test(pin)) return false;
  const digits = [...pin].map(Number);
  if (digits.every((digit) => digit === digits[0])) return false;
  const steps = digits.slice(1).map((digit, index) => digit - digits[index]);
  if (steps.every((step) => step === 1) || steps.every((step) => step === -1)) return false;
  return true;
}

/** Formato: pbkdf2-sha256$rodadas$sal$hash (sal e hash em base64). O PDV confere o mesmo formato. */
export async function hashPin(pin: string, salt = randomBytes(16)): Promise<string> {
  const hash = await pbkdf2Async(pin, salt, PIN_ITERATIONS, 32, 'sha256');
  return `pbkdf2-sha256$${PIN_ITERATIONS}$${salt.toString('base64')}$${hash.toString('base64')}`;
}
