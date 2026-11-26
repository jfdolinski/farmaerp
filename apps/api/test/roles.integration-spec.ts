// Cada rota com e sem a permissão, contra o banco real.
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
const ADMIN_ID = '019a0000-0000-7000-8000-000000000008';
const OPERATOR_ID = '019a0000-0000-7000-8000-000000000009';
const MANAGER_ID = '019a0000-0000-7000-8000-00000000000d';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';
const BRANCH_SUL = '019a0000-0000-7000-8000-000000000006';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch' | 'put';

describe('perfis e permissões contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email: string) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const rolesOf = async (email = ADMIN) =>
    (await call('get', '/admin/roles', email).expect(200)).body as Json[];
  const roleNamed = async (name: string) =>
    (await rolesOf()).find((role) => role.name === name) as Json;

  beforeAll(async () => {
    const destination = new Writable({
      write(_chunk: Buffer, _encoding, callback) {
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

  describe('sessão', () => {
    it.each([
      [ADMIN, ['users.manage', 'roles.manage', 'terminals.revoke']],
      [MANAGER, ['users.view', 'terminals.block']],
      [OPERATOR, ['sales.sell']],
    ])('%s recebe as permissões do perfil', async (email, expected) => {
      const me = (await call('get', '/auth/me', email).expect(200)).body as Json;
      expect(me.permissions).toEqual(expect.arrayContaining(expected));
      if (expected.length === 0) expect(me.permissions).toEqual([]);
      expect(me).not.toHaveProperty('isAdmin');
    });
  });

  describe('matriz de rotas', () => {
    const allowed = [200, 201];
    it.each<[string, Method, string, object | undefined, string, boolean]>([
      ['criar usuário', 'post', '/admin/users', { name: 'Teste' }, ADMIN, true],
      ['criar usuário', 'post', '/admin/users', { name: 'Teste' }, MANAGER, false],
      ['criar usuário', 'post', '/admin/users', { name: 'Teste' }, OPERATOR, false],
      ['criar perfil', 'post', '/admin/roles', { name: `P${randomBytes(3).toString('hex')}`, permissions: [] }, ADMIN, true],
      ['criar perfil', 'post', '/admin/roles', { name: 'Z', permissions: [] }, MANAGER, false],
      ['criar perfil', 'post', '/admin/roles', { name: 'Z', permissions: [] }, OPERATOR, false],
    ])('%s (%s %s), usuário %s', async (_label, method, path, body, email, expected) => {
      const response = await call(method, path, email).send(body);
      if (expected) {
        expect(allowed).toContain(response.status);
      } else {
        expect(response.status).toBe(403);
        expect(codeOf(response)).toBe('FA002');
      }
    });

    it('catálogo e perfis podem ser lidos por quem está no grupo', async () => {
      const catalog = (await call('get', '/admin/permissions', OPERATOR).expect(200)).body as Json[];
      expect(catalog).toHaveLength(54);
      expect((await rolesOf(OPERATOR)).length).toBeGreaterThanOrEqual(4);
    });

    it('o operador vê só o próprio cadastro, o gerente vê a filial, e o admin vê todos', async () => {
      const ids = async (email: string) =>
        ((await call('get', '/admin/users', email).expect(200)).body as Json[]).map((u) => u.id);
      expect(await ids(OPERATOR)).toEqual([OPERATOR_ID]);

      const manager = await ids(MANAGER);
      expect(manager).toEqual(expect.arrayContaining([MANAGER_ID, OPERATOR_ID]));
      expect(manager).not.toContain(ADMIN_ID);

      expect(await ids(ADMIN)).toEqual(expect.arrayContaining([ADMIN_ID, MANAGER_ID, OPERATOR_ID]));
    });

    it('a lista mostra os perfis e onde valem', async () => {
      const list = (await call('get', '/admin/users', ADMIN).expect(200)).body as Json[];
      const manager = list.find((user) => user.id === MANAGER_ID)!;
      expect(manager.roles).toEqual([
        expect.objectContaining({ name: 'Gerente', branch_id: BRANCH_CENTRO }),
      ]);
    });
  });

  describe('gerente', () => {
    it('não atribui nem gerencia perfis', async () => {
      const gerente = await roleNamed('Gerente');
      const response = await call('post', `/admin/users/${OPERATOR_ID}/roles`, MANAGER)
        .send({ roleId: gerente.id })
        .expect(403);
      expect(codeOf(response)).toBe('FA002');
    });

    it('não gera senha do administrador', async () => {
      const response = await call('post', `/admin/users/${ADMIN_ID}/temporary-password`, MANAGER).expect(403);
      expect(codeOf(response)).toBe('FA002');
    });

    it('não edita usuários', async () => {
      const response = await call('patch', `/admin/users/${OPERATOR_ID}`, MANAGER)
        .send({ name: 'Invadido', email: OPERATOR })
        .expect(403);
      expect(codeOf(response)).toBe('FA002');
    });
  });

  describe('atribuição', () => {
    async function newUser() {
      const created = await call('post', '/admin/users', ADMIN)
        .send({ name: 'Atribuição', email: `${randomBytes(6).toString('hex')}@exemplo.com.br` })
        .expect(201);
      return (created.body as Json).id as string;
    }

    it('atribui, reflete na sessão e retira com efeito imediato', async () => {
      const id = await newUser();
      const email = (((await call('get', '/admin/users', ADMIN).expect(200)).body as Json[])
        .find((user) => user.id === id) as Json).email as string;
      const temporary = await call('post', `/admin/users/${id}/temporary-password`, ADMIN).expect(200);
      const password = (temporary.body as Json).temporaryPassword as string;
      const login = await request(app.getHttpServer())
        .post('/auth/login')
        .set('X-Forwarded-For', newIp())
        .send({ email, password })
        .expect(200);
      const token = (login.body as Json).token as string;
      const as = (method: Method, path: string) =>
        request(app.getHttpServer())
          [method](path)
          .set('X-Forwarded-For', newIp())
          .set('Authorization', `Bearer ${token}`);
      await as('post', '/auth/change-password')
        .send({ currentPassword: password, newPassword: 'minha-senha-nova' })
        .expect(200);

      const gerente = await roleNamed('Gerente');
      const assigned = await call('post', `/admin/users/${id}/roles`, ADMIN).send({ roleId: gerente.id }).expect(201);
      expect(((await as('get', '/auth/me').expect(200)).body as Json).permissions).toContain('users.view');

      await call('post', `/admin/user-roles/${(assigned.body as Json).id}/remove`, ADMIN).expect(200);
      expect(((await as('get', '/auth/me').expect(200)).body as Json).permissions).toEqual([]);
    });

    it('perfil por filial exige o vínculo', async () => {
      const id = await newUser();
      const gerente = await roleNamed('Gerente');
      const refused = await call('post', `/admin/users/${id}/roles`, ADMIN)
        .send({ roleId: gerente.id, branchId: BRANCH_SUL })
        .expect(422);
      expect(codeOf(refused)).toBe('FA505');

      await call('put', `/admin/users/${id}/branches`, ADMIN).send({ branchIds: [BRANCH_SUL] }).expect(200);
      await call('post', `/admin/users/${id}/roles`, ADMIN)
        .send({ roleId: gerente.id, branchId: BRANCH_SUL })
        .expect(201);
    });

    it('repetir o perfil dá erro claro', async () => {
      const id = await newUser();
      const gerente = await roleNamed('Gerente');
      await call('post', `/admin/users/${id}/roles`, ADMIN).send({ roleId: gerente.id }).expect(201);
      expect(codeOf(await call('post', `/admin/users/${id}/roles`, ADMIN).send({ roleId: gerente.id }).expect(409))).toBe('FA507');
    });
  });

  describe('gestão de perfis', () => {
    it('cria, edita e exclui', async () => {
      const name = `Perfil ${randomBytes(4).toString('hex')}`;
      const created = await call('post', '/admin/roles', ADMIN)
        .send({ name, permissions: ['terminals.view'] })
        .expect(201);
      const id = (created.body as Json).id as string;

      await call('patch', `/admin/roles/${id}`, ADMIN)
        .send({ name, description: 'Descrição', permissions: ['terminals.view', 'users.view'] })
        .expect(200);
      expect((await roleNamed(name)).permissions).toEqual(['terminals.view', 'users.view']);

      await call('post', `/admin/roles/${id}/delete`, ADMIN).expect(200);
      expect(await roleNamed(name)).toBeUndefined();
    });

    it('o Administrador não pode ser alterado', async () => {
      const admin = await roleNamed('Administrador');
      expect(codeOf(await call('patch', `/admin/roles/${admin.id}`, ADMIN).send({ name: 'X', permissions: [] }).expect(409))).toBe('FA502');
      expect(codeOf(await call('post', `/admin/roles/${admin.id}/delete`, ADMIN).expect(409))).toBe('FA502');
    });

    it('perfil em uso não é excluído', async () => {
      const gerente = await roleNamed('Gerente');
      expect(codeOf(await call('post', `/admin/roles/${gerente.id}/delete`, ADMIN).expect(409))).toBe('FA503');
    });

    it('rejeita dados malformados', async () => {
      expect(codeOf(await call('post', '/admin/roles', ADMIN).send({ name: 'X', permissions: 'tudo' }).expect(422))).toBe('FA005');
      expect(codeOf(await call('post', '/admin/roles', ADMIN).send({ name: 'Y', permissions: ['nao.existe'] }).expect(422))).toBe('FA508');
    });
  });
});
