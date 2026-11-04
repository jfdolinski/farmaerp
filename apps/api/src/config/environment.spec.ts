import { appEnvironment, assertEnvironment } from './environment.js';

const SECRET_A = 'a'.repeat(32);
const SECRET_B = 'b'.repeat(32);

const development = {
  APP_ENV: 'development',
  FARMAERP_APP_PASSWORD: 'senha',
  TERMINAL_TOKEN_SECRET: SECRET_A,
};
const homologation = {
  ...development,
  APP_ENV: 'homologation',
  DB_HOST: 'banco',
  DB_NAME: 'farmaerp',
  ADMIN_INTERNAL_SECRET: SECRET_B,
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
  it('aceita desenvolvimento e homologação completos', () => {
    expect(() => assertEnvironment(development)).not.toThrow();
    expect(() => assertEnvironment(homologation)).not.toThrow();
  });

  it('a produção não inicia, mesmo com tudo preenchido', () => {
    expect(() =>
      assertEnvironment({ ...homologation, APP_ENV: 'production' }),
    ).toThrow(/exige o login/);
  });

  it.each([
    ['FARMAERP_APP_PASSWORD', homologation],
    ['DB_HOST', homologation],
    ['DB_NAME', homologation],
    ['TERMINAL_TOKEN_SECRET', homologation],
    ['ADMIN_INTERNAL_SECRET', homologation],
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

  it('recusa segredo curto', () => {
    expect(() =>
      assertEnvironment({ ...homologation, ADMIN_INTERNAL_SECRET: 'curto' }),
    ).toThrow(/ADMIN_INTERNAL_SECRET precisa ter/);
  });

  it('recusa o mesmo valor nos dois segredos', () => {
    expect(() =>
      assertEnvironment({ ...homologation, ADMIN_INTERNAL_SECRET: SECRET_A }),
    ).toThrow(/precisa ser diferente/);
  });

  it('a mensagem não revela o valor dos segredos', () => {
    let message = '';
    try {
      assertEnvironment({ ...homologation, ADMIN_INTERNAL_SECRET: 'vazou' });
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).not.toContain('vazou');
  });
});
