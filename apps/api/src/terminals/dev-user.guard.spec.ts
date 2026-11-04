import { ExecutionContext } from '@nestjs/common';
import { AppError } from '../observability/app-error.js';
import { DevUserGuard } from './dev-user.guard.js';

const USER = '019a0000-0000-7000-8000-000000000008';
const SECRET = 's'.repeat(32);

const contextWith = (headers: Record<string, string>) =>
  ({
    switchToHttp: () => ({ getRequest: () => ({ headers }) }),
  }) as unknown as ExecutionContext;

describe('DevUserGuard', () => {
  const original = { ...process.env };

  afterEach(() => {
    process.env.APP_ENV = original.APP_ENV;
    if (original.ADMIN_INTERNAL_SECRET === undefined) {
      delete process.env.ADMIN_INTERNAL_SECRET;
    } else {
      process.env.ADMIN_INTERNAL_SECRET = original.ADMIN_INTERNAL_SECRET;
    }
  });

  const code = (fn: () => unknown) => {
    try {
      fn();
    } catch (error) {
      return (error as AppError).code;
    }
    return null;
  };

  describe('inicialização', () => {
    it('impede o início em produção', () => {
      process.env.APP_ENV = 'production';
      expect(() => new DevUserGuard()).toThrow(/não pode rodar em produção/);
    });

    it('impede o início sem ambiente válido', () => {
      process.env.APP_ENV = 'qualquer';
      expect(() => new DevUserGuard()).toThrow(/APP_ENV/);
    });

    it('NODE_ENV=production não basta para liberar nem bloquear', () => {
      process.env.APP_ENV = 'development';
      const nodeEnv = process.env.NODE_ENV;
      process.env.NODE_ENV = 'production';
      expect(() => new DevUserGuard()).not.toThrow();
      process.env.NODE_ENV = nodeEnv;
    });
  });

  describe('desenvolvimento', () => {
    beforeEach(() => {
      process.env.APP_ENV = 'development';
    });

    it('aceita o usuário do cabeçalho', () => {
      const guard = new DevUserGuard();
      expect(guard.canActivate(contextWith({ 'x-dev-user-id': USER }))).toBe(true);
    });

    it('recusa sem usuário', () => {
      const guard = new DevUserGuard();
      expect(code(() => guard.canActivate(contextWith({})))).toBe('FA002');
    });
  });

  describe('homologação', () => {
    beforeEach(() => {
      process.env.APP_ENV = 'homologation';
      process.env.ADMIN_INTERNAL_SECRET = SECRET;
    });

    it('aceita com o segredo certo', () => {
      const guard = new DevUserGuard();
      expect(
        guard.canActivate(
          contextWith({ 'x-dev-user-id': USER, 'x-internal-token': SECRET }),
        ),
      ).toBe(true);
    });

    it.each([
      ['sem segredo', {}],
      ['segredo errado', { 'x-internal-token': 'errado' }],
      ['segredo quase igual', { 'x-internal-token': `${SECRET}x` }],
    ])('recusa %s, mesmo com usuário', (_label, headers) => {
      const guard = new DevUserGuard();
      expect(
        code(() =>
          guard.canActivate(contextWith({ 'x-dev-user-id': USER, ...headers })),
        ),
      ).toBe('FA002');
    });

    it('recusa se o segredo não estiver configurado', () => {
      delete process.env.ADMIN_INTERNAL_SECRET;
      const guard = new DevUserGuard();
      expect(
        code(() =>
          guard.canActivate(
            contextWith({ 'x-dev-user-id': USER, 'x-internal-token': '' }),
          ),
        ),
      ).toBe('FA002');
    });

    it('recusa segredo certo sem usuário', () => {
      const guard = new DevUserGuard();
      expect(
        code(() => guard.canActivate(contextWith({ 'x-internal-token': SECRET }))),
      ).toBe('FA002');
    });
  });
});
