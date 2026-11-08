// Rotas de séries contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const TERMINAL = '019a0000-0000-7000-8000-000000000007';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'patch';

describe('séries por terminal contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const listOf = async (email = ADMIN) => (await call('get', '/admin/fiscal/series', email).expect(200)).body as Json[];
  const seriesOf = async (model: string, email = ADMIN) =>
    (await listOf(email)).find((row) => row.terminal_id === TERMINAL && row.model === model) as Json;

  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] }).compile();
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
    await request(app.getHttpServer()).get('/admin/fiscal/series').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('o caixa do seed tem NFC-e e NF-e', async () => {
    const nfce = await seriesOf('65');
    const nfe = await seriesOf('55');
    expect(nfce).toMatchObject({ terminal_name: 'Caixa 1', initial_number: '1', last_used_number: null, can_manage: true });
    expect(nfe).toMatchObject({ terminal_name: 'Caixa 1', initial_number: '1', last_used_number: null, can_manage: true });
  });

  it('o administrador ajusta série e número inicial', async () => {
    const { id } = await seriesOf('65');
    await call('patch', `/admin/fiscal/series/${id}`).send({ series: 42, initialNumber: 1500 }).expect(200);
    expect(await seriesOf('65')).toMatchObject({ series: 42, initial_number: '1500' });
  });

  it.each([
    ['série reservada', { series: 890, initialNumber: 1 }],
    ['série zero', { series: 0, initialNumber: 1 }],
    ['número grande demais', { series: 1, initialNumber: 1_000_000_000 }],
    ['série em texto', { series: '1', initialNumber: 1 }],
    ['número quebrado', { series: 1, initialNumber: 1.5 }],
    ['sem número', { series: 1 }],
    ['série além do tipo', { series: 99_999_999_999, initialNumber: 1 }],
  ])('recusa %s', async (_label, body) => {
    const { id } = await seriesOf('65');
    expect(codeOf(await call('patch', `/admin/fiscal/series/${id}`).send(body).expect(422))).toBe('FA919');
  });

  it('identificador inválido dá erro claro, e série inexistente não é encontrada', async () => {
    expect(codeOf(await call('patch', '/admin/fiscal/series/abc').send({ series: 1, initialNumber: 1 }).expect(422))).toBe('FA005');
    const missing = await call('patch', '/admin/fiscal/series/019a0000-0000-7000-8000-00000000ffff').send({ series: 1, initialNumber: 1 });
    expect(codeOf(missing)).toBe('FA006');
  });

  it('o Gerente consulta, mas não altera', async () => {
    const row = await seriesOf('55', MANAGER);
    expect(row.can_manage).toBe(false);
    expect(codeOf(await call('patch', `/admin/fiscal/series/${row.id}`, MANAGER).send({ series: 5, initialNumber: 1 }).expect(403))).toBe('FA002');
  });
});
