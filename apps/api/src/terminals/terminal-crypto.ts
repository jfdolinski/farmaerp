import {
  createHmac,
  createPublicKey,
  randomBytes,
  timingSafeEqual,
  verify,
} from 'node:crypto';

const MIN_SECRET_LENGTH = 32;

export const CHALLENGE_TTL_SECONDS = 60;
export const TOKEN_TTL_SECONDS = 15 * 60;

/** Texto assinado pelo aparelho para provar que tem a chave ao abrir a solicitação. */
export const pairingProofMessage = (publicKey: string) =>
  `farmaerp-terminal-pairing:${publicKey}`;

/** Texto assinado pelo aparelho para responder a um desafio. */
export const challengeMessage = (challenge: string) =>
  `farmaerp-terminal-auth:${challenge}`;

export function isValidPublicKey(publicKey: unknown): publicKey is string {
  return typeof publicKey === 'string' && /^[A-Za-z0-9_-]{43}$/.test(publicKey);
}

/** Confere uma assinatura Ed25519. Dados malformados contam como assinatura inválida. */
export function verifySignature(
  publicKey: string,
  message: string,
  signature: unknown,
): boolean {
  if (typeof signature !== 'string' || !/^[A-Za-z0-9_-]{86}$/.test(signature)) {
    return false;
  }
  try {
    const key = createPublicKey({
      key: { kty: 'OKP', crv: 'Ed25519', x: publicKey },
      format: 'jwk',
    });
    return verify(
      null,
      Buffer.from(message),
      key,
      Buffer.from(signature, 'base64url'),
    );
  } catch {
    return false;
  }
}

type TokenKind = 'challenge' | 'access';

export interface VerifiedToken {
  terminalId: string;
  expiresAt: number;
}

function loadSecret(): string {
  const secret = process.env.TERMINAL_TOKEN_SECRET;
  if (!secret || secret.length < MIN_SECRET_LENGTH) {
    throw new Error(
      `A variável TERMINAL_TOKEN_SECRET precisa ter ao menos ${MIN_SECRET_LENGTH} caracteres.`,
    );
  }
  return secret;
}

function hmac(kind: TokenKind, payload: string): Buffer {
  // O tipo entra na assinatura: um desafio não serve como token de acesso.
  return createHmac('sha256', loadSecret())
    .update(`${kind}.${payload}`)
    .digest();
}

function issue(
  kind: TokenKind,
  terminalId: string,
  ttlSeconds: number,
  now: number,
): { value: string; expiresAt: string } {
  const expiresAt = now + ttlSeconds * 1000;
  const payload = Buffer.from(
    JSON.stringify({
      tid: terminalId,
      exp: expiresAt,
      nonce: randomBytes(16).toString('base64url'),
    }),
  ).toString('base64url');
  return {
    value: `${payload}.${hmac(kind, payload).toString('base64url')}`,
    expiresAt: new Date(expiresAt).toISOString(),
  };
}

function check(
  kind: TokenKind,
  value: unknown,
  now: number,
): VerifiedToken | null {
  if (typeof value !== 'string') {
    return null;
  }
  const [payload, signature, ...rest] = value.split('.');
  if (!payload || !signature || rest.length > 0) {
    return null;
  }
  const expected = hmac(kind, payload);
  const received = Buffer.from(signature, 'base64url');
  if (
    received.length !== expected.length ||
    !timingSafeEqual(received, expected)
  ) {
    return null;
  }
  try {
    const { tid, exp } = JSON.parse(
      Buffer.from(payload, 'base64url').toString(),
    ) as { tid?: unknown; exp?: unknown };
    if (typeof tid !== 'string' || typeof exp !== 'number' || exp <= now) {
      return null;
    }
    return { terminalId: tid, expiresAt: exp };
  } catch {
    return null;
  }
}

export const issueChallenge = (terminalId: string, now = Date.now()) =>
  issue('challenge', terminalId, CHALLENGE_TTL_SECONDS, now);
export const issueAccessToken = (terminalId: string, now = Date.now()) =>
  issue('access', terminalId, TOKEN_TTL_SECONDS, now);
export const verifyChallenge = (value: unknown, now = Date.now()) =>
  check('challenge', value, now);
export const verifyAccessToken = (value: unknown, now = Date.now()) =>
  check('access', value, now);

/** Falha na inicialização, e não na primeira autenticação, se o segredo estiver errado. */
export function assertTokenSecretConfigured(): void {
  loadSecret();
}
