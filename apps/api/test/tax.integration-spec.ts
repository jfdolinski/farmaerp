// Tributação do produto contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt, randomUUID } from 'node:crypto';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const COMPANY = '019a0000-0000-7000-8000-000000000002';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const SUL = '019a0000-0000-7000-8000-000000000006';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'patch';

describe('tributação do produto contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const taxOf = async (email = ADMIN) =>
    (await call('get', `/admin/products/${DIPIRONA}/tax`, email).expect(200)).body as Json[];
  const setRegime = (regime: number) =>
    call('patch', `/admin/fiscal/companies/${COMPANY}/regime`).send({ regime }).expect(200);

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
    const server = app.getHttpServer();
    await request(server).get(`/admin/products/${DIPIRONA}/tax`).set('X-Forwarded-For', newIp()).expect(401);
    await request(server).get('/admin/fiscal/tax-coverage').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('o regime da empresa escolhe a regra, e a data sai como texto', async () => {
    await setRegime(1);
    const simples = (await taxOf()).find((row) => row.branch_id === CENTRO) as Json;
    expect(simples).toMatchObject({
      status: 'ok', tax_regime: 1, state: 'SP', cfop: '5405', icms_csosn: '500', icms_cst: null, valid_from: '2026-01-01',
    });

    await setRegime(3);
    const normal = (await taxOf()).find((row) => row.branch_id === CENTRO) as Json;
    expect(normal).toMatchObject({ status: 'ok', tax_regime: 3, cfop: '5102', icms_cst: '00', icms_csosn: null, class_trib: '000001' });
    expect(Number(normal.icms_rate)).toBe(18);
  });

  it('cada filial que o administrador enxerga tem a sua linha', async () => {
    const rows = await taxOf();
    expect(rows.map((row) => row.branch_id)).toEqual(expect.arrayContaining([CENTRO, SUL]));
  });

  it('o Gerente só vê as filiais dele', async () => {
    const rows = await taxOf(MANAGER);
    expect(rows.map((row) => row.branch_id)).toEqual([CENTRO]);
  });

  it('produto inexistente e identificador inválido', async () => {
    expect(codeOf(await call('get', `/admin/products/${randomUUID()}/tax`).expect(404))).toBe('FA006');
    await call('get', '/admin/products/nao-e-id/tax').expect(422);
  });

  it('a cobertura traz só totais (com a situação do Catálogo), e o Gerente vê as filiais dele', async () => {
    const admin = (await call('get', '/admin/fiscal/tax-coverage').expect(200)).body as Json[];
    const centro = admin.find((row) => row.branch_id === CENTRO) as Json;
    expect(Object.keys(centro).sort()).toEqual(['branch_id', 'catalog_problems', 'catalog_waiting', 'has_catalog_key', 'products_missing', 'products_total']);
    expect(Number(centro.products_total)).toBeGreaterThan(0);
    const manager = (await call('get', '/admin/fiscal/tax-coverage', MANAGER).expect(200)).body as Json[];
    expect(manager.map((row) => row.branch_id)).toEqual([CENTRO]);
  });

  it('quem não vê o Fiscal não recebe cobertura', async () => {
    const operator = (await call('get', '/admin/fiscal/tax-coverage', OPERATOR).expect(200)).body as Json[];
    expect(operator).toEqual([]);
  });

  it('a API não tem rota de escrita da tributação', async () => {
    await call('patch', `/admin/products/${DIPIRONA}/tax`).send({ cfop: '5102' }).expect(404);
  });
});
