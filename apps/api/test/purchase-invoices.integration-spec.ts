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

  it('lança, mostra o custo, recusa liberação sem senha certa e estorna', async () => {
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, items: [{ code: `P-${randomInt(1e9)}`, ean: testGtin(), quantity: '4.0000', value: '40.00', description: 'ITEM PARA LANCAR' }] });
    const id = ((await send(nfe.xml).expect(201)).body as Json).id as string;
    const [item] = ((await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json).items as Json[];
    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/post`).expect(422))).toBe('FA934');
    const productId = ((await call('post', `/admin/purchase-invoice-items/${item.id}/duplicate`).send({ sourceProductId: DIPIRONA }).expect(201)).body as Json).id as string;

    const before = (await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json;
    expect(before).toMatchObject({ can_post: true, can_override_cost: true, events: [] });
    expect(before.items[0].posting).toMatchObject({ cost_status: 'first_entry', unit_cost: '10.000000', stock_quantity: '4.000', batch_status: 'not_required' });

    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/release-cost`).send({ reason: 'x', password: 'errada' }).expect(422))).toBe('FA409');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/release-cost`).send({ reason: 'x' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/release-cost`).send({ reason: 'x', password: PASSWORD }).expect(409))).toBe('FA941');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/batches`).send({ batches: 'x' }).expect(422))).toBe('FA936');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/batches`).send({ batches: [{ number: 'L1' }] }).expect(422))).toBe('FA936');
    await call('post', `/admin/purchase-invoice-items/${item.id}/batches`).send({ batches: [] }).expect(200);

    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/post`, OPERATOR).expect(403))).toBe('FA002');
    await call('post', `/admin/purchase-invoices/${id}/post`).expect(200);
    const after = (await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json;
    expect(after.status).toBe('posted');
    expect(after.items[0].posting).toMatchObject({ cost_status: 'posted', new_average_cost: '10.000000' });
    expect(after.events).toEqual([expect.objectContaining({ kind: 'posted', reason: null, user_name: expect.any(String) })]);
    const costs = (await call('get', `/admin/products/${productId}/average-costs`).expect(200)).body as Json[];
    expect(costs).toEqual([expect.objectContaining({ branch_name: 'Loja Centro', average_cost: '10.000000', stock_quantity: '4.000' })]);
    expect((await call('get', `/admin/products/${productId}/average-costs`, OPERATOR).expect(200)).body).toEqual([]);

    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/discard`).send({ reason: 'x' }).expect(409))).toBe('FA940');
    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/reverse`).send({}).expect(422))).toBe('FA302');
    await call('post', `/admin/purchase-invoices/${id}/reverse`).send({ reason: 'Teste de estorno' }).expect(200);
    expect(((await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json).status).toBe('review');
    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/reverse`).send({ reason: 'de novo' }).expect(409))).toBe('FA939');
  });

  it('altera o fracionamento da nota lançada e cancela; o operador não faz nenhum dos dois', async () => {
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, items: [{ code: `P-${randomInt(1e9)}`, ean: testGtin(), quantity: '2.0000', value: '20.00', description: 'ITEM PARA CANCELAR' }] });
    const id = ((await send(nfe.xml).expect(201)).body as Json).id as string;
    const [item] = ((await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json).items as Json[];
    await call('post', `/admin/purchase-invoice-items/${item.id}/duplicate`).send({ sourceProductId: DIPIRONA }).expect(201);
    await call('post', `/admin/purchase-invoices/${id}/post`).expect(200);

    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/fraction`).send({ fraction: '5', reason: 'x' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/fraction`).send({ fraction: 5 }).expect(422))).toBe('FA302');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${item.id}/fraction`, OPERATOR).send({ fraction: 5, reason: 'x' }).expect(403))).toBe('FA002');
    await call('post', `/admin/purchase-invoice-items/${item.id}/fraction`).send({ fraction: 5, reason: 'Caixa com 5' }).expect(200);
    const changed = (await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json;
    expect(changed).toMatchObject({ can_cancel: true, can_negative_stock: true, cancel_reason: null, cancelled_by_name: null });
    expect(changed.items[0]).toMatchObject({ fraction: '5.000', stock_quantity: '10.000' });
    expect(changed.items[0].posting).toMatchObject({ fraction: '5.000', stock_quantity: '10.000', unit_cost: '2.000000' });
    expect(changed.audit[0]).toMatchObject({ kind: 'fraction_changed', detail: expect.objectContaining({ from: 1, to: 5 }) });

    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/cancel`, OPERATOR).send({ reason: 'x' }).expect(403))).toBe('FA002');
    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/cancel`).send({}).expect(422))).toBe('FA302');
    await call('post', `/admin/purchase-invoices/${id}/cancel`).send({ reason: 'Mercadoria não veio' }).expect(200);
    const cancelled = (await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json;
    expect(cancelled).toMatchObject({ status: 'cancelled', cancel_reason: 'Mercadoria não veio', cancelled_by_name: expect.any(String), cancelled_at: null });
    expect(cancelled.events.map((event: Json) => event.kind)).toEqual(['posted', 'cancelled']);
    expect(codeOf(await call('post', `/admin/purchase-invoices/${id}/cancel`).send({ reason: 'de novo' }).expect(409))).toBe('FA764');
    expect(codeOf(await call('post', `/admin/purchase-invoices/${randomUUID()}/cancel`).send({ reason: 'x' }).expect(404))).toBe('FA006');
  });

  it('identificadores e filtros inválidos', async () => {
    await call('get', '/admin/purchase-invoices?status=x').expect(422);
    await call('get', '/admin/purchase-invoices?status=posted').expect(200);
    await call('get', '/admin/purchase-invoices?branch=x').expect(422);
    expect(codeOf(await call('get', `/admin/purchase-invoices/${randomUUID()}`).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', `/admin/purchase-invoice-items/${randomUUID()}/link`).send({ productId: DIPIRONA }).expect(404))).toBe('FA006');
  });
});
