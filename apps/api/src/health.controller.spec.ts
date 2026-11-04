import { DatabaseService } from './database.service.js';
import { HealthController } from './health.controller.js';
import { AppError } from './observability/app-error.js';

describe('HealthController', () => {
  const controllerWith = (ping: () => Promise<void>) =>
    new HealthController({ ping } as unknown as DatabaseService);

  it('informa que está tudo certo quando o banco responde', async () => {
    const controller = controllerWith(() => Promise.resolve());
    await expect(controller.check()).resolves.toEqual({
      status: 'ok',
      database: 'up',
    });
  });

  it('usa o código do catálogo e guarda a causa técnica', async () => {
    const technicalError = new Error('senha incorreta para farmaerp_app');
    const controller = controllerWith(() => Promise.reject(technicalError));

    const failure = await controller.check().catch((error: unknown) => error);

    expect(failure).toBeInstanceOf(AppError);
    expect((failure as AppError).code).toBe('FA001');
    expect((failure as AppError).cause).toBe(technicalError);
  });
});
