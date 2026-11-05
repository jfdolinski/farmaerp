// Login, sessão e usuários contra o banco real.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomBytes, randomInt } from 'node:crypto';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import pg from 'pg';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';

try {
  process.loadEnvFile(join(import.meta.dirname, '..', '..', '..', '.env'));
} catch {
  // Sem arquivo .env, valem as variáveis do ambiente.
}

const ADMIN_EMAIL = 'admin@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const MANAGER_EMAIL = 'gerente@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const OPERATOR_ID = '019a0000-0000-7000-8000-000000000009';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';
const BRANCH_SUL = '019a0000-0000-7000-8000-000000000006';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('login e usuários contra o banco real', () => {
  let app: INestApplication<App>;
  let logs: string[] = [];
  let ip: string;

  const newIp = () =>
    `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const server = () => request(app.getHttpServer());
  const login = (email: string, password: string) =>
    server()
      .post('/auth/login')
      .set('X-Forwarded-For', ip)
      .send({ email, password });
  const as = (token: string) => ({
    get: (path: string) =>
      server().get(path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`),
    post: (path: string) =>
      server().post(path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`),
    patch: (path: string) =>
      server().patch(path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`),
    put: (path: string) =>
      server().put(path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`),
  });
  const tokenOf = async (email: string, password = DEV_PASSWORD) =>
    ((await login(email, password).expect(200)).body as Json).token as string;
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const uniqueEmail = () => `${randomBytes(6).toString('hex')}@exemplo.com.br`;

  /** Cria um usuário com acesso e devolve a sessão dele, já com a senha trocada. */
  async function newUser(adminToken: string, overrides: Json = {}) {
    const email = uniqueEmail();
    const created = await as(adminToken)
      .post('/admin/users')
      .send({ name: 'Usuário de teste', email, ...overrides })
      .expect(201);
    const id = (created.body as Json).id as string;
    const temporary = await as(adminToken)
      .post(`/admin/users/${id}/temporary-password`)
      .expect(200);
    return { id, email, temporaryPassword: (temporary.body as Json).temporaryPassword as string };
  }

  beforeAll(async () => {
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        logs.push(chunk.toString());
        callback();
      },
    });
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(destination)))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
  });

  beforeEach(() => {
    logs = [];
    ip = newIp();
  });

  afterAll(async () => {
    await app.close();
  });

  describe('login', () => {
    it('entra com e-mail e senha, sem diferenciar maiúsculas no e-mail', async () => {
      const response = await login(' ADMIN@farmaerp.test ', DEV_PASSWORD).expect(200);
      expect(response.body).toMatchObject({ mustChangePassword: false });
      const me = await as((response.body as Json).token as string).get('/auth/me').expect(200);
      expect(me.body).toMatchObject({ email: ADMIN_EMAIL });
      expect((me.body as Json).permissions).toContain('users.manage');
      expect(JSON.stringify(me.body)).not.toContain('argon2');
    });

    it('senha errada e e-mail desconhecido dão a mesma resposta', async () => {
      const wrong = await login(ADMIN_EMAIL, 'senha-errada-aqui').expect(401);
      const unknown = await login('ninguem@exemplo.com.br', 'senha-errada-aqui').expect(401);
      const strip = (response: request.Response) => {
        const { traceId: _traceId, ...rest } = response.body as Json;
        return rest;
      };
      expect(codeOf(wrong)).toBe('FA401');
      expect(strip(wrong)).toEqual(strip(unknown));
    });

    it('bloqueia a conta depois de 5 falhas, com a mesma mensagem, mesmo com a senha certa', async () => {
      const adminToken = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(adminToken);
      for (let i = 0; i < 5; i += 1) {
        ip = newIp();
        await login(user.email, 'senha-errada-aqui').expect(401);
      }
      ip = newIp();
      expect(codeOf(await login(user.email, user.temporaryPassword).expect(401))).toBe('FA401');

      // A nova senha temporária desbloqueia.
      const temporary = await as(adminToken).post(`/admin/users/${user.id}/temporary-password`).expect(200);
      await login(user.email, (temporary.body as Json).temporaryPassword as string).expect(200);
    });

    it('limita as tentativas por IP', async () => {
      for (let i = 0; i < 10; i += 1) {
        await login('ninguem@exemplo.com.br', 'senha-errada-aqui').expect(401);
      }
      expect(codeOf(await login('ninguem@exemplo.com.br', 'senha-errada-aqui').expect(429))).toBe('FA009');
    });

    it.each([
      ['sem e-mail', { password: 'x' }],
      ['sem senha', { email: ADMIN_EMAIL }],
      ['com tipo errado', { email: 1, password: 2 }],
    ])('rejeita pedido %s', async (_label, body) => {
      const response = await server().post('/auth/login').set('X-Forwarded-For', ip).send(body).expect(422);
      expect(codeOf(response)).toBe('FA005');
    });

    it('o log não recebe senha, token nem e-mail', async () => {
      const response = await login(ADMIN_EMAIL, DEV_PASSWORD).expect(200);
      await login(OPERATOR_EMAIL, 'senha-errada-aqui').expect(401);
      const joined = logs.join('');
      expect(joined).toContain('requisição concluída');
      expect(joined).not.toContain(DEV_PASSWORD);
      expect(joined).not.toContain('senha-errada-aqui');
      expect(joined).not.toContain((response.body as Json).token as string);
      expect(joined).not.toContain(ADMIN_EMAIL);
      expect(joined).not.toContain(OPERATOR_EMAIL);
    });
  });

  describe('sessão', () => {
    it.each([
      ['sem cabeçalho', undefined],
      ['token inválido', 'Bearer abc'],
      ['outro esquema', 'Basic abc'],
    ])('rota protegida recusa %s', async (_label, header) => {
      const call = server().get('/admin/terminals').set('X-Forwarded-For', ip);
      if (header) call.set('Authorization', header);
      expect(codeOf(await call.expect(401))).toBe('FA402');
    });

    it('o cabeçalho antigo de identidade não funciona mais', async () => {
      const response = await server()
        .get('/admin/terminals')
        .set('X-Forwarded-For', ip)
        .set('X-Dev-User-Id', '019a0000-0000-7000-8000-000000000008')
        .expect(401);
      expect(codeOf(response)).toBe('FA402');
    });

    it('sair encerra a sessão na hora', async () => {
      const token = await tokenOf(ADMIN_EMAIL);
      await as(token).post('/auth/logout').expect(200);
      expect(codeOf(await as(token).get('/auth/me').expect(401))).toBe('FA402');
    });

    it('desativar o usuário encerra a sessão na hora', async () => {
      const adminToken = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(adminToken);
      const token = await tokenOf(user.email, user.temporaryPassword);
      await as(token).get('/auth/me').expect(200);

      await as(adminToken)
        .patch(`/admin/users/${user.id}`)
        .send({ name: 'Usuário de teste', email: user.email, isActive: false })
        .expect(200);

      expect(codeOf(await as(token).get('/auth/me').expect(401))).toBe('FA402');
      expect(codeOf(await login(user.email, user.temporaryPassword).expect(401))).toBe('FA401');
    });

    it('a sessão usa o usuário dela nas consultas com RLS', async () => {
      const token = await tokenOf(MANAGER_EMAIL);
      const response = await as(token).get('/admin/terminals').expect(200);
      expect(new Set((response.body as Json[]).map((t) => t.branch_id))).toEqual(new Set([BRANCH_CENTRO]));
    });
  });

  describe('troca de senha', () => {
    it('senha temporária só libera a troca, e depois tudo funciona', async () => {
      const adminToken = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(adminToken);

      const first = await login(user.email, user.temporaryPassword).expect(200);
      expect(first.body).toMatchObject({ mustChangePassword: true });
      const token = (first.body as Json).token as string;

      await as(token).get('/auth/me').expect(200);
      expect(codeOf(await as(token).get('/admin/terminals').expect(403))).toBe('FA403');

      await as(token)
        .post('/auth/change-password')
        .send({ currentPassword: user.temporaryPassword, newPassword: 'minha-senha-nova' })
        .expect(200);

      await as(token).get('/admin/terminals').expect(200);
      expect(codeOf(await login(user.email, user.temporaryPassword).expect(401))).toBe('FA401');
      await login(user.email, 'minha-senha-nova').expect(200);
    });

    it('encerra as outras sessões e mantém a atual', async () => {
      const adminToken = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(adminToken);
      const current = await tokenOf(user.email, user.temporaryPassword);
      const other = await tokenOf(user.email, user.temporaryPassword);

      await as(current)
        .post('/auth/change-password')
        .send({ currentPassword: user.temporaryPassword, newPassword: 'minha-senha-nova' })
        .expect(200);

      await as(current).get('/auth/me').expect(200);
      expect(codeOf(await as(other).get('/auth/me').expect(401))).toBe('FA402');
    });

    it.each([
      ['senha atual errada', () => ({ currentPassword: 'errada-errada', newPassword: 'minha-senha-nova' }), 'FA409'],
      ['senha nova curta', (u: Json) => ({ currentPassword: u.temporaryPassword, newPassword: 'curta' }), 'FA404'],
      ['senha nova igual à atual', (u: Json) => ({ currentPassword: u.temporaryPassword, newPassword: u.temporaryPassword }), 'FA404'],
      ['senha nova igual ao e-mail', (u: Json) => ({ currentPassword: u.temporaryPassword, newPassword: u.email }), 'FA404'],
    ])('recusa %s', async (_label, bodyOf: (u: Json) => Json, code) => {
      const adminToken = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(adminToken);
      const token = await tokenOf(user.email, user.temporaryPassword);
      const response = await as(token).post('/auth/change-password').send(bodyOf(user)).expect(422);
      expect(codeOf(response)).toBe(code);
    });
  });

  describe('usuários', () => {
    it('admin cria usuário com código, e operador de caixa não precisa de e-mail', async () => {
      const token = await tokenOf(ADMIN_EMAIL);
      const created = await as(token).post('/admin/users').send({ name: 'Caixa da loja' }).expect(201);
      expect((created.body as Json).code).toBeGreaterThan(0);

      const list = await as(token).get('/admin/users').expect(200);
      const row = (list.body as Json[]).find((user) => user.id === (created.body as Json).id);
      expect(row).toMatchObject({ name: 'Caixa da loja', email: null, has_access: false, branch_ids: [] });
    });

    it('a lista nunca traz dados de senha', async () => {
      const token = await tokenOf(ADMIN_EMAIL);
      const list = await as(token).get('/admin/users').expect(200);
      expect(JSON.stringify(list.body)).not.toMatch(/argon2|password_hash/);
    });

    it('senha temporária exige e-mail', async () => {
      const token = await tokenOf(ADMIN_EMAIL);
      const created = await as(token).post('/admin/users').send({ name: 'Sem e-mail' }).expect(201);
      const response = await as(token)
        .post(`/admin/users/${(created.body as Json).id}/temporary-password`)
        .expect(422);
      expect(codeOf(response)).toBe('FA408');
    });

    it('o log não recebe a senha temporária', async () => {
      const token = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(token);
      expect(logs.join('')).not.toContain(user.temporaryPassword);
    });

    it('e-mail repetido e inválido dão erros claros', async () => {
      const token = await tokenOf(ADMIN_EMAIL);
      expect(codeOf(await as(token).post('/admin/users').send({ name: 'X', email: ADMIN_EMAIL }).expect(409))).toBe('FA406');
      expect(codeOf(await as(token).post('/admin/users').send({ name: 'X', email: 'sem-arroba' }).expect(422))).toBe('FA407');
    });

    it('define as filiais do usuário e reflete na RLS', async () => {
      const adminToken = await tokenOf(ADMIN_EMAIL);
      const user = await newUser(adminToken);
      const change = await tokenOf(user.email, user.temporaryPassword);
      await as(change)
        .post('/auth/change-password')
        .send({ currentPassword: user.temporaryPassword, newPassword: 'minha-senha-nova' })
        .expect(200);

      const branches = async () =>
        (await as(change).get('/admin/branches').expect(200)).body as Json[];
      expect(await branches()).toEqual([]);

      await as(adminToken).put(`/admin/users/${user.id}/branches`).send({ branchIds: [BRANCH_CENTRO, BRANCH_SUL] }).expect(200);
      expect((await branches()).map((b) => b.id as string).sort((x, y) => x.localeCompare(y))).toEqual([BRANCH_CENTRO, BRANCH_SUL]);

      await as(adminToken).put(`/admin/users/${user.id}/branches`).send({ branchIds: [BRANCH_SUL] }).expect(200);
      expect((await branches()).map((b) => b.id)).toEqual([BRANCH_SUL]);

      // Repetir não duplica.
      await as(adminToken).put(`/admin/users/${user.id}/branches`).send({ branchIds: [BRANCH_SUL] }).expect(200);
      const list = (await as(adminToken).get('/admin/users').expect(200)).body as Json[];
      expect(list.find((u) => u.id === user.id)?.branch_ids).toEqual([BRANCH_SUL]);
    });

    it('não desativa o último administrador', async () => {
      // Grupo próprio, para não depender dos admins criados em outros testes.
      const owner = new pg.Client({
        host: process.env.DB_HOST ?? '127.0.0.1',
        port: Number(process.env.DB_PORT ?? 5432),
        user: 'farmaerp_migrator',
        password: process.env.FARMAERP_MIGRATOR_PASSWORD,
        database: 'farmaerp_integration',
      });
      await owner.connect();
      const email = uniqueEmail();
      const { rows: [group] } = await owner.query<{ id: string }>(
        `INSERT INTO economic_group (name) VALUES ('Sozinho') RETURNING id`,
      );
      const { rows: [admin] } = await owner.query<{ id: string }>(
        `INSERT INTO user_account (economic_group_id, name, email) VALUES ($1, 'Único', $2) RETURNING id`,
        [group.id, email],
      );
      await owner.query(
        `INSERT INTO user_role (user_id, role_id)
         SELECT $1, id FROM role WHERE economic_group_id = $2 AND system_key = 'administrator'`,
        [admin.id, group.id],
      );
      const { argon2id, hash } = await import('argon2');
      await owner.query(
        'INSERT INTO user_credential (user_id, password_hash, must_change_password) VALUES ($1, $2, false)',
        [admin.id, await hash('senha-do-unico-admin', { type: argon2id })],
      );
      await owner.end();

      const token = await tokenOf(email, 'senha-do-unico-admin');
      const response = await as(token)
        .patch(`/admin/users/${admin.id}`)
        .send({ name: 'Único', email, isActive: false })
        .expect(409);
      expect(codeOf(response)).toBe('FA405');
    });

    describe('permissões', () => {
      it('operador não cria, não altera nem gera senha', async () => {
        const token = await tokenOf(OPERATOR_EMAIL);
        expect(codeOf(await as(token).post('/admin/users').send({ name: 'X' }).expect(403))).toBe('FA002');
        expect(codeOf(await as(token).patch(`/admin/users/${OPERATOR_ID}`).send({ name: 'X' }).expect(403))).toBe('FA002');
        expect(codeOf(await as(token).post(`/admin/users/${OPERATOR_ID}/temporary-password`).expect(403))).toBe('FA002');
        expect(codeOf(await as(token).put(`/admin/users/${OPERATOR_ID}/branches`).send({ branchIds: [BRANCH_SUL] }).expect(403))).toBe('FA002');
      });

      it('operador vê só o próprio cadastro', async () => {
        const token = await tokenOf(OPERATOR_EMAIL);
        const list = (await as(token).get('/admin/users').expect(200)).body as Json[];
        expect(list.map((user) => user.id)).toEqual([OPERATOR_ID]);
      });
    });
  });
});
