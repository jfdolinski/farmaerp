import { INestApplication, Logger } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DatabaseService } from './../src/database.service.js';

describe('GET /health', () => {
  let app: INestApplication<App>;
  const ping = vi.fn<() => Promise<void>>();

  beforeEach(async () => {
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(DatabaseService)
      .useValue({ ping })
      .compile();

    moduleFixture.useLogger(false);
    vi.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);

    app = moduleFixture.createNestApplication();
    await app.init();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await app.close();
  });

  it('responde 200 quando o banco está disponível', () => {
    ping.mockResolvedValue();
    return request(app.getHttpServer())
      .get('/health')
      .expect(200)
      .expect({ status: 'ok', database: 'up' });
  });

  it('responde 503 com mensagem clara quando o banco está indisponível', async () => {
    ping.mockRejectedValue(new Error('detalhe técnico'));
    const response = await request(app.getHttpServer())
      .get('/health')
      .expect(503);
    const body = response.body as { message: string };
    expect(body.message).toContain('Sistema indisponível');
    expect(JSON.stringify(response.body)).not.toContain('detalhe técnico');
  });
});
