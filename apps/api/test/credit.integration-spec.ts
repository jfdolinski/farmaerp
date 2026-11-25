// Crediário pela API contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomBytes, randomInt } from 'node:crypto';
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
type Method = 'get' | 'post';

// CPF de teste, gerado ao acaso (nunca de pessoa real).
function cpf(): string {
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits: number[]) => {
    const rest = (digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0) * 10) % 11;
    return rest === 10 ? 0 : rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}

describe('crediário contra o banco real', () => {
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
    await request(app.getHttpServer()).get('/admin/credit/accounts').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('abre a conta, muda limite, bloqueia e define vencimentos; recusa o que não pode', async () => {
    const created = await call('post', '/admin/customers', ADMIN)
      .send({ personType: 'individual', document: cpf(), name: `Cliente crediário ${randomBytes(3).toString('hex')}` })
      .expect(201);
    const customerId = (created.body as Json).id as string;
    expect((await call('get', `/admin/credit/customers/${customerId}`).expect(200)).body).toMatchObject({
      account: null, can_open: true, suggested_limits: [expect.objectContaining({ branch_id: BRANCH_CENTRO, suggested_limit: 0 })],
    });
    expect(codeOf(await call('post', `/admin/credit/customers/${customerId}/open`, OPERATOR)
      .send({ homeBranchId: BRANCH_CENTRO, creditLimit: 100 }).expect(403))).toBe('FA002');
    expect(codeOf(await call('post', `/admin/credit/customers/${customerId}/open`).send({ homeBranchId: BRANCH_CENTRO, creditLimit: 'cem' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/credit/customers/${customerId}/open`).send({ homeBranchId: BRANCH_CENTRO, creditLimit: -5 }).expect(422))).toBe('FA838');
    const accountId = ((await call('post', `/admin/credit/customers/${customerId}/open`)
      .send({ homeBranchId: BRANCH_CENTRO, creditLimit: 150 }).expect(201)).body as Json).id as string;
    expect(codeOf(await call('post', `/admin/credit/customers/${customerId}/open`).send({ homeBranchId: BRANCH_CENTRO, creditLimit: 1 }).expect(409))).toBe('FA835');

    expect(codeOf(await call('post', `/admin/credit/accounts/${accountId}/limit`).send({ creditLimit: 200 }).expect(422))).toBe('FA302');
    await call('post', `/admin/credit/accounts/${accountId}/limit`).send({ creditLimit: 200, reason: 'Bom pagador' }).expect(200);
    await call('post', `/admin/credit/accounts/${accountId}/status`).send({ status: 'blocked', reason: 'Pedido do cliente' }).expect(200);
    expect(codeOf(await call('post', `/admin/credit/accounts/${accountId}/status`).send({ status: 'blocked', reason: 'De novo' }).expect(409))).toBe('FA836');
    expect(codeOf(await call('post', `/admin/credit/accounts/${accountId}/status`).send({ status: 'outro', reason: 'x' }).expect(422))).toBe('FA005');
    await call('post', `/admin/credit/accounts/${accountId}/terms`).send({ dueMode: 'days', intervalDays: 15 }).expect(200);
    expect(codeOf(await call('post', `/admin/credit/accounts/${accountId}/terms`).send({ dueMode: 'closing', closingDay: 30, dueDay: 10 }).expect(422))).toBe('FA837');

    const detail = (await call('get', `/admin/credit/customers/${customerId}`).expect(200)).body as Json;
    expect(detail.account).toMatchObject({ credit_limit: 200, status: 'blocked', terms: { due_mode: 'days', interval_days: 15, own: true } });
    expect((detail.events as Json[]).map((e) => e.kind)).toEqual(['terms', 'blocked', 'limit', 'opened']);
    const blocked = (await call('get', '/admin/credit/accounts?situation=blocked').expect(200)).body as Json[];
    expect(blocked.some((row) => row.account_id === accountId)).toBe(true);
    expect(codeOf(await call('get', '/admin/credit/accounts?situation=outra').expect(422))).toBe('FA005');
    expect((await call('get', '/admin/credit/accounts', OPERATOR).expect(200)).body).toEqual([]);
    expect(codeOf(await call('get', '/admin/credit/customers/nada').expect(422))).toBe('FA005');
  });

  it('parâmetros da filial: o Gerente vê, só o Administrador muda', async () => {
    const forManager = (await call('get', '/admin/credit/policies').expect(200)).body as Json[];
    expect(forManager.find((row) => row.branch_id === BRANCH_CENTRO)).toMatchObject({ can_edit: false });
    expect(codeOf(await call('post', `/admin/credit/policies/${BRANCH_CENTRO}`).send({ maxInstallments: 4 }).expect(403))).toBe('FA002');
    expect(codeOf(await call('post', `/admin/credit/policies/${BRANCH_CENTRO}`, ADMIN).send({ lateFeePercent: 5 }).expect(422))).toBe('FA837');
    expect(codeOf(await call('post', `/admin/credit/policies/${BRANCH_CENTRO}`, ADMIN).send({ dueMode: 'semanal' }).expect(422))).toBe('FA005');
    await call('post', `/admin/credit/policies/${BRANCH_CENTRO}`, ADMIN).send({ maxInstallments: 4 }).expect(200);
    const after = (await call('get', '/admin/credit/policies', ADMIN).expect(200)).body as Json[];
    expect(after.find((row) => row.branch_id === BRANCH_CENTRO)).toMatchObject({ customized: true, can_edit: true, policy: { max_installments: 4, late_fee_percent: 2 } });
  });
});
