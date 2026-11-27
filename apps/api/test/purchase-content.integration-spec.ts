// Parte E1: dados completos do XML, duplicatas e auditoria da nota de compra, contra o banco real.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { createHash, randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DatabaseService } from './../src/database.service.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { readAuthorizedNfe } from './../src/purchases/nfe-xml.js';
import { PurchaseContentService } from './../src/purchases/purchase-content.service.js';
import { buildNfe } from './nfe-fixture.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const ADMIN_ID = '019a0000-0000-7000-8000-000000000008';
const CENTRO_CNPJ = '11222333000181';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const BILLING =
  '<cobr><fat><nFat>77</nFat><vOrig>21.00</vOrig><vLiq>21.00</vLiq></fat>' +
  '<dup><nDup>001</nDup><dVenc>2026-12-20</dVenc><vDup>10.50</vDup></dup>' +
  '<dup><nDup>002</nDup><dVenc>2027-01-20</dVenc><vDup>10.50</vDup></dup></cobr>';
const withBilling = (xml: string) => xml.replace('</total>', `</total>${BILLING}<infAdic><infCpl>PEDIDO 991</infCpl></infAdic>`);

describe('dados completos da nota de compra contra o banco real', () => {
  let app: INestApplication<App>;
  let token = '';
  const previous = { ...process.env };
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post', path: string) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
  const detailOf = async (id: string) => (await call('get', `/admin/purchase-invoices/${id}`).expect(200)).body as Json;

  /** Nota gravada direto no banco, como as recebidas antes desta versão: sem os dados completos. */
  const importWithoutContent = async (xml: string, data: Json) =>
    app.get(DatabaseService).withContext(
      async (client) =>
        (await client.query<{ id: string }>('SELECT app.import_purchase_invoice($1::jsonb, $2, $3, true) AS id', [
          JSON.stringify(data), xml, createHash('sha256').update(xml).digest('hex'),
        ])).rows[0].id,
      { userId: ADMIN_ID },
    );

  beforeAll(async () => {
    process.env.PURCHASE_CONTENT_WORKER = 'off';
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() })))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    token = ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
      .send({ email: ADMIN, password: PASSWORD }).expect(200)).body as Json).token as string;
  });

  afterAll(async () => {
    await app.close();
    process.env = previous;
  });

  it('a importação já grava os dados completos e as duplicatas; o detalhe mostra a auditoria', async () => {
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, items: [{ code: `E1-${randomInt(1e9)}` }], beforeSign: withBilling });
    const id = ((await call('post', '/admin/purchase-invoices').set('Content-Type', 'application/xml').send(nfe.xml).expect(201)).body as Json).id as string;
    const detail = await detailOf(id);
    expect(detail.content).toMatchObject({ ide: { natOp: 'VENDA', mod: '55' }, infAdic: { infCpl: 'PEDIDO 991' }, cobr: { fat: { nFat: '77' } } });
    expect(detail.content_read_at).not.toBeNull();
    expect(detail.content_error).toBeNull();
    expect(detail.installments).toEqual([
      { line: 1, number: '001', due_date: '2026-12-20', amount: 10.5 },
      { line: 2, number: '002', due_date: '2027-01-20', amount: 10.5 },
    ]);
    expect(detail.audit).toEqual([]);

    await call('post', `/admin/purchase-invoice-items/${(detail.items as Json[])[0].id}/link`).send({ productId: DIPIRONA }).expect(200);
    const after = await detailOf(id);
    expect(after.audit).toHaveLength(1);
    expect(after.audit[0]).toMatchObject({ kind: 'linked', user_name: 'Administrador', detail: { item_number: 1, source: 'manual', product_id: DIPIRONA } });
  });

  it('a rotina lê as notas guardadas sem os dados; XML que não se lê fica marcado e sai da fila', async () => {
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, beforeSign: withBilling });
    const { detail: _detail, ...data } = readAuthorizedNfe(nfe.xml);
    const old = await importWithoutContent(nfe.xml, data);
    const broken = buildNfe({ destCnpj: CENTRO_CNPJ });
    const { detail: _ignored, ...brokenData } = readAuthorizedNfe(broken.xml);
    const unreadable = await importWithoutContent(broken.xml.replace('<nProt>', '<nProt>9'), brokenData);

    const before = await detailOf(old);
    expect(before.content).toBeNull();
    expect(before.installments).toEqual([]);

    // Outras notas do banco de testes podem estar na fila: confere só as duas desta nota.
    const service = app.get(PurchaseContentService);
    expect(await service.tick()).not.toBeNull();

    const read = await detailOf(old);
    expect(read.content).toMatchObject({ infAdic: { infCpl: 'PEDIDO 991' } });
    expect(read.installments).toHaveLength(2);
    const failed = await detailOf(unreadable);
    expect(failed.content).toBeNull();
    expect(failed.content_error).toMatch(/^XML não lido: /);

    // Na rodada seguinte, nenhuma das duas muda (nem volta para a fila).
    await service.tick();
    expect(await detailOf(old)).toMatchObject({ content_read_at: read.content_read_at, installments: read.installments });
    expect((await detailOf(unreadable)).content_error).toBe(failed.content_error);
  });
});
