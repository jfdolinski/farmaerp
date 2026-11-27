// NF-e de devolução ao fornecedor emitida pela central, contra o banco real e uma Sefaz falsa (TLS
// local). A nota é montada e assinada com o motor do PDV compilado para JavaScript. Nada sai para a
// Sefaz de verdade.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { createServer, Server } from 'node:https';
import { AddressInfo } from 'node:net';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { localhostCertificate } from './fake-tls.js';
import { buildPfx } from './fiscal-pfx.js';
import { buildNfe, testGtin } from './nfe-fixture.js';

const ADMIN = 'admin@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const PASSWORD = 'farmaerp-dev-123';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const CENTRO_CNPJ = '11222333000181';
const COMPANY = '019a0000-0000-7000-8000-000000000002';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';
const PFX_PASSWORD = 'senha-do-pfx-da-devolucao';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const soap = (inner: string) =>
  `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeResultMsg>${inner}</nfeResultMsg></soap:Body></soap:Envelope>`;
const keyOf = (body: string) => /Id="NFe(\d{44})"/.exec(body)?.[1] ?? '';

describe('NF-e de devolução emitida pela central', () => {
  let app: INestApplication<App>;
  let sefaz: Server;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const received: string[] = [];
  // Próxima resposta da Sefaz falsa: 'down' (erro 500), 'reject' ou autoriza.
  const plan: string[] = [];

  const admin = (method: 'get' | 'post' | 'patch', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  beforeAll(async () => {
    const tls = localhostCertificate();
    sefaz = createServer({ key: tls.key, cert: tls.cert, requestCert: true, rejectUnauthorized: false }, (req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (chunk: Buffer) => chunks.push(chunk));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        received.push(body);
        const next = plan.shift();
        if (next === 'down') {
          res.writeHead(500);
          res.end();
          return;
        }
        const key = keyOf(body);
        const answer = next === 'reject'
          ? '<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo><protNFe versao="4.00"><infProt><cStat>539</cStat><xMotivo>Rejeicao: Duplicidade de NF-e com diferenca na Chave de Acesso</xMotivo></infProt></protNFe></retEnviNFe>'
          : `<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo><protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><chNFe>${key}</chNFe>`
            + '<dhRecbto>2026-11-27T16:00:05-03:00</dhRecbto><nProt>135260000000777</nProt><cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe></retEnviNFe>';
        res.writeHead(200, { 'Content-Type': 'application/soap+xml; charset=utf-8' });
        res.end(soap(answer));
      });
    });
    await new Promise<void>((resolve) => sefaz.listen(0, '127.0.0.1', resolve));
    process.env.SEFAZ_NFE_URL = `https://localhost:${(sefaz.address() as AddressInfo).port}`;
    process.env.SEFAZ_TEST_CA = tls.cert;
    process.env.FISCAL_WORKER = 'off';
    process.env.PURCHASE_CONTENT_WORKER = 'off';

    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() })))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, OPERATOR]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
    await admin('post', `/fiscal/branches/${CENTRO}/certificate`)
      .send({ file: buildPfx({ password: PFX_PASSWORD }).toString('base64'), password: PFX_PASSWORD }).expect(201);
  });

  it('filial sem os dados fiscais completos não emite', async () => {
    const { returnId } = await returned();
    expect(codeOf(await admin('post', `/purchase-returns/${returnId}/nfe`).expect(422))).toBe('FA724');
    // Completa a filial do seed (endereço, inscrição e regime) para os próximos testes.
    const overview = (await admin('get', '/structure').expect(200)).body as Json;
    const branch = (overview.branches as Json[]).find((row) => row.id === CENTRO)!;
    await admin('patch', `/structure/branches/${CENTRO}`).send({
      name: branch.name, cnpj: CENTRO_CNPJ, state: 'SP', postalCode: '01001000', street: 'Rua das Flores', streetNumber: '100',
      district: 'Centro', city: 'São Paulo', cityCode: '3550308', phone: '1133334444',
    }).expect(200);
    await admin('patch', `/fiscal/branches/${CENTRO}/state-registration`).send({ stateRegistration: '110042490114' }).expect(200);
    await admin('patch', `/fiscal/companies/${COMPANY}/regime`).send({ regime: 1 }).expect(200);
  });

  afterAll(async () => {
    await app.close();
    await new Promise((resolve) => sefaz.close(resolve));
    delete process.env.SEFAZ_NFE_URL;
    delete process.env.SEFAZ_TEST_CA;
    delete process.env.FISCAL_WORKER;
    delete process.env.PURCHASE_CONTENT_WORKER;
  });

  /** Nota de compra lançada e uma devolução de 1 unidade. Devolve os ids. */
  async function returned() {
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, items: [{ code: `P-${randomInt(1e9)}`, ean: testGtin(), quantity: '4.0000', value: '40.00', description: 'ITEM DEVOLVIDO' }] });
    const id = ((await admin('post', '/purchase-invoices').set('Content-Type', 'application/xml').send(nfe.xml).expect(201)).body as Json).id as string;
    const [item] = ((await admin('get', `/purchase-invoices/${id}`).expect(200)).body as Json).items as Json[];
    await admin('post', `/purchase-invoice-items/${item.id}/duplicate`).send({ sourceProductId: DIPIRONA }).expect(201);
    await admin('post', `/purchase-invoices/${id}/post`).expect(200);
    const returnId = ((await admin('post', `/purchase-invoices/${id}/returns`).send({ items: [{ itemId: item.id, quantity: 1 }], reason: 'Avaria' }).expect(201)).body as Json).id as string;
    return { invoiceId: id, returnId, purchaseKey: nfe.key };
  }

  it('emite, transmite e autoriza; o DANFE e o XML ficam para baixar; não emite de novo', async () => {
    const { invoiceId, returnId, purchaseKey } = await returned();
    expect(codeOf(await admin('post', `/purchase-returns/${returnId}/nfe`, OPERATOR).expect(403))).toBe('FA002');
    const emitted = (await admin('post', `/purchase-returns/${returnId}/nfe`).expect(200)).body as Json;
    expect(emitted).toMatchObject({ id: expect.any(String), status: 'authorized' });
    // O que foi à Sefaz: a NF-e 55 de devolução, assinada, referenciando a nota de compra.
    const sent = received.at(-1)!;
    expect(sent).toContain('<mod>55</mod>');
    expect(sent).toContain('<finNFe>4</finNFe>');
    expect(sent).toContain(`<refNFe>${purchaseKey}</refNFe>`);
    expect(sent).toContain('<Signature xmlns="http://www.w3.org/2000/09/xmldsig#">');

    const detail = (await admin('get', `/purchase-invoices/${invoiceId}`).expect(200)).body as Json;
    expect(detail.return_nfes).toEqual([expect.objectContaining({ id: emitted.id, return_id: returnId, status: 'authorized', protocol: '135260000000777' })]);
    expect(detail.can_issue_nfe).toBe(true);

    const xml = await admin('get', `/central-nfe/${emitted.id}/xml`).expect(200);
    expect(xml.headers['content-type']).toContain('application/xml');
    expect(xml.text).toContain('<nfeProc');
    expect(xml.text).toContain('<nProt>135260000000777</nProt>');
    const danfe = await admin('get', `/central-nfe/${emitted.id}/danfe`).buffer(true).parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => done(null, Buffer.concat(chunks)));
    }).expect(200);
    expect(danfe.headers['content-type']).toContain('application/pdf');
    expect((danfe.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');

    expect(codeOf(await admin('post', `/purchase-returns/${returnId}/nfe`).expect(409))).toBe('FA773');
  });

  it('sem resposta da Sefaz fica pendente e a próxima tentativa transmite o mesmo XML; recusada pode ser emitida de novo', async () => {
    const { returnId } = await returned();
    plan.push('down');
    const pending = (await admin('post', `/purchase-returns/${returnId}/nfe`).expect(200)).body as Json;
    expect(pending.status).toBe('pending');
    const firstXml = received.at(-1)!;
    const again = (await admin('post', `/purchase-returns/${returnId}/nfe`).expect(200)).body as Json;
    expect(again).toEqual({ id: pending.id, status: 'authorized' });
    expect(keyOf(received.at(-1)!)).toBe(keyOf(firstXml));

    const second = await returned();
    plan.push('reject');
    const rejected = (await admin('post', `/purchase-returns/${second.returnId}/nfe`).expect(200)).body as Json;
    expect(rejected.status).toBe('rejected');
    const rejectedKey = keyOf(received.at(-1)!);
    const reissued = (await admin('post', `/purchase-returns/${second.returnId}/nfe`).expect(200)).body as Json;
    expect(reissued.status).toBe('authorized');
    expect(reissued.id).not.toBe(rejected.id);
    expect(keyOf(received.at(-1)!)).not.toBe(rejectedKey);
  });
});
