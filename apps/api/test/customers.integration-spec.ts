// Rotas de clientes contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
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
const SEED_CUSTOMER = '019a0000-0000-7000-8000-000000000032';
const SEED_CPF = '11144477735';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch';

function cpf(): string {
  const base = Array.from({ length: 9 }, () => randomInt(10));
  if (new Set(base).size === 1) base[0] = (base[0] + 1) % 10;
  const digit = (digits: number[]) => {
    const total = digits.reduce((sum, d, i) => sum + d * (digits.length + 1 - i), 0);
    const rest = (total * 10) % 11;
    return rest === 10 ? 0 : rest;
  };
  const first = digit(base);
  return [...base, first, digit([...base, first])].join('');
}

describe('clientes contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const logLines: string[] = [];

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const create = (body: object = {}, email = ADMIN) =>
    call('post', '/admin/customers', email).send({ personType: 'individual', document: cpf(), name: 'Cliente API', ...body });

  beforeAll(async () => {
    // Guarda o log de verdade, para conferir que nenhum documento chega até ele.
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        logLines.push(chunk.toString());
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

  it('sem sessão, responde 401', async () => {
    await request(app.getHttpServer()).get('/admin/customers').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('a lista mascara o documento, e a ficha mostra completo', async () => {
    const list = (await call('get', `/admin/customers?q=${SEED_CPF}`).expect(200)).body as Json[];
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id: SEED_CUSTOMER, document_masked: '111.***.***-35' });
    expect(JSON.stringify(list)).not.toContain(SEED_CPF);

    const detail = (await call('get', `/admin/customers/${SEED_CUSTOMER}`).expect(200)).body as Json;
    expect(detail.document).toBe(SEED_CPF);
    expect(detail.consents).toHaveLength(3);
  });

  it('cadastra, edita, inclui dependente e registra consentimento', async () => {
    const document = cpf();
    const { id } = (await create({ document: `${document.slice(0, 3)}.${document.slice(3, 6)}.${document.slice(6, 9)}-${document.slice(9)}`, birthDate: '1990-12-31' }).expect(201)).body as { id: string };
    await call('patch', `/admin/customers/${id}`).send({ document, name: 'Cliente Editado', email: 'a@b.com', state: 'SP' }).expect(200);
    await call('post', `/admin/customers/${id}/dependents`).send({ name: 'Filha', relationship: 'child', birthDate: '2015-01-01' }).expect(201);
    const first = (await call('post', `/admin/customers/${id}/consents`).send({ purpose: 'cashback', granted: true, channel: 'store' }).expect(201)).body as Json;
    const again = (await call('post', `/admin/customers/${id}/consents`).send({ purpose: 'cashback', granted: true, channel: 'store' }).expect(201)).body as Json;
    expect(first.changed).toBe(true);
    expect(again).toEqual({ id: null, changed: false });

    const detail = (await call('get', `/admin/customers/${id}`).expect(200)).body as Json;
    expect(detail).toMatchObject({ name: 'Cliente Editado', email: 'a@b.com', state: 'SP' });
    expect(detail.dependents[0]).toMatchObject({ name: 'Filha', relationship: 'child', birth_date: '2015-01-01' });
    expect(detail.consents.find((row: Json) => row.purpose === 'cashback')).toMatchObject({ granted: true, author: 'Administrador' });
    expect(detail.consent_history).toHaveLength(1);
  });

  it('a data de nascimento volta como o dia exato', async () => {
    const { id } = (await create({ birthDate: '1990-12-31' }).expect(201)).body as { id: string };
    const detail = (await call('get', `/admin/customers/${id}`).expect(200)).body as Json;
    expect(detail.birth_date).toBe('1990-12-31');
  });

  it.each<[string, object, number, string]>([
    ['CPF inválido', { document: '12345678900' }, 422, 'FA902'],
    ['sem nome', { name: '' }, 422, 'FA216'],
    ['sem documento', { document: '' }, 422, 'FA902'],
    ['documento repetido', { document: SEED_CPF }, 409, 'FA901'],
    ['data inválida', { birthDate: '2000-02-31' }, 422, 'FA005'],
    ['e-mail inválido', { email: 'sem-arroba' }, 422, 'FA904'],
  ])('recusa %s', async (_label, body, status, code) => {
    const response = await create(body).expect(status);
    expect(codeOf(response)).toBe(code);
  });

  it('o documento recusado não aparece no log nem na resposta', async () => {
    logLines.length = 0;
    const response = await create({ document: SEED_CPF }).expect(409);
    expect(JSON.stringify(response.body)).not.toContain(SEED_CPF);
    expect(logLines.join('')).not.toContain(SEED_CPF);
  });

  it('consentimento sem decisão é recusado', async () => {
    const response = await call('post', `/admin/customers/${SEED_CUSTOMER}/consents`).send({ purpose: 'marketing', channel: 'store' }).expect(422);
    expect(codeOf(response)).toBe('FA005');
  });

  describe('permissões', () => {
    it('Gerente de uma filial cadastra e atende clientes da rede', async () => {
      const { id } = (await create({}, MANAGER).expect(201)).body as { id: string };
      await call('get', `/admin/customers/${id}`, MANAGER).expect(200);
      await call('get', `/admin/customers/${SEED_CUSTOMER}`, MANAGER).expect(200);
    });

    it('Operador não vê nem cadastra', async () => {
      expect((await call('get', '/admin/customers', OPERATOR).expect(200)).body).toEqual([]);
      await call('get', `/admin/customers/${SEED_CUSTOMER}`, OPERATOR).expect(404);
      const response = await create({}, OPERATOR).expect(403);
      expect(codeOf(response)).toBe('FA002');
    });
  });
});
