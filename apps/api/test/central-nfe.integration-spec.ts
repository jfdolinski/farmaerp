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
/** Hora atual no formato da Sefaz (a nota autorizada agora pode ser cancelada nas 24 horas). */
const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00');
const keyOf = (body: string) => /Id="NFe(\d{44})"/.exec(body)?.[1] ?? '';

describe('NF-e de devolução emitida pela central', () => {
  let app: INestApplication<App>;
  let sefaz: Server;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const received: string[] = [];
  const paths: string[] = [];
  // Próxima resposta da Sefaz falsa: 'down' (erro 500), 'stopped' (108, serviço parado), 'reject' ou autoriza.
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
        paths.push(req.url ?? '');
        const next = plan.shift();
        if (next === 'stopped') {
          res.writeHead(200, { 'Content-Type': 'application/soap+xml; charset=utf-8' });
          res.end(soap('<retEnviNFe><cStat>108</cStat><xMotivo>Servico Paralisado Momentaneamente</xMotivo></retEnviNFe>'));
          return;
        }
        if (next === 'down') {
          res.writeHead(500);
          res.end();
          return;
        }
        const key = keyOf(body);
        if ((req.url ?? '').endsWith('/event')) {
          res.writeHead(200, { 'Content-Type': 'application/soap+xml; charset=utf-8' });
          res.end(soap('<retEnvEvento versao="1.00"><cStat>128</cStat><xMotivo>Lote processado</xMotivo><retEvento versao="1.00"><infEvento>'
            + `<cStat>135</cStat><xMotivo>Evento registrado</xMotivo><nProt>135260000000904</nProt><dhRegEvento>${now()}</dhRegEvento>`
            + '</infEvento></retEvento></retEnvEvento>'));
          return;
        }
        const answer = next === 'reject'
          ? '<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo><protNFe versao="4.00"><infProt><cStat>539</cStat><xMotivo>Rejeicao: Duplicidade de NF-e com diferenca na Chave de Acesso</xMotivo></infProt></protNFe></retEnviNFe>'
          : `<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo><protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><chNFe>${key}</chNFe>`
            + `<dhRecbto>${now()}</dhRecbto><nProt>135260000000777</nProt>`
            + '<cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe></retEnviNFe>';
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

  it('cancela a NF-e da devolução no evento da NF-e: só a nota; a devolução aceita NF-e nova', async () => {
    const { invoiceId, returnId } = await returned();
    const emitted = (await admin('post', `/purchase-returns/${returnId}/nfe`).expect(200)).body as Json;
    expect(emitted.status).toBe('authorized');
    let detail = (await admin('get', `/purchase-invoices/${invoiceId}`).expect(200)).body as Json;
    expect((detail.return_nfes as Json[])[0].cancelable_until).toEqual(expect.any(String));
    // Motivo curto e quem não emite: recusados antes da Sefaz.
    const before = paths.length;
    expect(codeOf(await admin('post', `/central-nfe/${emitted.id}/cancel`).send({ reason: 'curto' }).expect(422))).toBe('FA005');
    expect(codeOf(await admin('post', `/central-nfe/${emitted.id}/cancel`, OPERATOR).send({ reason: 'Valores da devolução errados' }).expect(403))).toBe('FA002');
    expect(paths.length).toBe(before);

    const canceled = (await admin('post', `/central-nfe/${emitted.id}/cancel`).send({ reason: 'Valores da devolução errados' }).expect(200)).body as Json;
    expect(canceled).toEqual({ status: 'canceled', sefaz: '135 Evento registrado' });
    expect(paths.at(-1)).toBe('/event');
    const event = received.at(-1)!;
    expect(event).toContain('<tpEvento>110111</tpEvento>');
    expect(event).toMatch(/<chNFe>\d{44}<\/chNFe>/);
    expect(event).toContain('<nProt>135260000000777</nProt>');
    expect(event).toContain('<xJust>Valores da devolução errados</xJust>');
    // Repetido: já está feito, sem ir à Sefaz.
    const again = paths.length;
    expect((await admin('post', `/central-nfe/${emitted.id}/cancel`).send({ reason: 'Valores da devolução errados' }).expect(200)).body)
      .toEqual({ status: 'canceled', already: true });
    expect(paths.length).toBe(again);

    detail = (await admin('get', `/purchase-invoices/${invoiceId}`).expect(200)).body as Json;
    expect((detail.return_nfes as Json[])[0]).toMatchObject({ id: emitted.id, status: 'canceled', cancel_reason: 'Valores da devolução errados', cancelable_until: null });
    const file = await admin('get', `/central-nfe/${emitted.id}/xml?kind=cancel`).expect(200);
    expect(file.headers['content-disposition']).toContain('Cancelamento-NFe-');
    expect(file.text).toContain('<procEventoNFe');
    // A devolução continua e ganha NF-e nova, com outro número.
    const second = (await admin('post', `/purchase-returns/${returnId}/nfe`).expect(200)).body as Json;
    expect(second).toMatchObject({ status: 'authorized' });
    expect(second.id).not.toBe(emitted.id);
    expect(codeOf(await admin('get', `/central-nfe/${second.id}/xml?kind=cancel`).expect(404))).toBe('FA006');
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

  it('Sefaz da UF parada: a mesma nota vai para a SVC-AN (tpEmis 6), com outra chave, e sai autorizada', async () => {
    const { returnId } = await returned();
    plan.push('stopped');
    const before = paths.length;
    const emitted = (await admin('post', `/purchase-returns/${returnId}/nfe`).expect(200)).body as Json;
    expect(emitted.status).toBe('authorized');
    expect(paths.slice(before)).toEqual(['/authorization', '/svc-authorization']);
    const [normal, svc] = received.slice(-2);
    expect(normal).toContain('<tpEmis>1</tpEmis>');
    expect(svc).toContain('<tpEmis>6</tpEmis>');
    expect(svc).toContain('<xJust>Sefaz da UF sem comunicacao no momento da emissao</xJust>');
    expect(keyOf(svc).substring(34, 35)).toBe('6');
    expect(keyOf(svc).substring(25, 34)).toBe(keyOf(normal).substring(25, 34));
    const xml = await admin('get', `/central-nfe/${emitted.id}/xml`).expect(200);
    expect(xml.text).toContain(`Id="NFe${keyOf(svc)}"`);
  });

  it('transferência entre filiais: emite a NF-e da origem, aparece nas movimentações e não emite de novo', async () => {
    const SUL = '019a0000-0000-7000-8000-000000000006';
    // Destino com os dados fiscais (mesma empresa do seed).
    const overview = (await admin('get', '/structure').expect(200)).body as Json;
    const sul = (overview.branches as Json[]).find((row) => row.id === SUL)!;
    await admin('patch', `/structure/branches/${SUL}`).send({
      name: sul.name, cnpj: sul.cnpj, state: 'SP', postalCode: '01310100', street: 'Avenida Paulista', streetNumber: '900',
      district: 'Bela Vista', city: 'São Paulo', cityCode: '3550308',
    }).expect(200);
    await admin('patch', `/fiscal/branches/${SUL}/state-registration`).send({ stateRegistration: '110042490114' }).expect(200);

    // Produto do Catálogo (traz o NCM) com custo médio na origem: nota de compra lançada.
    const [catalogItem] = (await admin('get', '/catalog?q=7890000000062').expect(200)).body as Json[];
    const barcode = testGtin();
    const productId = ((await admin('post', '/products').send({ displayName: 'Protetor transferência', barcode, catalogProductId: catalogItem.id }).expect(201)).body as Json).id as string;
    const nfe = buildNfe({ destCnpj: CENTRO_CNPJ, items: [{ code: `T-${randomInt(1e9)}`, ean: testGtin(), quantity: '4.0000', value: '48.00', description: 'PROTETOR' }] });
    const invoiceId = ((await admin('post', '/purchase-invoices').set('Content-Type', 'application/xml').send(nfe.xml).expect(201)).body as Json).id as string;
    const [item] = ((await admin('get', `/purchase-invoices/${invoiceId}`).expect(200)).body as Json).items as Json[];
    await admin('post', `/purchase-invoice-items/${item.id}/link`).send({ productId }).expect(200);
    await admin('post', `/purchase-invoices/${invoiceId}/post`).expect(200);

    const transferId = ((await admin('post', '/stock/transfers').send({
      productLookup: barcode, fromBranchId: CENTRO, toBranchId: SUL, quantity: 2, reason: 'Reposição',
    }).expect(201)).body as Json).id as string;
    expect(codeOf(await admin('post', `/stock-transfers/${transferId}/nfe`, OPERATOR).expect(403))).toBe('FA002');
    const emittedResponse = await admin('post', `/stock-transfers/${transferId}/nfe`);
    expect(emittedResponse.body).toMatchObject({ status: 'authorized' });
    const emitted = emittedResponse.body as Json;
    expect(emitted.status).toBe('authorized');
    const sent = received.at(-1)!;
    expect(sent).toContain('<CFOP>5152</CFOP>');
    expect(sent).toContain('TRANSFERENCIA DE MERCADORIA');

    const movements = (await admin('get', `/stock/movements?branch=${CENTRO}`).expect(200)).body as Json[];
    const out = movements.find((row) => row.transfer?.id === transferId);
    expect(out).toMatchObject({ quantity: '-2.000', transfer: { can_issue_nfe: true, nfe: { id: emitted.id, status: 'authorized' } } });
    await admin('get', `/central-nfe/${emitted.id as string}/xml`).expect(200);
    expect(codeOf(await admin('post', `/stock-transfers/${transferId}/nfe`).expect(409))).toBe('FA776');
  });

  it('padrões fiscais da devolução: lista, altera, recusa valor fora da lista e volta ao padrão', async () => {
    const SUL = '019a0000-0000-7000-8000-000000000006';
    const rows = (await admin('get', '/fiscal/return-tax').expect(200)).body as Json[];
    expect(rows.map((row) => row.branch_id)).toEqual(expect.arrayContaining([CENTRO, SUL]));
    expect(rows.find((row) => row.branch_id === SUL)).toMatchObject({ can_manage: true, settings: { cfop_internal: '5202', pis_cst: '49' } });

    const changed = (await admin('patch', `/fiscal/return-tax/${SUL}`).send({ pis_cst: '99', cofins_cst: '99' }).expect(200)).body as Json;
    expect(changed).toMatchObject({ pis_cst: '99', cofins_cst: '99', cfop_internal: '5202' });
    expect(((await admin('get', '/fiscal/return-tax').expect(200)).body as Json[]).find((row) => row.branch_id === SUL)).toMatchObject({ customized: true });

    expect(codeOf(await admin('patch', `/fiscal/return-tax/${SUL}`).send({ cfop_internal: '6202' }).expect(422))).toBe('FA775');
    expect(codeOf(await admin('patch', `/fiscal/return-tax/${SUL}`, OPERATOR).send({ pis_cst: '49' }).expect(403))).toBe('FA002');
    expect(codeOf(await admin('patch', '/fiscal/return-tax/nao-e-uuid').send({}).expect(422))).toBe('FA005');

    expect((await admin('post', `/fiscal/return-tax/${SUL}/reset`).expect(200)).body).toMatchObject({ pis_cst: '49', cofins_cst: '49' });
    expect(((await admin('get', '/fiscal/return-tax').expect(200)).body as Json[]).find((row) => row.branch_id === SUL)).toMatchObject({ customized: false });
  });
});
