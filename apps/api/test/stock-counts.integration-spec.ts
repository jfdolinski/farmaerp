// Inventário de abertura pela API contra o banco real: abrir, planilha, digitação, conferência e
// cancelar. Aplicar fica nos testes do banco (aqui zeraria o estoque que os outros testes usam).
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomBytes, randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const SUL = '019a0000-0000-7000-8000-000000000006';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

function gtin(): string {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

describe('inventário de abertura contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post' | 'put', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  beforeAll(async () => {
    const destination = new Writable({ write(_chunk: Buffer, _encoding, callback) { callback(); } });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(destination))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, OPERATOR]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
    // Inventário que ficou aberto de uma execução anterior.
    for (const row of (await call('get', `/admin/stock-counts?branch=${SUL}`).expect(200)).body as Json[]) {
      if (row.status === 'counting') await call('post', `/admin/stock-counts/${row.id as string}/cancel`).expect(200);
    }
  });

  afterAll(async () => {
    await app.close();
  });

  it('abre, recebe a planilha e a digitação, confere e cancela', async () => {
    const barcode = gtin();
    await call('post', '/admin/products').send({ displayName: `Inventário ${randomBytes(4).toString('hex')}`, barcode }).expect(201);
    const cutoffAt = new Date(Date.now() - 60_000).toISOString();

    expect(codeOf(await call('post', '/admin/stock-counts', OPERATOR).send({ branchId: SUL, cutoffAt }).expect(403))).toBe('FA002');
    expect(codeOf(await call('post', '/admin/stock-counts').send({ branchId: SUL, cutoffAt: 'ontem' }).expect(422))).toBe('FA005');
    const { id } = (await call('post', '/admin/stock-counts').send({ branchId: SUL, cutoffAt, note: 'Teste' }).expect(201)).body as { id: string };
    expect(codeOf(await call('post', '/admin/stock-counts').send({ branchId: SUL, cutoffAt }).expect(409))).toBe('FA744');

    const csv = `Código;Quantidade;Lote;Validade\r\n${barcode};2,5;;\r\n${barcode};1;;\r\nNAO-EXISTE;1;;\r\n`;
    const loaded = (await call('post', `/admin/stock-counts/${id}/file`).set('Content-Type', 'text/csv').send(csv).expect(200)).body as Json;
    expect(loaded).toMatchObject({ accepted: 2, rejected_total: 1, rejected: [{ line: 4, reason: 'Produto não encontrado pelo código.' }] });
    expect(codeOf(await call('post', `/admin/stock-counts/${id}/file`).set('Content-Type', 'text/csv').send('   ').expect(422))).toBe('FA005');

    let detail = (await call('get', `/admin/stock-counts/${id}`).expect(200)).body as Json;
    expect(detail).toMatchObject({ status: 'counting', note: 'Teste', can_change: true });
    expect(detail.items.map((i: Json) => [i.quantity, i.source])).toEqual([['3.500', 'file']]);
    expect(detail.review.find((r: Json) => r.product_name.startsWith('Inventário'))).toMatchObject({ counted: '3.500', was_counted: true });

    await call('put', `/admin/stock-counts/${id}/items`).send({ lookup: barcode, quantity: 4 }).expect(200);
    expect(codeOf(await call('put', `/admin/stock-counts/${id}/items`).send({ lookup: barcode, quantity: '4' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('put', `/admin/stock-counts/${id}/items`).send({ lookup: 'NAO-EXISTE', quantity: 1 }).expect(422))).toBe('FA004');
    detail = (await call('get', `/admin/stock-counts/${id}`).expect(200)).body as Json;
    expect(detail.items.map((i: Json) => [i.quantity, i.source])).toEqual([['4.000', 'typed']]);

    await call('post', `/admin/stock-counts/${id}/items/${detail.items[0].id as string}/remove`).expect(200);
    await call('post', `/admin/stock-counts/${id}/cancel`).expect(200);
    expect(codeOf(await call('post', `/admin/stock-counts/${id}/apply`).expect(409))).toBe('FA745');
    expect(((await call('get', `/admin/stock-counts/${id}`).expect(200)).body as Json).status).toBe('canceled');
  });
});
