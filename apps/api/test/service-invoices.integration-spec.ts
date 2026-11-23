// NFS-e pelo Ambiente de Dados Nacional contra o banco real e um ADN falso (HTTPS com certificado
// de cliente). Nenhum teste fala com o ADN de verdade.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { createServer, Server } from 'node:https';
import { AddressInfo } from 'node:net';
import { TLSSocket } from 'node:tls';
import { gzipSync } from 'node:zlib';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DfeService } from './../src/sefaz/dfe.service.js';
import { localhostCertificate } from './fake-tls.js';
import { buildPfx } from './fiscal-pfx.js';
import { buildNfse, buildNfseEvent } from './nfse-fixture.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const CENTRO_CNPJ = '11222333000181';
const PFX_PASSWORD = 'senha-do-pfx-da-nfse';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const zip = (xml: string) => gzipSync(Buffer.from(xml, 'utf8')).toString('base64');
const item = (nsu: number, type: string, key: string, xml: string) => ({
  NSU: nsu, ChaveAcesso: key, TipoDocumento: type, TipoEvento: null, ArquivoXml: zip(xml), DataHoraGeracao: '2026-11-11T10:00:00',
});

describe('notas de serviço contra o banco real e o ADN falso', () => {
  let app: INestApplication<App>;
  let adn: Server;
  const sessions = new Map<string, string>();
  const received: { url: string; clientCertificate: boolean }[] = [];
  let respond: (url: string) => { status: number; body: string } = () => ({ status: 500, body: '' });

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: 'get' | 'post', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', newIp()).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const status = () => call('get', '/admin/dfe/status').expect(200).then((r) => (r.body as Json[]).find((row) => row.branch_id === CENTRO) as Json);
  const list = (query = '', email = ADMIN) => call('get', `/admin/service-invoices${query}`, email).expect(200).then((r) => r.body as Json[]);

  // A: recebida, depois substituída por D. B: emitida pela própria filial. C: recebida e cancelada.
  const noteA = buildNfse({ providerName: 'MANUTENCAO A LTDA', takerCnpj: CENTRO_CNPJ });
  const noteB = buildNfse({ providerCnpj: CENTRO_CNPJ, takerCnpj: '11444777000161', description: 'Aplicação de injetável' });
  const noteC = buildNfse({ providerName: 'LIMPEZA C LTDA', takerCnpj: CENTRO_CNPJ });
  const noteD = buildNfse({ providerName: 'MANUTENCAO A LTDA', takerCnpj: CENTRO_CNPJ, replaces: noteA.key, serviceValue: '900.00', netValue: '800.00' });
  // Lote cheio na primeira página: 46 notas de terceiros em que a filial só intermedeia.
  const fillers = Array.from({ length: 46 }, () => buildNfse({ takerCnpj: '11444777000161', providerCnpj: '04252011000110' }));

  beforeAll(async () => {
    const tls = localhostCertificate();
    adn = createServer({ key: tls.key, cert: tls.cert, requestCert: true, rejectUnauthorized: false }, (req, res) => {
      const clientCertificate = Object.keys((req.socket as TLSSocket).getPeerCertificate()).length > 0;
      received.push({ url: req.url ?? '', clientCertificate });
      const answer = clientCertificate ? respond(req.url ?? '') : { status: 403, body: '' };
      res.writeHead(answer.status, { 'Content-Type': 'application/json' });
      res.end(answer.body);
    });
    await new Promise<void>((resolve) => adn.listen(0, '127.0.0.1', resolve));
    const { port } = adn.address() as AddressInfo;
    process.env.SEFAZ_ADN_URL = `https://localhost:${port}/contribuintes`;
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
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: false }).expect(200);
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: true }).expect(200);
  });

  afterAll(async () => {
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: false });
    await app.close();
    await new Promise((resolve) => adn.close(resolve));
    delete process.env.SEFAZ_ADN_URL;
    delete process.env.SEFAZ_TEST_CA;
  });

  it('baixa em lotes de 50 pelo NSU, guarda notas e eventos e espera a hora seguinte', async () => {
    respond = (url) => {
      if (url.startsWith('/contribuintes/DFe/0?')) {
        const first = [
          item(1, 'NFSE', noteA.key, noteA.xml),
          item(2, 'NFSE', noteB.key, noteB.xml),
          ...fillers.map((note, index) => item(3 + index, 'NFSE', note.key, note.xml)),
          item(49, 'NFSE', noteC.key, noteC.xml),
          item(50, 'DPS', noteC.key, '<DPS/>'),
        ];
        return { status: 200, body: JSON.stringify({ StatusProcessamento: 'DOCUMENTOS_LOCALIZADOS', LoteDFe: first }) };
      }
      if (url.startsWith('/contribuintes/DFe/50?')) {
        return {
          status: 200,
          body: JSON.stringify({
            StatusProcessamento: 'DOCUMENTOS_LOCALIZADOS',
            LoteDFe: [
              item(51, 'EVENTO', noteC.key, buildNfseEvent(noteC.key, 'cancel')),
              item(52, 'NFSE', noteD.key, noteD.xml),
              item(53, 'EVENTO', noteA.key, buildNfseEvent(noteA.key, 'replace', noteD.key)),
            ],
          }),
        };
      }
      return { status: 404, body: JSON.stringify({ StatusProcessamento: 'NENHUM_DOCUMENTO_LOCALIZADO', LoteDFe: [] }) };
    };
    received.length = 0;
    const dfe = app.get(DfeService);
    await dfe.syncServiceInvoices();
    expect(received.map((r) => r.url)).toEqual([
      `/contribuintes/DFe/0?cnpjConsulta=${CENTRO_CNPJ}&lote=true`,
      `/contribuintes/DFe/50?cnpjConsulta=${CENTRO_CNPJ}&lote=true`,
    ]);
    expect(received.every((r) => r.clientCertificate)).toBe(true);
    expect(await status()).toMatchObject({ nfse_last_status: 'DOCUMENTOS_LOCALIZADOS', nfse_last_error: null });

    const rows = await list();
    const byKey = (key: string) => rows.find((row) => row.number === '1234' && row.provider_name === (key === noteC.key ? 'LIMPEZA C LTDA' : 'MANUTENCAO A LTDA') && (key === noteD.key ? row.status === 'active' : true));
    expect(rows.filter((row) => ['MANUTENCAO A LTDA', 'LIMPEZA C LTDA'].includes(row.provider_name as string)).map((row) => row.status as string).sort((x, y) => x.localeCompare(y)))
      .toEqual(['active', 'cancelled', 'replaced']);
    expect(rows.some((row) => row.description === 'Aplicação de injetável')).toBe(false);
    expect(rows).toHaveLength(3);
    expect(byKey(noteD.key)).toMatchObject({ service_value: '900.00', net_value: '800.00', iss_withholding: 2, competence: '2026-11-01' });

    // Ainda não deu a hora.
    received.length = 0;
    await dfe.syncServiceInvoices();
    expect(received).toEqual([]);
  });

  it('o detalhe liga a substituída à substituta e entrega o XML original', async () => {
    const rows = await list();
    const fresh = rows.find((row) => row.status === 'active') as Json;
    const old = rows.find((row) => row.status === 'replaced') as Json;
    const freshDetail = (await call('get', `/admin/service-invoices/${fresh.id as string}`).expect(200)).body as Json;
    expect(freshDetail).toMatchObject({ replaces_id: old.id, replaces_number: '1234', status: 'active', access_key: noteD.key, irrf_withheld: '15.00' });
    const oldDetail = (await call('get', `/admin/service-invoices/${old.id as string}`).expect(200)).body as Json;
    expect(oldDetail).toMatchObject({ replaced_by: fresh.id, replaced_by_number: '1234', status: 'replaced' });
    const xml = await call('get', `/admin/service-invoices/${fresh.id as string}/xml`).expect(200);
    expect(xml.headers['content-type']).toContain('application/xml');
    expect(xml.headers['content-disposition']).toBe(`attachment; filename="NFSe-${noteD.key}.xml"`);
    expect(xml.text).toBe(noteD.xml);
  });

  it('filtros, permissões e identificadores', async () => {
    expect((await list('?status=cancelled')).map((row) => row.provider_name)).toEqual(['LIMPEZA C LTDA']);
    expect(await list('?from=2026-12-01')).toEqual([]);
    expect(await list(`?branch=${CENTRO}&from=2026-11-01&to=2026-11-30`)).toHaveLength(3);
    await call('get', '/admin/service-invoices?from=2026-13-01').expect(422);
    await call('get', '/admin/service-invoices?status=x').expect(422);
    expect(await list('', OPERATOR)).toEqual([]);
    const any = (await list())[0];
    expect(codeOf(await call('get', `/admin/service-invoices/${any.id as string}`, OPERATOR).expect(404))).toBe('FA006');
    expect(codeOf(await call('get', `/admin/service-invoices/${any.id as string}/xml`, OPERATOR).expect(404))).toBe('FA006');
  });

  it('recusa do ADN fica registrada com o motivo', async () => {
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: false }).expect(200);
    await call('post', `/admin/branches/${CENTRO}/dfe`).send({ enabled: true }).expect(200);
    respond = () => ({
      status: 400,
      body: JSON.stringify({ StatusProcessamento: 'REJEICAO', Erros: [{ Codigo: 'E2245', Descricao: 'Não há procuração da inscrição' }] }),
    });
    await app.get(DfeService).syncServiceInvoices();
    expect(await status()).toMatchObject({ nfse_last_status: 'REJEICAO', nfse_last_error: 'FA948', nfse_last_message: 'E2245 Não há procuração da inscrição' });
  });
});
