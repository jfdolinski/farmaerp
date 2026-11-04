import { generateKeyPairSync, sign } from 'node:crypto';
import { DevUserGuard } from './dev-user.guard.js';
import {
  assertTokenSecretConfigured,
  challengeMessage,
  issueAccessToken,
  issueChallenge,
  verifyAccessToken,
  verifyChallenge,
  verifySignature,
} from './terminal-crypto.js';

const TERMINAL = '019a0000-0000-7000-8000-000000000007';

function device() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return {
    publicKey: publicKey.export({ format: 'jwk' }).x!,
    sign: (message: string) =>
      sign(null, Buffer.from(message), privateKey).toString('base64url'),
  };
}

describe('verifySignature', () => {
  it('aceita a assinatura da chave certa', () => {
    const { publicKey, sign: signWith } = device();
    expect(verifySignature(publicKey, 'mensagem', signWith('mensagem'))).toBe(
      true,
    );
  });

  // Assinatura feita com a mesma semente nos testes do PDV: garante que Dart e Node combinam.
  it('aceita a assinatura gerada pelo PDV em Dart', () => {
    expect(
      verifySignature(
        '6kpsY-KcUgq-9VB7Ey7F-ZVHdq6-vnuSQh7qaRRG0iw',
        'farmaerp-teste',
        DART_SIGNATURE,
      ),
    ).toBe(true);
  });

  it('rejeita mensagem diferente', () => {
    const { publicKey, sign: signWith } = device();
    expect(verifySignature(publicKey, 'outra', signWith('mensagem'))).toBe(
      false,
    );
  });

  it('rejeita assinatura de outra chave', () => {
    const { publicKey } = device();
    const other = device();
    expect(verifySignature(publicKey, 'mensagem', other.sign('mensagem'))).toBe(
      false,
    );
  });

  it.each([undefined, null, 123, '', 'curta', 'a'.repeat(86), {}])(
    'rejeita a assinatura malformada %j',
    (signature) => {
      expect(verifySignature(device().publicKey, 'mensagem', signature)).toBe(
        false,
      );
    },
  );

  it('rejeita chave malformada sem lançar erro', () => {
    const { sign: signWith } = device();
    expect(verifySignature('nao-e-chave', 'm', signWith('m'))).toBe(false);
  });
});

describe('desafios e tokens', () => {
  it('um desafio válido identifica o terminal', () => {
    const { value } = issueChallenge(TERMINAL);
    expect(verifyChallenge(value)?.terminalId).toBe(TERMINAL);
  });

  it('o desafio vence em 60 segundos', () => {
    const now = Date.now();
    const { value } = issueChallenge(TERMINAL, now);
    expect(verifyChallenge(value, now + 59_000)).not.toBeNull();
    expect(verifyChallenge(value, now + 60_000)).toBeNull();
  });

  it('o token vence em 15 minutos', () => {
    const now = Date.now();
    const { value } = issueAccessToken(TERMINAL, now);
    expect(verifyAccessToken(value, now + 14 * 60_000)).not.toBeNull();
    expect(verifyAccessToken(value, now + 15 * 60_000)).toBeNull();
  });

  it('um desafio não serve como token, nem o contrário', () => {
    expect(verifyAccessToken(issueChallenge(TERMINAL).value)).toBeNull();
    expect(verifyChallenge(issueAccessToken(TERMINAL).value)).toBeNull();
  });

  it('rejeita conteúdo adulterado', () => {
    const { value } = issueAccessToken(TERMINAL);
    const [, signature] = value.split('.');
    const forged = Buffer.from(
      JSON.stringify({ tid: 'outro', exp: Date.now() + 60_000, nonce: 'x' }),
    ).toString('base64url');
    expect(verifyAccessToken(`${forged}.${signature}`)).toBeNull();
  });

  it.each([undefined, null, '', 'abc', 'a.b', 'a.b.c', 123])(
    'rejeita o valor %j sem lançar erro',
    (value) => {
      expect(verifyAccessToken(value)).toBeNull();
    },
  );

  it('dois desafios seguidos são diferentes', () => {
    expect(issueChallenge(TERMINAL).value).not.toBe(
      issueChallenge(TERMINAL).value,
    );
  });

  it('o texto assinado inclui o desafio', () => {
    expect(challengeMessage('abc')).toContain('abc');
  });
});

describe('configuração', () => {
  const original = process.env.TERMINAL_TOKEN_SECRET;
  const originalEnv = process.env.NODE_ENV;

  afterEach(() => {
    process.env.TERMINAL_TOKEN_SECRET = original;
    process.env.NODE_ENV = originalEnv;
  });

  it.each([undefined, '', 'curto'])(
    'recusa o segredo %j',
    (secret) => {
      if (secret === undefined) delete process.env.TERMINAL_TOKEN_SECRET;
      else process.env.TERMINAL_TOKEN_SECRET = secret;
      expect(assertTokenSecretConfigured).toThrow(/TERMINAL_TOKEN_SECRET/);
    },
  );

  it('a identidade de desenvolvimento impede a inicialização em produção', () => {
    process.env.NODE_ENV = 'production';
    expect(() => new DevUserGuard()).toThrow(/não pode rodar em produção/);
  });

  it('a identidade de desenvolvimento funciona fora de produção', () => {
    process.env.NODE_ENV = 'development';
    expect(() => new DevUserGuard()).not.toThrow();
  });
});

const DART_SIGNATURE = 'ns1zZWcdS4PAAice6923Vixl18j7ZsHMVMMM_ke9q0jpurM8deQSs1XJd-AGLi7752Jks95zW04JeScuqMFJCg';
