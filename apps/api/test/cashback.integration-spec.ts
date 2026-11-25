// Cashback na retaguarda contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const DEMO_CUSTOMER = '019a0000-0000-7000-8000-000000000032';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('cashback na retaguarda contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', newIp()).set('Authorization', `Bearer ${sessions.get(email)}`);

  beforeAll(async () => {
    const destination = new Writable({
      write(_chunk: Buffer, _encoding, callback) {
        callback();
      },
    });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(destination)))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, MANAGER]) {
      const response = await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', newIp())
        .send({ email, password: PASSWORD }).expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
  });

  afterAll(async () => {
    await app.close();
  });

  it('extrato do cliente e parâmetros da rede', async () => {
    expect((await call('get', `/admin/customers/${DEMO_CUSTOMER}/cashback`, MANAGER).expect(200)).body)
      .toMatchObject({ available: 0, waiting: 0, entries: [] });
    expect((await call('get', '/admin/customers/nada/cashback').expect(422)).body).toMatchObject({ code: 'FA005' });
    expect((await call('get', '/admin/cashback-policy', MANAGER).expect(200)).body)
      .toEqual({ waiting_days: 0, validity_days: 90, max_use_percent: 50, can_edit: false });
    expect((await call('post', '/admin/cashback-policy', MANAGER).send({ validityDays: 60 }).expect(403)).body).toMatchObject({ code: 'FA002' });
    expect((await call('post', '/admin/cashback-policy').send({ validityDays: 1.5 }).expect(422)).body).toMatchObject({ code: 'FA005' });
    expect((await call('post', '/admin/cashback-policy').send({ maxUsePercent: 0 }).expect(422)).body).toMatchObject({ code: 'FA853' });
    await call('post', '/admin/cashback-policy').send({ validityDays: 60 }).expect(200);
    expect((await call('get', '/admin/cashback-policy').expect(200)).body).toMatchObject({ validity_days: 60, can_edit: true });
    await call('post', '/admin/cashback-policy').send({ validityDays: 90 }).expect(200);
  });
});
