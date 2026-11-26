// Profissionais da saúde pela API contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('profissionais da saúde contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post' | 'put', path: string, email = MANAGER) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  beforeAll(async () => {
    const destination = new Writable({ write(_chunk: Buffer, _encoding, callback) { callback(); } });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(destination))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [MANAGER, OPERATOR]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
  });

  afterAll(async () => {
    await app.close();
  });

  it('o gerente cadastra, busca e altera; repetido e inválido dão o código certo', async () => {
    const number = String(randomInt(100000, 999999999));
    const data = { name: 'Dra. Integração Teste', council: 'CRM', registration: number, state: 'SP', specialty: 'Clínica geral' };
    const { id } = (await call('post', '/admin/health-professionals').send(data).expect(201)).body as { id: string };
    expect(codeOf(await call('post', '/admin/health-professionals').send({ ...data, registration: `0${number}` }).expect(409))).toBe('FA733');
    expect(codeOf(await call('post', '/admin/health-professionals').send({ ...data, council: 'XYZ', registration: '1' }).expect(422))).toBe('FA734');
    expect(codeOf(await call('post', '/admin/health-professionals').send({ ...data, active: 'sim' }).expect(422))).toBe('FA734');
    expect(codeOf(await call('post', '/admin/health-professionals').send([]).expect(422))).toBe('FA005');

    const found = (await call('get', `/admin/health-professionals?busca=${number}`).expect(200)).body as Json[];
    expect(found).toEqual([expect.objectContaining({ id, name: data.name, state: 'SP', active: true, can_manage: true })]);

    await call('put', `/admin/health-professionals/${id}`).send({ ...data, active: false }).expect(200);
    expect((await call('get', `/admin/health-professionals?busca=${number}`).expect(200)).body).toEqual([]);
    expect(((await call('get', `/admin/health-professionals?busca=${number}&inativos=1`).expect(200)).body as Json[])[0])
      .toMatchObject({ id, active: false });
    expect(codeOf(await call('put', '/admin/health-professionals/nada').send(data).expect(422))).toBe('FA005');
  });

  it('o operador de caixa não cadastra nem lista', async () => {
    expect(codeOf(await call('post', '/admin/health-professionals', OPERATOR)
      .send({ name: 'Dr. Sem Permissão', council: 'CRM', registration: '1', state: 'SP' }).expect(403))).toBe('FA002');
    expect(codeOf(await call('get', '/admin/health-professionals', OPERATOR).expect(403))).toBe('FA002');
  });
});
