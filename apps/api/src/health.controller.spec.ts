import { Logger, ServiceUnavailableException } from '@nestjs/common';
import { DatabaseService } from './database.service.js';
import { HealthController } from './health.controller.js';

describe('HealthController', () => {
  const logError = vi.spyOn(Logger.prototype, 'error');

  beforeEach(() => {
    logError.mockImplementation(() => undefined);
  });

  const controllerWith = (ping: () => Promise<void>) =>
    new HealthController({ ping } as unknown as DatabaseService);

  it('informa que está tudo certo quando o banco responde', async () => {
    const controller = controllerWith(() => Promise.resolve());
    await expect(controller.check()).resolves.toEqual({
      status: 'ok',
      database: 'up',
    });
  });

  it('não expõe o detalhe técnico quando o banco falha', async () => {
    const technicalError = new Error('senha incorreta para farmaerp_app');
    const controller = controllerWith(() => Promise.reject(technicalError));

    const failure = await controller.check().catch((error: unknown) => error);

    expect(failure).toBeInstanceOf(ServiceUnavailableException);
    expect((failure as Error).message).not.toContain('farmaerp_app');
    expect(logError).toHaveBeenCalledWith(
      expect.any(String),
      technicalError,
    );
  });
});
