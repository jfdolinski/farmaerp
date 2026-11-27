// Curva ABC de clientes (parte D do lote de 26/11) contra o banco real: parâmetros, recálculo,
// lista e a rotina.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AbcService } from './../src/customers/abc.service.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('curva ABC contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const previous = { ...process.env };
  const call = (method: 'get' | 'post' | 'put', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  beforeAll(async () => {
    process.env.ABC_WORKER = 'off';
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() })))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, OPERATOR]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
  });

  afterAll(async () => {
    await app.close();
    process.env = previous;
  });

  it('parâmetros com os padrões; quem cadastra clientes troca; valores errados recusam', async () => {
    const before = ((await call('get', '/admin/abc/settings').expect(200)).body as Json[]).find((row) => row.branch_id === BRANCH_CENTRO);
    expect(before).toMatchObject({ branch_name: 'Loja Centro', can_manage: true });
    const data = { periodDays: 180, aMinSales: 12, bMinSales: 4, aIntervalDays: 7, bIntervalDays: 15, cIntervalDays: 30 };
    expect(codeOf(await call('put', `/admin/abc/settings/${BRANCH_CENTRO}`).send({ ...data, aMinSales: '12' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('put', `/admin/abc/settings/${BRANCH_CENTRO}`).send({ ...data, bMinSales: 20 }).expect(422))).toBe('FA761');
    expect(codeOf(await call('put', `/admin/abc/settings/${BRANCH_CENTRO}`, OPERATOR).send(data).expect(403))).toBe('FA002');
    await call('put', `/admin/abc/settings/${BRANCH_CENTRO}`).send({ ...data, periodDays: 365 }).expect(200);
    const after = ((await call('get', '/admin/abc/settings').expect(200)).body as Json[]).find((row) => row.branch_id === BRANCH_CENTRO);
    expect(after).toMatchObject({ period_days: 365, a_min_sales: 12, b_min_sales: 4 });
  });

  it('recalcular agora, a lista por curva, a curva do cliente e a rotina', async () => {
    expect(codeOf(await call('post', `/admin/abc/recalculate/${BRANCH_CENTRO}`, OPERATOR).expect(403))).toBe('FA002');
    expect((await call('post', `/admin/abc/recalculate/${BRANCH_CENTRO}`).expect(200)).body).toMatchObject({ changed: expect.any(Number) });
    const all = (await call('get', `/admin/abc/customers?branch=${BRANCH_CENTRO}`).expect(200)).body as Json[];
    expect(Array.isArray(all)).toBe(true);
    expect(codeOf(await call('get', `/admin/abc/customers?branch=${BRANCH_CENTRO}&curve=D`).expect(422))).toBe('FA005');
    expect(codeOf(await call('get', '/admin/abc/customers?branch=nada').expect(422))).toBe('FA005');
    for (const curve of ['A', 'B', 'C']) {
      const rows = (await call('get', `/admin/abc/customers?branch=${BRANCH_CENTRO}&curve=${curve}`).expect(200)).body as Json[];
      expect(rows.every((row) => row.curve === curve)).toBe(true);
    }
    if (all.length > 0) {
      const curves = (await call('get', `/admin/abc/customers/${all[0].customer_id as string}`).expect(200)).body as Json[];
      expect(curves).toEqual(expect.arrayContaining([expect.objectContaining({ branch_id: BRANCH_CENTRO, curve: all[0].curve })]));
    }
    // A rotina roda o que venceu (a filial acabou de rodar as três: nada nela).
    const result = await app.get(AbcService).tick();
    expect(result).toMatchObject({ runs: expect.any(Number), changed: expect.any(Number) });
  });
});
