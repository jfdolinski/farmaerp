// Fatura do convênio pela API contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomBytes, randomInt, randomUUID } from 'node:crypto';
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
const OPERATOR = 'operador@farmaerp.test';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch';

describe('fatura do convênio contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = MANAGER) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

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
    for (const email of [ADMIN, MANAGER, OPERATOR]) {
      const response = await request(app.getHttpServer())
        .post('/auth/login')
        .set('X-Forwarded-For', newIp())
        .send({ email, password: PASSWORD })
        .expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
  });

  afterAll(async () => {
    await app.close();
  });

  it('sem sessão, responde 401', async () => {
    await request(app.getHttpServer()).get('/admin/agreements').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('dia de fechamento, prévia e fechamento sem vendas; recusa o que não pode', async () => {
    const name = `Convênio fatura ${randomBytes(4).toString('hex')}`;
    const agreement = (await call('post', '/admin/agreements', ADMIN).send({ name }).expect(201)).body as { id: string };

    expect(codeOf(await call('patch', `/admin/agreements/${agreement.id}/closing-day`, ADMIN).send({ day: 29 }).expect(422))).toBe('FA860');
    expect(codeOf(await call('patch', `/admin/agreements/${agreement.id}/closing-day`, ADMIN).send({ day: '10' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('patch', `/admin/agreements/${agreement.id}/closing-day`, OPERATOR).send({ day: 10 }).expect(403))).toBe('FA002');
    await call('patch', `/admin/agreements/${agreement.id}/closing-day`, ADMIN).send({ day: 10 }).expect(200);
    const list = (await call('get', '/admin/agreements', ADMIN).expect(200)).body as Json[];
    expect(list.find((row) => row.id === agreement.id)).toMatchObject({ closing_day: 10 });

    const preview = (await call('get', `/admin/agreements/${agreement.id}/invoice-preview`, ADMIN).expect(200)).body as Json;
    expect(preview).toMatchObject({ agreement_name: name, closing_day: 10, items: [], total: 0 });
    expect(codeOf(await call('get', `/admin/agreements/${agreement.id}/invoice-preview?until=2026-13-01`, ADMIN).expect(422))).toBe('FA005');

    expect(codeOf(await call('post', `/admin/agreements/${agreement.id}/invoices`, ADMIN).send({}).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/agreements/${agreement.id}/invoices`, ADMIN).send({ until: preview.period_end }).expect(422))).toBe('FA856');
    expect(codeOf(await call('post', `/admin/agreements/${agreement.id}/invoices`, ADMIN).send({ until: '2999-01-01' }).expect(422))).toBe('FA857');
    expect((await call('get', `/admin/agreements/${agreement.id}/invoices`, ADMIN).expect(200)).body).toEqual([]);
  });

  it('fatura que não existe ou formato errado', async () => {
    const missing = randomUUID();
    expect(codeOf(await call('get', `/admin/agreement-invoices/${missing}`, ADMIN).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/agreement-invoices/${missing}/pay`, ADMIN).send({ paidOn: '2026-01-10' }).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/agreement-invoices/${missing}/pay`, ADMIN).send({ paidOn: 'ontem' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/agreement-invoices/${missing}/cancel`, ADMIN).send({ reason: 'x' }).expect(404))).toBe('FA006');
    expect(codeOf(await call('get', '/admin/agreement-invoices/nao-e-uuid', ADMIN).expect(422))).toBe('FA005');
  });
});
