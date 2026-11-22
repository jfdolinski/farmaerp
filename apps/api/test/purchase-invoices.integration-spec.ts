// Importação e conferência de notas contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt, randomUUID } from 'node:crypto';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { buildNfe, testCnpj, testGtin } from './nfe-fixture.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const CENTRO_CNPJ = '11222333000181';
const SUL_CNPJ = '11222333000262';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('notas de compra contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post', path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const send = (xml: string, email = ADMIN) => call('post', '/admin/purchase-invoices', email).set('Content-Type', 'application/xml').send(xml);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

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
    await request(server).get('/admin/purchase-invoices').set('X-Forwarded-For', newIp()).expect(401);
    await request(server).post('/admin/purchase-invoices').set('X-Forwarded-For', newIp()).set('Content-Type', 'application/xml')
      .send(buildNfe({ destCnpj: CENTRO_CNPJ }).xml).expect(401);
  });

  it('importa a nota assinada, mostra na lista e no detalhe, e não aceita de novo', async () => {
    const nfe = buildNfe({
      destCnpj: CENTRO_CNPJ,
      items: [{ code: 'A1', quantity: '3.0000', value: '30.00', batches: [{ number: 'LOTE1', quantity: '3.000', expiresOn: '2028-01-31' }], anvisa: '1000000000001', pmc: '19.90' }],
    });
    const id = ((await send(nfe.xml).expect(201)).body as Json).id as string;
    const list = (await call('get', '/admin/purchase-invoices?status=review').expect(200)).body as Json[];
    expect(list.find((row) => row.id === id)).toMatchObject({ access_key: nfe.key, branch_name: 'Loja Centro', item_count: '1', pending_count: '1' });
    const detail = (await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json;
    expect(detail).toMatchObject({ access_key: nfe.key, status: 'review', emitter_cnpj: nfe.emitterCnpj, can_manage: true, invoice_total: '30.00' });
    expect(detail.items[0]).toMatchObject({ supplier_code: 'A1', quantity: '3.0000', product_id: null, anvisa_code: '1000000000001', pmc: '19.90' });
    expect(detail.items[0].batches).toEqual([{ number: 'LOTE1', quantity: 3, manufacturedOn: null, expiresOn: '2028-01-31' }]);
    expect(codeOf(await send(nfe.xml).expect(409))).toBe('FA929');
  });

  it('recusa XML alterado, corpo que não é XML e nota de filial de fora', async () => {
    const tampered = buildNfe({ destCnpj: CENTRO_CNPJ, afterSign: (xml) => xml.replace('<qCom>2.0000</qCom>', '<qCom>9.0000</qCom>') });
    expect(codeOf(await send(tampered.xml).expect(422))).toBe('FA930');
    expect(codeOf(await call('post', '/admin/purchase-invoices').send({ xml: 'x' }).expect(422))).toBe('FA930');
    expect(codeOf(await send('não é xml').expect(422))).toBe('FA930');
    expect(codeOf(await send(buildNfe({ destCnpj: testCnpj() }).xml).expect(422))).toBe('FA927');
  });

  it('arquivo acima de 5 MB responde FA933', async () => {
    const big = `<nfeProc>${'a'.repeat(5 * 1024 * 1024 + 10)}</nfeProc>`;
    expect(codeOf(await send(big).expect(413))).toBe('FA933');
  });

  it('liga à mão, duplica cadastro e descarta', async () => {
    const ean = testGtin();
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, items: [{ code: `L-${randomInt(1e9)}`, ean }, { code: `D-${randomInt(1e9)}`, ean: testGtin(), description: 'ITEM DUPLICADO' }] });
    const id = ((await send(nfe.xml).expect(201)).body as Json).id as string;
    const items = ((await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json).items as Json[];
    expect(await call('post', `/admin/purchase-invoice-items/${items[0].id}/link`).send({ productId: DIPIRONA }).expect(200).then((r) => r.body))
      .toEqual({ barcodeAdded: true, barcodeConflict: false });
    const duplicated = ((await call('post', `/admin/purchase-invoice-items/${items[1].id}/duplicate`).send({ sourceProductId: DIPIRONA }).expect(201)).body as Json).id as string;
    const after = ((await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json).items as Json[];
    expect(after.map((row) => [row.product_id, row.match_source])).toEqual([[DIPIRONA, 'manual'], [duplicated, 'duplicate']]);
    expect(after[1].product_name).toBe('ITEM DUPLICADO');

    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/discard`).send({}).expect(422))).toBe('FA302');
    await call('post', `/admin/purchase-invoices/${id}/discard`).send({ reason: 'Teste' }).expect(200);
    expect(codeOf(await call('get', `/admin/purchase-invoices/${id}`).expect(404))).toBe('FA006');
    // Nota descartada some para a conferência, como se não existisse.
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${items[0].id}/link`).send({ productId: DIPIRONA }).expect(404))).toBe('FA006');
  });

  it('o Gerente importa a nota da loja dele, mas não a de outra; o operador não importa', async () => {
    await send(buildNfe({ destCnpj: CENTRO_CNPJ }).xml, MANAGER).expect(201);
    expect(codeOf(await send(buildNfe({ destCnpj: SUL_CNPJ }).xml, MANAGER).expect(403))).toBe('FA002');
    expect(codeOf(await send(buildNfe({ destCnpj: CENTRO_CNPJ }).xml, OPERATOR).expect(403))).toBe('FA002');
    expect((await call('get', '/admin/purchase-invoices', OPERATOR).expect(200)).body).toEqual([]);
  });

  it('identificadores e filtros inválidos', async () => {
    await call('get', '/admin/purchase-invoices?status=posted').expect(422);
    await call('get', '/admin/purchase-invoices?branch=x').expect(422);
    expect(codeOf(await call('get', `/admin/purchase-invoices/${randomUUID()}`).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${randomUUID()}/link`).send({ productId: DIPIRONA }).expect(404))).toBe('FA006');
  });
});
