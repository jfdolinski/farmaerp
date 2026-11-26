// Manutenção do SNGPC pela API contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt, randomUUID } from 'node:crypto';
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
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch';

describe('SNGPC contra o banco real', () => {
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
    await request(app.getHttpServer()).get('/admin/sngpc/branches').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('abre a filial, lista e simula; quem não confere não vê nem abre', async () => {
    expect((await call('get', '/admin/sngpc/branches', OPERATOR).expect(200)).body).toEqual([]);
    expect(codeOf(await call('post', `/admin/sngpc/branches/${BRANCH_CENTRO}/open`, OPERATOR).expect(403))).toBe('FA002');
    const opened = await call('post', `/admin/sngpc/branches/${BRANCH_CENTRO}/open`, ADMIN);
    // O banco de desenvolvimento pode já ter o SNGPC aberto (testes repetidos sem zerar).
    if (opened.status === 200) expect(opened.body).toMatchObject({ inventory_lines: expect.any(Number), unbatched: expect.any(Array) });
    else expect(codeOf(opened)).toBe('FA861');
    const branches = (await call('get', '/admin/sngpc/branches', ADMIN).expect(200)).body as Json[];
    expect(branches.find((b) => b.branch_id === BRANCH_CENTRO)).toMatchObject({ opened_at: expect.any(String) });
    const rows = (await call('get', `/admin/sngpc/branches/${BRANCH_CENTRO}/movements`, ADMIN).expect(200)).body as Json[];
    expect(Array.isArray(rows)).toBe(true);
    expect(codeOf(await call('get', `/admin/sngpc/branches/${BRANCH_CENTRO}/movements?status=xyz`, ADMIN).expect(422))).toBe('FA005');
    expect((await call('post', `/admin/sngpc/branches/${BRANCH_CENTRO}/check`, ADMIN).send({ ids: [randomUUID()] }).expect(200)).body).toEqual([]);
    expect(codeOf(await call('post', `/admin/sngpc/branches/${BRANCH_CENTRO}/check`, ADMIN).send({ ids: [] }).expect(422))).toBe('FA005');
    expect(codeOf(await call('get', `/admin/sngpc/branches/${BRANCH_CENTRO}/batches`, ADMIN).expect(422))).toBe('FA005');
  });

  it('conferência pede a senha; o resto recusa o que não existe', async () => {
    const confirm = (password: string) =>
      call('post', `/admin/sngpc/branches/${BRANCH_CENTRO}/confirm`, ADMIN).send({ ids: [randomUUID()], sendOn: '2999-01-01', password });
    expect(codeOf(await confirm('senha-errada'))).toBe('FA409');
    expect(codeOf(await confirm(PASSWORD))).toBe('FA865');
    const missing = randomUUID();
    expect(codeOf(await call('patch', `/admin/sngpc/movements/${missing}`, ADMIN).send({}).expect(422))).toBe('FA005');
    expect(codeOf(await call('patch', `/admin/sngpc/movements/${missing}`, ADMIN).send({ reportedOn: '2026-01-01' }).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/sngpc/movements/${missing}/complete`, ADMIN).send({ batchId: randomUUID() }).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/sngpc/movements/${missing}/disregard`, ADMIN).send({ reason: 'x' }).expect(404))).toBe('FA006');
  });
});
