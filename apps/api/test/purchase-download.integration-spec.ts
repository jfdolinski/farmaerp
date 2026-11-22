// Download automático e ciência contra o banco real e um servidor falso da Sefaz (HTTPS com
// certificado de cliente). Nenhum teste fala com a Sefaz de verdade.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { generateKeyPairSync, randomInt } from 'node:crypto';
import { createServer, Server } from 'node:https';
import { AddressInfo } from 'node:net';
import { TLSSocket } from 'node:tls';
import { gzipSync } from 'node:zlib';
import forge from 'node-forge';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DfeService } from './../src/sefaz/dfe.service.js';
import { buildPfx } from './fiscal-pfx.js';
import { buildNfe, testCnpj } from './nfe-fixture.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const CENTRO_CNPJ = '11222333000181';
const PFX_PASSWORD = 'senha-do-pfx-do-download';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** Certificado do servidor falso, para localhost; o próprio certificado serve de certificadora. */
function serverCertificate() {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  const cert = forge.pki.createCertificate();
  cert.publicKey = forge.pki.publicKeyFromPem(publicKey);
  cert.serialNumber = '05';
  cert.validity.notBefore = new Date(Date.now() - 86_400_000);
  cert.validity.notAfter = new Date(Date.now() + 86_400_000);
  const attrs = [{ name: 'commonName', value: 'localhost' }];
  cert.setSubject(attrs);
  cert.setIssuer(attrs);
  cert.setExtensions([
    { name: 'basicConstraints', cA: true },
    { name: 'subjectAltName', altNames: [{ type: 2, value: 'localhost' }, { type: 7, ip: '127.0.0.1' }] },
  ]);
  cert.sign(forge.pki.privateKeyFromPem(privateKey), forge.md.sha256.create());
  return { key: privateKey, cert: forge.pki.certificateToPem(cert) };
}

const zip = (xml: string) => gzipSync(Buffer.from(xml, 'utf8')).toString('base64');
const digestOf = (xml: string) => /<DigestValue>([^<]+)<\/DigestValue>/.exec(xml)?.[1] ?? '';
const nsu = (value: number) => String(value).padStart(15, '0');
const summaryOf = (nfe: { key: string; xml: string; emitterCnpj: string }, situation = 1) =>
  `<resNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><chNFe>${nfe.key}</chNFe><CNPJ>${nfe.emitterCnpj}</CNPJ>` +
  `<xNome>DISTRIBUIDORA BAIXADA LTDA</xNome><IE>110042490114</IE><dhEmi>2026-11-20T10:00:00-03:00</dhEmi><tpNF>1</tpNF>` +
  `<vNF>21.00</vNF><digVal>${digestOf(nfe.xml)}</digVal><dhRecbto>2026-11-20T10:00:05-03:00</dhRecbto>` +
  `<nProt>135260000000001</nProt><cSitNFe>${situation}</cSitNFe></resNFe>`;
const cancellation = (key: string) =>
  `<resEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><cOrgao>35</cOrgao><CNPJ>11444777000161</CNPJ><chNFe>${key}</chNFe>` +
  `<dhEvento>2026-11-21T10:00:00-03:00</dhEvento><tpEvento>110111</tpEvento><nSeqEvento>1</nSeqEvento><xEvento>Cancelamento</xEvento>` +
  `<dhRecbto>2026-11-21T10:00:01-03:00</dhRecbto><nProt>135260000000009</nProt></resEvento>`;
const distribution = (status: string, last: number, max: number, docs: [number, string, string][] = []) =>
  `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeDistDFeInteresseResponse xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe">` +
  `<nfeDistDFeInteresseResult><retDistDFeInt xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.01"><tpAmb>2</tpAmb><cStat>${status}</cStat>` +
  `<xMotivo>${status === '137' ? 'Nenhum documento localizado' : 'Documento localizado'}</xMotivo><ultNSU>${nsu(last)}</ultNSU><maxNSU>${nsu(max)}</maxNSU>` +
  (docs.length ? `<loteDistDFeInt>${docs.map(([n, schema, xml]) => `<docZip NSU="${nsu(n)}" schema="${schema}">${zip(xml)}</docZip>`).join('')}</loteDistDFeInt>` : '') +
  `</retDistDFeInt></nfeDistDFeInteresseResult></nfeDistDFeInteresseResponse></soap:Body></soap:Envelope>`;
const eventResponse = (status: string, motive: string) =>
  `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeResultMsg xmlns="http://www.portalfiscal.inf.br/nfe/wsdl/NFeRecepcaoEvento4">` +
  `<retEnvEvento xmlns="http://www.portalfiscal.inf.br/nfe" versao="1.00"><cStat>128</cStat><retEvento versao="1.00"><infEvento>` +
  `<cStat>${status}</cStat><xMotivo>${motive}</xMotivo><nProt>891260000000001</nProt></infEvento></retEvento></retEnvEvento></nfeResultMsg></soap:Body></soap:Envelope>`;

describe('download automático contra o banco real e a Sefaz falsa', () => {
  let app: INestApplication<App>;
  let sefaz: Server;
  const sessions = new Map<string, string>();
  const received: { path: string; body: string; clientCertificate: boolean }[] = [];
  /** Resposta da Sefaz falsa para cada pedido; muda conforme o teste. */
  let respond: (path: string, body: string) => { status: number; body: string } = () => ({ status: 500, body: '' });

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', newIp()).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const importXml = (xml: string) =>
    call('post', '/admin/purchase-invoices').set('Content-Type', 'application/xml').send(xml).expect(201).then((r) => (r.body as Json).id as string);
  const invoice = (id: string) => call('get', `/admin/purchase-invoices/${id}`).expect(200).then((r) => r.body as Json);
  const status = () => call('get', '/admin/dfe/status').expect(200).then((r) => (r.body as Json[]).find((row) => row.branch_id === CENTRO) as Json);

  // Notas do teste: A chega como resumo e pede ciência; B chega completa; C foi importada à mão e
  // é cancelada; D foi importada à mão e é confirmada pela consulta da chave.
  const noteA = buildNfe({ destCnpj: CENTRO_CNPJ, emitterCnpj: testCnpj(), items: [{ code: `A-${randomInt(1e9)}` }] });
  const noteB = buildNfe({ destCnpj: CENTRO_CNPJ, emitterCnpj: testCnpj(), items: [{ code: `B-${randomInt(1e9)}` }] });
  const noteC = buildNfe({ destCnpj: CENTRO_CNPJ, emitterCnpj: testCnpj(), items: [{ code: `C-${randomInt(1e9)}` }] });
  const noteD = buildNfe({ destCnpj: CENTRO_CNPJ, emitterCnpj: testCnpj(), items: [{ code: `D-${randomInt(1e9)}` }] });
  let invoiceC: string;
  let invoiceD: string;

  beforeAll(async () => {
    const tls = serverCertificate();
    sefaz = createServer({ key: tls.key, cert: tls.cert, requestCert: true, rejectUnauthorized: false }, (req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (chunk: Buffer) => chunks.push(chunk));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        const clientCertificate = Object.keys((req.socket as TLSSocket).getPeerCertificate()).length > 0;
        received.push({ path: req.url ?? '', body, clientCertificate });
        const answer = clientCertificate ? respond(req.url ?? '', body) : { status: 403, body: '' };
        res.writeHead(answer.status, { 'Content-Type': 'application/soap+xml; charset=utf-8' });
        res.end(answer.body);
      });
    });
    await new Promise<void>((resolve) => sefaz.listen(0, '127.0.0.1', resolve));
    const { port } = sefaz.address() as AddressInfo;
    process.env.SEFAZ_DIST_URL = `https://localhost:${port}/dist`;
    process.env.SEFAZ_EVENT_URL = `https://localhost:${port}/event`;
    process.env.SEFAZ_TEST_CA = tls.cert;

    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] }).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, OPERATOR]) {
      const response = await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', newIp())
        .send({ email, password: PASSWORD }).expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
    await call('post', `/admin/fiscal/branches/${CENTRO}/certificate`)
      .send({ file: buildPfx({ password: PFX_PASSWORD }).toString('base64'), password: PFX_PASSWORD }).expect(201);
    invoiceC = await importXml(noteC.xml);
    invoiceD = await importXml(noteD.xml);
  });

  afterAll(async () => {
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: false });
    await app.close();
    await new Promise((resolve) => sefaz.close(resolve));
    delete process.env.SEFAZ_DIST_URL;
    delete process.env.SEFAZ_EVENT_URL;
    delete process.env.SEFAZ_TEST_CA;
  });

  it('só quem cuida do fiscal liga o download', async () => {
    expect(codeOf(await call('post', `/admin/branches/${CENTRO}/dfe`, OPERATOR).send({ enabled: true }).expect(403))).toBe('FA002');
    expect(codeOf(await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: 'sim' }).expect(422))).toBe('FA005');
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: true }).expect(200);
    expect(await status()).toMatchObject({ enabled: true, has_certificate: true, last_run_at: null });
  });

  it('baixa por NSU, página por página, e espera a hora pedida pela Sefaz', async () => {
    respond = (path, body) => {
      if (body.includes('<ultNSU>000000000000000</ultNSU>')) {
        return { status: 200, body: distribution('138', 2, 3, [[1, 'resNFe_v1.01', summaryOf(noteA)], [2, 'procNFe_v4.00', noteB.xml]]) };
      }
      if (body.includes('<ultNSU>000000000000002</ultNSU>')) {
        return { status: 200, body: distribution('138', 3, 3, [[3, 'resEvento_v1.01', cancellation(noteC.key)]]) };
      }
      return { status: 200, body: distribution('137', 3, 3) };
    };
    received.length = 0;
    const dfe = app.get(DfeService);
    await dfe.syncBranches();
    const pages = received.filter((r) => r.path === '/dist');
    expect(pages).toHaveLength(2);
    expect(pages.every((r) => r.clientCertificate)).toBe(true);
    expect(pages[0].body).toContain(`<tpAmb>2</tpAmb><cUFAutor>35</cUFAutor><CNPJ>${CENTRO_CNPJ}</CNPJ>`);

    const summaries = (await call('get', '/admin/purchase-summaries').expect(200)).body as Json[];
    expect(summaries.find((s) => s.access_key === noteA.key)).toMatchObject({ emitter_name: 'DISTRIBUIDORA BAIXADA LTDA', total: '21.00', awareness_at: null, can_manage: true });
    const list = (await call('get', '/admin/purchase-invoices').expect(200)).body as Json[];
    expect(list.find((row) => row.access_key === noteB.key)).toMatchObject({ source: 'download', confirmation: 'confirmed', status: 'review' });
    expect(await invoice(invoiceC)).toMatchObject({ status: 'cancelled' });
    expect(await status()).toMatchObject({ last_status: '138', last_error: null });

    // Ainda não deu a hora: a rodada seguinte não chama a Sefaz.
    received.length = 0;
    await dfe.syncBranches();
    expect(received).toEqual([]);
  });

  it('a ciência sai assinada; a consulta pela chave traz o XML e confirma a importada à mão', async () => {
    const summary = ((await call('get', '/admin/purchase-summaries').expect(200)).body as Json[]).find((s) => s.access_key === noteA.key) as Json;
    expect(codeOf(await call('post', `/admin/purchase-summaries/${summary.id as string}/awareness`, OPERATOR).expect(403))).toBe('FA002');

    respond = (path) => (path === '/event' ? { status: 200, body: eventResponse('650', 'Evento para NF-e cancelada') } : { status: 500, body: '' });
    expect(codeOf(await call('post', `/admin/purchase-summaries/${summary.id as string}/awareness`).expect(422))).toBe('FA945');
    respond = () => ({ status: 500, body: 'erro' });
    expect(codeOf(await call('post', `/admin/purchase-summaries/${summary.id as string}/awareness`).expect(503))).toBe('FA944');

    received.length = 0;
    respond = (path) => (path === '/event' ? { status: 200, body: eventResponse('135', 'Evento registrado e vinculado a NF-e') } : { status: 500, body: '' });
    expect((await call('post', `/admin/purchase-summaries/${summary.id as string}/awareness`).expect(200)).body).toEqual({ protocol: '891260000000001' });
    expect(received[0].body).toContain(`<infEvento Id="ID210210${noteA.key}01"><cOrgao>91</cOrgao><tpAmb>2</tpAmb><CNPJ>${CENTRO_CNPJ}</CNPJ>`);
    expect(received[0].body).toContain('<SignatureValue>');
    expect(codeOf(await call('post', `/admin/purchase-summaries/${summary.id as string}/awareness`).expect(409))).toBe('FA946');

    respond = (_path, body) => {
      if (body.includes(`<chNFe>${noteA.key}</chNFe>`)) return { status: 200, body: distribution('138', 0, 0, [[10, 'procNFe_v4.00', noteA.xml]]) };
      if (body.includes(`<chNFe>${noteD.key}</chNFe>`)) return { status: 200, body: distribution('138', 0, 0, [[11, 'resNFe_v1.01', summaryOf(noteD)]]) };
      return { status: 200, body: distribution('137', 0, 0) };
    };
    received.length = 0;
    await app.get(DfeService).runQueries();
    // Outras notas pendentes da filial, de outros testes, também são consultadas.
    expect(received.map((r) => /<chNFe>([0-9]{44})<\/chNFe>/.exec(r.body)?.[1])).toEqual(expect.arrayContaining([noteA.key, noteD.key]));
    const list = (await call('get', '/admin/purchase-invoices').expect(200)).body as Json[];
    expect(list.find((row) => row.access_key === noteA.key)).toMatchObject({ source: 'download', confirmation: 'confirmed' });
    expect(await invoice(invoiceD)).toMatchObject({ confirmation: 'confirmed', source: 'manual' });
    expect(((await call('get', '/admin/purchase-summaries').expect(200)).body as Json[]).some((s) => s.access_key === noteA.key)).toBe(false);
  });

  it('Sefaz fora do ar fica registrada como erro, sem derrubar a rodada', async () => {
    // Desligar e ligar põe a filial de volta na fila na hora.
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: false }).expect(200);
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: true }).expect(200);
    respond = () => ({ status: 500, body: 'fora do ar' });
    await app.get(DfeService).tick();
    expect(await status()).toMatchObject({ last_error: 'FA944' });
  });
});
