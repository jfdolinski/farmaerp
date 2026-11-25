// Plataforma contra o banco real: empresa nova como cliente separado, com o seed de desenvolvimento.
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

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

// CNPJ de teste, gerado ao acaso.
function cnpj(): string {
  const base = Array.from({ length: 12 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits: number[]) => {
    const weights = digits.length === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const rest = digits.reduce((sum, d, i) => sum + d * weights[i], 0) % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}

describe('plataforma contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const login = async (email: string, password: string) =>
    (await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', newIp()).send({ email, password }).expect(200)).body as Json;
  const call = (method: 'get' | 'post', path: string, token: string) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', newIp()).set('Authorization', `Bearer ${token}`);

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
    for (const email of [ADMIN, MANAGER]) sessions.set(email, (await login(email, PASSWORD)).token as string);
  });

  afterAll(async () => {
    await app.close();
  });

  it('só o administrador da plataforma vê e cadastra; a empresa nova não vê nada da rede de demonstração', async () => {
    expect((await call('get', '/auth/me', sessions.get(ADMIN)!).expect(200)).body).toMatchObject({ platformAdmin: true });
    expect((await call('get', '/auth/me', sessions.get(MANAGER)!).expect(200)).body).toMatchObject({ platformAdmin: false });
    expect((await call('get', '/platform/tenants', sessions.get(MANAGER)!).expect(403)).body).toMatchObject({ code: 'FA002' });

    const email = `dona-${randomBytes(4).toString('hex')}@farmacia.test`;
    const body = {
      groupName: `Farmácia Nova ${randomBytes(3).toString('hex')}`, cnpj: cnpj(), legalName: 'Farmácia Nova Ltda', tradeName: 'Farmácia Nova',
      branch: { name: 'Matriz', state: 'SP', city: 'Campinas' },
      admin: { name: 'Dona da Farmácia', email },
    };
    expect((await call('post', '/platform/tenants', sessions.get(MANAGER)!).send(body).expect(403)).body).toMatchObject({ code: 'FA002' });
    expect((await call('post', '/platform/tenants', sessions.get(ADMIN)!).send({ ...body, cnpj: undefined }).expect(422)).body)
      .toMatchObject({ code: 'FA005' });
    const created = (await call('post', '/platform/tenants', sessions.get(ADMIN)!).send(body).expect(201)).body as Json;
    expect(created).toMatchObject({ groupId: expect.any(String), branchId: expect.any(String), temporaryPassword: expect.any(String) });
    expect((await call('post', '/platform/tenants', sessions.get(ADMIN)!).send(body).expect(409)).body).toMatchObject({ code: 'FA213' });
    const tenants = (await call('get', '/platform/tenants', sessions.get(ADMIN)!).expect(200)).body as Json[];
    expect(tenants.find((t) => t.group_id === created.groupId)).toMatchObject({ name: body.groupName, branch_count: 1, user_count: 1, admin_email: email });

    // O administrador novo entra com a senha temporária, troca e só vê o que é dele.
    const first = await login(email, created.temporaryPassword as string);
    expect(first.mustChangePassword).toBe(true);
    await call('post', '/auth/change-password', first.token as string)
      .send({ currentPassword: created.temporaryPassword, newPassword: 'senha-nova-da-farmacia' })
      .expect(200);
    const token = (await login(email, 'senha-nova-da-farmacia')).token as string;
    expect((await call('get', '/auth/me', token).expect(200)).body).toMatchObject({ platformAdmin: false });
    expect((await call('get', '/platform/tenants', token).expect(403)).body).toMatchObject({ code: 'FA002' });
    const structure = (await call('get', '/admin/structure', token).expect(200)).body as Json;
    expect((structure.branches as Json[]).map((b) => b.id)).toEqual([created.branchId]);
    expect((await call('get', '/admin/customers', token).expect(200)).body).toMatchObject([]);
    expect(((await call('get', '/admin/users', token).expect(200)).body as Json[]).map((u) => u.email)).toEqual([email]);
    expect((await call('get', '/admin/terminals', token).expect(200)).body).toEqual([]);
  });
});
