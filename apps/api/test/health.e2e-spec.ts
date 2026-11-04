import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DatabaseService } from './../src/database.service.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';

const VALID_TRACE = '019a0000-0000-7000-8000-0000000000b1';

describe('GET /health', () => {
  let app: INestApplication<App>;
  let logs: Record<string, unknown>[];
  const ping = vi.fn<() => Promise<void>>();

  beforeEach(async () => {
    logs = [];
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        logs.push(JSON.parse(chunk.toString()) as Record<string, unknown>);
        callback();
      },
    });

    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(DatabaseService)
      .useValue({ ping })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(destination)))
      .compile();

    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    await app.init();
  });

  afterEach(async () => {
    await app.close();
  });

  it('responde 200 quando o banco está disponível', () => {
    ping.mockResolvedValue();
    return request(app.getHttpServer())
      .get('/health')
      .expect(200)
      .expect({ status: 'ok', database: 'up' });
  });

  it('responde 503 com o catálogo, sem detalhe técnico', async () => {
    ping.mockRejectedValue(new Error('senha incorreta para farmaerp_app'));
    const response = await request(app.getHttpServer())
      .get('/health')
      .expect(503);

    expect(response.body).toEqual({
      code: 'FA001',
      message: 'Sistema indisponível no momento.',
      action: 'Aguarde alguns instantes e tente novamente.',
      retryable: true,
      traceId: response.headers['x-trace-id'],
    });
    expect(JSON.stringify(response.body)).not.toContain('farmaerp_app');
  });

  it('mantém o detalhe técnico só no log', async () => {
    ping.mockRejectedValue(new Error('senha incorreta para farmaerp_app'));
    await request(app.getHttpServer()).get('/health').expect(503);

    const errorLog = logs.find((log) => log.level === 'error');
    expect(errorLog).toMatchObject({ error_code: 'FA001' });
    expect(JSON.stringify(errorLog)).toContain('farmaerp_app');
  });

  it('mantém o ID de rastreio recebido e o devolve', async () => {
    ping.mockResolvedValue();
    const response = await request(app.getHttpServer())
      .get('/health')
      .set('X-Trace-Id', VALID_TRACE)
      .expect(200);

    expect(response.headers['x-trace-id']).toBe(VALID_TRACE);
    expect(logs.at(-1)).toMatchObject({
      trace_id: VALID_TRACE,
      route: '/health',
      method: 'GET',
      status: 200,
      service: 'api',
    });
  });

  it.each(['abc', '550e8400-e29b-41d4-a716-446655440000', "1' OR '1'='1"])(
    'troca o ID de rastreio inválido %j',
    async (invalid) => {
      ping.mockResolvedValue();
      const response = await request(app.getHttpServer())
        .get('/health')
        .set('X-Trace-Id', invalid)
        .expect(200);

      expect(response.headers['x-trace-id']).not.toBe(invalid);
      expect(response.headers['x-trace-id']).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-7/,
      );
    },
  );

  it('gera um ID de rastreio quando não recebe nenhum', async () => {
    ping.mockResolvedValue();
    const response = await request(app.getHttpServer())
      .get('/health')
      .expect(200);
    expect(response.headers['x-trace-id']).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-7/,
    );
  });

  it('não registra a query string, que pode trazer dados pessoais', async () => {
    ping.mockResolvedValue();
    await request(app.getHttpServer())
      .get('/health?cpf=12345678909')
      .expect(200);
    expect(JSON.stringify(logs)).not.toContain('12345678909');
  });

  it('não registra a URL de um erro HTTP', async () => {
    await request(app.getHttpServer())
      .get('/nao-existe?nome=Maria&token=abc')
      .expect(404);
    expect(JSON.stringify(logs)).not.toContain('Maria');
    expect(JSON.stringify(logs)).not.toContain('nao-existe');
  });

  it('rota inexistente responde com o catálogo e o rastreio', async () => {
    const response = await request(app.getHttpServer())
      .get('/nao-existe')
      .set('X-Trace-Id', VALID_TRACE)
      .expect(404);

    expect(response.body).toMatchObject({
      code: 'FA006',
      traceId: VALID_TRACE,
    });
    expect(logs.at(-1)).toMatchObject({ error_code: 'FA006', status: 404 });
  });

  it('JSON malformado responde com o catálogo e tem ID de rastreio', async () => {
    const response = await request(app.getHttpServer())
      .post('/health')
      .set('Content-Type', 'application/json')
      .send('{"nome":"Maria Silva","cpf":"12345678909"')
      .expect(400);

    expect(response.body).toMatchObject({ code: 'FA007' });
    expect(response.headers['x-trace-id']).toBe(
      (response.body as { traceId: string }).traceId,
    );
    expect(JSON.stringify(response.body)).not.toContain('12345678909');
    expect(JSON.stringify(logs)).not.toContain('12345678909');
    expect(JSON.stringify(logs)).not.toContain('Maria');
  });
});
