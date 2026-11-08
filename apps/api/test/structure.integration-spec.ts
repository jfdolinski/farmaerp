// Rotas de empresas e filiais contra o banco real, com o seed de desenvolvimento.
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
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const COMPANY = '019a0000-0000-7000-8000-000000000002';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch';

/** CNPJ válido com raiz aleatória, calculado à parte do banco. */
function cnpj(root = String(randomInt(10_000_000, 100_000_000)), order = 1): string {
  const base = `${root}${String(order).padStart(4, '0')}`;
  const digit = (value: string) => {
    let weight = 2;
    let total = 0;
    for (let i = value.length - 1; i >= 0; i -= 1) {
      total += Number(value[i]) * weight;
      weight = weight === 9 ? 2 : weight + 1;
    }
    const rest = total % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(base);
  return `${base}${first}${digit(`${base}${first}`)}`;
}

describe('empresas e filiais contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const company = (body: object = {}, email = ADMIN) =>
    call('post', '/admin/structure/companies', email).send({ cnpj: cnpj(), legalName: 'Nova Ltda', tradeName: 'Nova', ...body });
  const overview = async () => (await call('get', '/admin/structure').expect(200)).body as Json;

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
    await request(app.getHttpServer()).get('/admin/structure').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('o administrador vê empresas e filiais com endereço', async () => {
    const data = await overview();
    expect(data.canManage).toBe(true);
    expect(data.companies.map((row: Json) => row.id)).toContain(COMPANY);
    expect(data.branches.find((row: Json) => row.id === CENTRO)).toMatchObject({ company_id: COMPANY, name: 'Loja Centro', state: 'SP' });
  });

  it('sem permissão de estrutura, não vê nem altera', async () => {
    for (const email of [MANAGER, OPERATOR]) {
      expect(codeOf(await call('get', '/admin/structure', email).expect(403))).toBe('FA002');
      expect(codeOf(await company({}, email).expect(403))).toBe('FA002');
      expect(codeOf(await call('patch', `/admin/structure/branches/${CENTRO}`, email).send({ name: 'X', cnpj: cnpj() }).expect(403))).toBe('FA002');
      expect(codeOf(await call('post', `/admin/structure/branches/${CENTRO}/delete`, email).expect(403))).toBe('FA002');
    }
  });

  it('cria empresa com filial, edita, move e encerra', async () => {
    const first = cnpj();
    const { body: created } = await company({
      cnpj: first,
      branch: { name: 'Matriz Nova', state: 'RJ', postalCode: '20040-020', cityCode: '3304557', pmcRegion: '' },
    }).expect(201);
    expect(created.branchId).toBeTruthy();

    await call('patch', `/admin/structure/companies/${created.id}`).send({ legalName: 'Razão Nova', tradeName: 'Fantasia Nova' }).expect(200);

    const { body: updated } = await call('patch', `/admin/structure/branches/${created.branchId}`)
      .send({ name: 'Matriz Editada', cnpj: first, state: 'RJ', phone: '(21) 3333-4444' })
      .expect(200);
    expect(updated).toEqual({ certificateEnded: false });

    const data = await overview();
    expect(data.companies.find((row: Json) => row.id === created.id)).toMatchObject({ legal_name: 'Razão Nova', cnpj_root: first.slice(0, 8) });
    expect(data.branches.find((row: Json) => row.id === created.branchId)).toMatchObject({ name: 'Matriz Editada', phone: '2133334444', cnpj: first });

    const { body: other } = await company().expect(201);
    expect(codeOf(await call('post', `/admin/structure/companies/${created.id}/delete`).expect(409))).toBe('FA105');
    const { body: moved } = await call('post', `/admin/structure/branches/${created.branchId}/move`).send({ companyId: other.id }).expect(200);
    expect(moved).toEqual({ moved: true, certificateEnded: false });
    await call('post', `/admin/structure/companies/${created.id}/delete`).expect(200);

    await call('post', `/admin/structure/branches/${created.branchId}/delete`).expect(200);
    await call('post', `/admin/structure/companies/${other.id}/delete`).expect(200);
    const after = await overview();
    expect(after.companies.map((row: Json) => row.id)).not.toContain(other.id);
    expect(after.branches.map((row: Json) => row.id)).not.toContain(created.branchId);
  });

  it('inclui filial numa empresa, aceitando outra raiz', async () => {
    const { body: created } = await company().expect(201);
    const { body: branch } = await call('post', `/admin/structure/companies/${created.id}/branches`)
      .send({ name: 'Outra raiz', cnpj: cnpj() })
      .expect(201);
    expect(branch.id).toBeTruthy();
  });

  it.each([
    ['CNPJ inválido', { cnpj: '11111111111111' }, 422, 'FA211'],
    ['sem CNPJ', { cnpj: null }, 422, 'FA211'],
    ['sem razão social', { legalName: ' ' }, 422, 'FA216'],
    ['raiz repetida', { cnpj: '11222333000343' }, 409, 'FA213'],
    ['filial sem nome', { branch: { name: '' } }, 422, 'FA216'],
    ['filial com CEP errado', { branch: { name: 'X', postalCode: '123' } }, 422, 'FA223'],
  ])('recusa %s', async (_label, body, status, code) => {
    expect(codeOf(await company(body).expect(status))).toBe(code);
  });

  it('não encerra filial com terminal em uso', async () => {
    expect(codeOf(await call('post', `/admin/structure/branches/${CENTRO}/delete`).expect(409))).toBe('FA224');
  });

  it('identificador inválido dá erro claro', async () => {
    expect(codeOf(await call('patch', '/admin/structure/branches/abc').send({}).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/structure/branches/${CENTRO}/move`).send({ companyId: 'abc' }).expect(422))).toBe('FA005');
  });

  it('a consulta de CNPJ também responde a quem tem structure.manage, e barra quem não tem', async () => {
    expect(codeOf(await call('get', '/admin/customers/cnpj/11111111111111').expect(422))).toBe('FA902');
    expect(codeOf(await call('get', '/admin/customers/cnpj/11222333000181', OPERATOR).expect(403))).toBe('FA002');
  });
});
