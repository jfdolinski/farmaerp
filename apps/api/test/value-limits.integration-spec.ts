// Limites de valor e liberação de supervisor contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { buildNfe } from './nfe-fixture.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const CENTRO_CNPJ = '11222333000181';
const DIPIRONA_EAN = '7890000000017';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('limites e liberação de supervisor contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  let managerRole: string;
  let originalLimits: Json;

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post' | 'put', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', newIp()).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const lossBody = (quantity: number, release?: Json) => ({
    productLookup: DIPIRONA_EAN, branchId: CENTRO, quantity, batchNumber: 'LIM01', reason: 'Quebra no balcão', ...(release ? { release } : {}),
  });

  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] }).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, MANAGER, OPERATOR]) {
      const response = await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', newIp())
        .send({ email, password: PASSWORD }).expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
    const limits = (await call('get', '/admin/role-limits').expect(200)).body as Json[];
    const manager = limits.filter((row) => row.code === 'stock_loss').find((row) => row.value === '500.00') as Json;
    managerRole = manager.role_id as string;
    originalLimits = Object.fromEntries(limits.filter((row) => row.role_id === managerRole).map((row) => [row.code, row.value]));

    // Dipirona a R$ 10,50 de custo médio na Loja Centro, pelo lançamento de uma nota.
    const nfe = buildNfe({
      destCnpj: CENTRO_CNPJ,
      items: [{ code: `LIM-${randomInt(1e9)}`, ean: DIPIRONA_EAN, quantity: '10.0000', value: '105.00', batches: [{ number: 'LIM01', quantity: '10.000', expiresOn: '2029-01-31' }] }],
    });
    const id = ((await call('post', '/admin/purchase-invoices').set('Content-Type', 'application/xml').send(nfe.xml).expect(201)).body as Json).id as string;
    await call('post', `/admin/purchase-invoices/${id}/post`).expect(200);
  });

  afterAll(async () => {
    await call('put', `/admin/roles/${managerRole}/limits`).send({ limits: originalLimits });
    await app.close();
  });

  it('a tela de perfis lê e troca os limites; só quem gerencia perfis troca', async () => {
    const limits = (await call('get', '/admin/role-limits').expect(200)).body as Json[];
    expect(limits.filter((row) => row.role_id === managerRole).map((row) => row.code).sort((x: string, y: string) => x.localeCompare(y)))
      .toEqual(['cash_withdrawal', 'credit_sale', 'sale_discount', 'stock_loss']);
    expect(codeOf(await call('put', `/admin/roles/${managerRole}/limits`).send({ limits: { stock_loss: -1 } }).expect(422))).toBe('FA954');
    expect(codeOf(await call('put', `/admin/roles/${managerRole}/limits`).send({ limits: { sale_discount: 150 } }).expect(422))).toBe('FA954');
    expect(codeOf(await call('put', `/admin/roles/${managerRole}/limits`, MANAGER).send({ limits: { stock_loss: 9999 } }).expect(403))).toBe('FA002');
    await call('put', `/admin/roles/${managerRole}/limits`).send({ limits: { stock_loss: '20.00' } }).expect(200);
    expect(((await call('get', '/admin/role-limits').expect(200)).body as Json[]).find((row) => row.role_id === managerRole && row.code === 'stock_loss'))
      .toMatchObject({ value: '20.00' });
  });

  it('acima do limite pede a liberação; senha errada e a própria pessoa são recusadas', async () => {
    await call('post', '/admin/stock/losses', MANAGER).send(lossBody(1)).expect(201); // R$ 10,50.
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3)).expect(409))).toBe('FA949');
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3, { identifier: ADMIN, password: 'errada', reason: 'x' })).expect(422))).toBe('FA953');
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3, { identifier: 'ninguem@farmaerp.test', password: PASSWORD, reason: 'x' })).expect(422))).toBe('FA953');
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3, { identifier: MANAGER, password: PASSWORD, reason: 'x' })).expect(422))).toBe('FA950');
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3, { identifier: OPERATOR, password: PASSWORD, reason: 'x' })).expect(403))).toBe('FA951');
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3, { identifier: ADMIN, password: PASSWORD })).expect(422))).toBe('FA302');
    expect(codeOf(await call('post', '/admin/stock/losses', MANAGER).send({ ...lossBody(3), release: 'admin' }).expect(422))).toBe('FA005');
    await call('post', '/admin/stock/losses', MANAGER).send(lossBody(3, { identifier: ADMIN, password: PASSWORD, reason: 'Caixa amassada' })).expect(201);
  });

  it('a auditoria mostra quem pediu, quem liberou, o valor e o motivo', async () => {
    const rows = (await call('get', '/admin/supervisor-releases?action=stock.loss', MANAGER).expect(200)).body as Json[];
    expect(rows[0]).toMatchObject({
      action: 'stock.loss', value: '31.50', requester_limit: '20.00', releaser_limit: null, reason: 'Caixa amassada', branch_name: 'Loja Centro',
    });
    expect(rows[0].released_by_name).toBeTruthy();
    expect(rows[0].requested_by_name).not.toBe(rows[0].released_by_name);
    expect((await call('get', '/admin/supervisor-releases', OPERATOR).expect(200)).body).toEqual([]);
    await call('get', '/admin/supervisor-releases?from=2026-13-01').expect(422);
    await call('get', '/admin/supervisor-releases?action=perda').expect(422);
  });
});
