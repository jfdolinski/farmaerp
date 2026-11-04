import { AppError } from '../observability/app-error.js';
import {
  assertPasswordPolicy,
  generateSessionToken,
  generateTemporaryPassword,
  hashPassword,
  hashSessionToken,
  verifyPassword,
} from './password.js';

const code = (fn: () => unknown) => {
  try {
    fn();
  } catch (error) {
    return (error as AppError).code;
  }
  return null;
};

describe('senha', () => {
  it('usa Argon2id e confere a senha certa', async () => {
    const hash = await hashPassword('senha-de-teste');
    expect(hash).toMatch(/^\$argon2id\$/);
    expect(hash).not.toContain('senha-de-teste');
    await expect(verifyPassword(hash, 'senha-de-teste')).resolves.toBe(true);
    await expect(verifyPassword(hash, 'outra-senha')).resolves.toBe(false);
  });

  it('hash malformado nega o acesso sem lançar erro', async () => {
    await expect(verifyPassword('nao-e-hash', 'qualquer')).resolves.toBe(false);
  });

  it('confere a senha gerada pelo seed de desenvolvimento', async () => {
    const { readFile } = await import('node:fs/promises');
    const sql = await readFile('../../db/seeds/dev-credentials.sql', 'utf8');
    const hash = /\$argon2id\$[^']+/.exec(sql)![0];
    await expect(verifyPassword(hash, 'farmaerp-dev-123')).resolves.toBe(true);
  });
});

describe('regras da senha', () => {
  it('aceita a partir de 10 caracteres, sem exigir símbolos', () => {
    expect(code(() => assertPasswordPolicy('abcdefghij'))).toBeNull();
    expect(code(() => assertPasswordPolicy('frase longa com espaços'))).toBeNull();
  });

  it.each([
    ['curta', 'abcdefghi', undefined],
    ['longa demais', 'a'.repeat(201), undefined],
    ['igual ao e-mail', 'Fulano@Exemplo.com.br', 'fulano@exemplo.com.br'],
  ])('recusa senha %s', (_label, password, email) => {
    expect(code(() => assertPasswordPolicy(password, email))).toBe('FA404');
  });
});

describe('segredos gerados', () => {
  it('a senha temporária atende às regras e varia', () => {
    const passwords = new Set(
      Array.from({ length: 50 }, () => generateTemporaryPassword()),
    );
    expect(passwords.size).toBe(50);
    for (const password of passwords) {
      expect(code(() => assertPasswordPolicy(password))).toBeNull();
      expect(password).not.toMatch(/[0O1lI]/);
    }
  });

  it('o token de sessão é longo e o hash não o revela', () => {
    const token = generateSessionToken();
    expect(token.length).toBeGreaterThanOrEqual(43);
    expect(hashSessionToken(token)).toMatch(/^[0-9a-f]{64}$/);
    expect(hashSessionToken(token)).not.toContain(token);
  });
});
