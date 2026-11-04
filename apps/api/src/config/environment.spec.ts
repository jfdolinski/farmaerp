import { appEnvironment, assertEnvironment } from './environment.js';

const SECRET = 'a'.repeat(32);

const development = {
  APP_ENV: 'development',
  FARMAERP_APP_PASSWORD: 'senha',
  TERMINAL_TOKEN_SECRET: SECRET,
};
const published = {
  ...development,
  APP_ENV: 'production',
  DB_HOST: 'banco',
  DB_NAME: 'farmaerp',
};

describe('appEnvironment', () => {
  it.each(['development', 'homologation', 'production'])('aceita %s', (value) => {
    expect(appEnvironment({ APP_ENV: value })).toBe(value);
  });

  it.each([undefined, '', 'staging', 'PRODUCTION'])('recusa %j', (value) => {
    expect(() => appEnvironment({ APP_ENV: value })).toThrow(/APP_ENV/);
  });
});

describe('assertEnvironment', () => {
  it('aceita desenvolvimento completo', () => {
    expect(() => assertEnvironment(development)).not.toThrow();
  });

  it.each(['homologation', 'production'])('aceita %s completo', (environment) => {
    expect(() =>
      assertEnvironment({ ...published, APP_ENV: environment }),
    ).not.toThrow();
  });

  it.each([
    ['FARMAERP_APP_PASSWORD', published],
    ['DB_HOST', published],
    ['DB_NAME', published],
    ['TERMINAL_TOKEN_SECRET', published],
    ['FARMAERP_APP_PASSWORD', development],
    ['TERMINAL_TOKEN_SECRET', development],
  ])('informa a falta de %s', (name, base) => {
    const env: Record<string, string | undefined> = { ...base };
    delete env[name];
    expect(() => assertEnvironment(env)).toThrow(new RegExp(name));
  });

  it('desenvolvimento não exige o endereço do banco', () => {
    expect(() => assertEnvironment(development)).not.toThrow();
  });

  it('recusa segredo curto, sem revelar o valor', () => {
    let message = '';
    try {
      assertEnvironment({ ...published, TERMINAL_TOKEN_SECRET: 'vazou' });
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toMatch(/TERMINAL_TOKEN_SECRET precisa ter/);
    expect(message).not.toContain('vazou');
  });
});
