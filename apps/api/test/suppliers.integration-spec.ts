// Fornecedores e códigos de fornecedor contra o banco real, com o seed de desenvolvimento.
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
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch';

/** CNPJ válido e aleatório, com raiz que não é de empresa real conhecida. */
function cnpj(): string {
  const base = `${randomInt(10_000_000, 100_000_000)}0001`;
  const digit = (text: string) => {
    const weights = text.length === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const rest = text.split('').reduce((sum, c, i) => sum + Number(c) * weights[i], 0) % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(base);
  return `${base}${first}${digit(`${base}${first}`)}`;
}

describe('fornecedores contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const create = async (body: Json = {}, email = ADMIN) =>
    ((await call('post', '/admin/suppliers', email).send({ cnpj: cnpj(), legalName: 'Distribuidora Integração Ltda', ...body }).expect(201)).body as Json).id as string;

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
    await request(server).get('/admin/suppliers').set('X-Forwarded-For', newIp()).expect(401);
    await request(server).get(`/admin/products/${DIPIRONA}/suppliers`).set('X-Forwarded-For', newIp()).expect(401);
  });

  it('cadastra com pontuação, mostra o detalhe e acha na busca', async () => {
    const raw = cnpj();
    const masked = `${raw.slice(0, 2)}.${raw.slice(2, 5)}.${raw.slice(5, 8)}/${raw.slice(8, 12)}-${raw.slice(12)}`;
    const id = await create({ cnpj: masked, legalName: 'Medicamentos Integração Ltda', state: 'SP', stateRegistration: '110.042.490.114' });
    const detail = (await call('get', `/admin/suppliers/${id}`).expect(200)).body as Json;
    expect(detail).toMatchObject({ cnpj: raw, legal_name: 'Medicamentos Integração Ltda', state: 'SP', state_registration: '110042490114', products: [] });
    const found = (await call('get', `/admin/suppliers?q=${raw.slice(0, 8)}`).expect(200)).body as Json[];
    expect(found.map((row) => row.id)).toContain(id);
  });

  it('recusa CNPJ repetido, inválido e dados errados com o código certo', async () => {
    const shared = cnpj();
    await create({ cnpj: shared });
    expect(codeOf(await call('post', '/admin/suppliers').send({ cnpj: shared, legalName: 'Outra' }).expect(409))).toBe('FA923');
    expect(codeOf(await call('post', '/admin/suppliers').send({ cnpj: '11111111111111', legalName: 'X' }).expect(422))).toBe('FA902');
    expect(codeOf(await call('post', '/admin/suppliers').send({ cnpj: cnpj(), legalName: 'X', stateRegistration: '110042490114' }).expect(422))).toBe('FA924');
    expect(codeOf(await call('post', '/admin/suppliers').send({ cnpj: cnpj(), legalName: 1 }).expect(422))).toBe('FA005');
    expect(codeOf(await call('get', '/admin/suppliers?limit=abc').expect(422))).toBe('FA005');
  });

  it('liga o código ao produto, mostra nos dois lados e recusa código repetido', async () => {
    const id = await create();
    const code = `INT-${randomInt(1e9)}`;
    const relation = ((await call('post', `/admin/products/${DIPIRONA}/suppliers`).send({ supplierId: id, supplierCode: code, fractionQuantity: 20 }).expect(201)).body as Json).id as string;
    const onProduct = ((await call('get', `/admin/products/${DIPIRONA}/suppliers`).expect(200)).body as Json[]).find((row) => row.id === relation) as Json;
    expect(onProduct).toMatchObject({ supplier_id: id, supplier_code: code });
    expect(Number(onProduct.effective_fraction)).toBe(20);
    const onSupplier = ((await call('get', `/admin/suppliers/${id}`).expect(200)).body as Json).products as Json[];
    expect(onSupplier).toEqual([expect.objectContaining({ id: relation, product_id: DIPIRONA, product_name: expect.stringContaining('Dipirona') })]);
    expect(codeOf(await call('post', `/admin/products/${DIPIRONA}/suppliers`).send({ supplierId: id, supplierCode: code }).expect(409))).toBe('FA925');

    await call('patch', `/admin/product-suppliers/${relation}`).send({ fractionQuantity: null }).expect(200);
    const reset = ((await call('get', `/admin/products/${DIPIRONA}/suppliers`).expect(200)).body as Json[]).find((row) => row.id === relation) as Json;
    expect(reset.fraction_quantity).toBeNull();
    expect(Number(reset.effective_fraction)).toBe(1);

    await call('post', `/admin/product-suppliers/${relation}/remove`).expect(201);
    const after = (await call('get', `/admin/products/${DIPIRONA}/suppliers`).expect(200)).body as Json[];
    expect(after.map((row) => row.id)).not.toContain(relation);
  });

  it('encerrar o fornecedor tira ele da lista e encerra os códigos', async () => {
    const id = await create();
    await call('post', `/admin/products/${DIPIRONA}/suppliers`).send({ supplierId: id, supplierCode: `END-${randomInt(1e9)}` }).expect(201);
    await call('post', `/admin/suppliers/${id}/delete`).expect(201);
    expect(codeOf(await call('get', `/admin/suppliers/${id}`).expect(404))).toBe('FA006');
    const onProduct = (await call('get', `/admin/products/${DIPIRONA}/suppliers`).expect(200)).body as Json[];
    expect(onProduct.map((row) => row.supplier_id)).not.toContain(id);
  });

  it('o Gerente cadastra e liga código; o operador não vê nem altera', async () => {
    const id = await create({}, MANAGER);
    await call('post', `/admin/products/${DIPIRONA}/suppliers`, MANAGER).send({ supplierId: id, supplierCode: `GER-${randomInt(1e9)}` }).expect(201);
    expect(codeOf(await call('post', '/admin/suppliers', OPERATOR).send({ cnpj: cnpj(), legalName: 'X' }).expect(403))).toBe('FA002');
    expect((await call('get', '/admin/suppliers', OPERATOR).expect(200)).body).toEqual([]);
    expect(codeOf(await call('get', `/admin/suppliers/${id}`, OPERATOR).expect(404))).toBe('FA006');
  });

  it('identificadores inválidos e inexistentes', async () => {
    await call('get', '/admin/suppliers/nao-e-id').expect(422);
    expect(codeOf(await call('get', `/admin/suppliers/${randomUUID()}`).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/products/${DIPIRONA}/suppliers`).send({ supplierId: 'x', supplierCode: 'A' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/products/${DIPIRONA}/suppliers`).send({ supplierId: randomUUID(), supplierCode: 'A' }).expect(422))).toBe('FA004');
  });
});
