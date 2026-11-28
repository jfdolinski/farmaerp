// Notas fiscais (NFC-e) pela central contra o banco real e uma Sefaz falsa (TLS local): reenvio
// automático, consulta, cancelamento com a venda e inutilização. Nada sai para a Sefaz de verdade.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { generateKeyPairSync, randomBytes, randomInt, sign } from 'node:crypto';
import { createServer, Server } from 'node:https';
import { AddressInfo } from 'node:net';
import { Writable } from 'node:stream';
import { TLSSocket } from 'node:tls';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DatabaseService } from './../src/database.service.js';
import { NfceActionsService } from './../src/fiscal/nfce-actions.service.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { challengeMessage, pairingProofMessage } from './../src/terminals/terminal-crypto.js';
import { localhostCertificate } from './fake-tls.js';
import { buildPfx } from './fiscal-pfx.js';
import { saleNfe } from './nfe-fixture.js';

const ADMIN_EMAIL = 'admin@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';
const OPERATOR_ID = '019a0000-0000-7000-8000-000000000009';
const DEMO_CUSTOMER = '019a0000-0000-7000-8000-000000000032';
const PFX_PASSWORD = 'senha-do-pfx-da-nfce';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

let clockMs = Date.now();
function uuidV7() {
  clockMs += 1;
  const bytes = randomBytes(16);
  bytes.writeUIntBE(clockMs, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const soap = (inner: string) =>
  `<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"><soap:Body><nfeResultMsg>${inner}</nfeResultMsg></soap:Body></soap:Envelope>`;
const prot = (key: string, status: string, protocol: string) =>
  `<protNFe versao="4.00"><infProt><tpAmb>2</tpAmb><chNFe>${key}</chNFe><dhRecbto>2026-11-26T10:00:01-03:00</dhRecbto>`
  + `<nProt>${protocol}</nProt><cStat>${status}</cStat><xMotivo>Motivo ${status}</xMotivo></infProt></protNFe>`;
const keyOf = (body: string) => /<chNFe>(\d{44})<\/chNFe>/.exec(body)?.[1] ?? /Id="NFe(\d{44})"/.exec(body)?.[1] ?? '';

describe('notas fiscais pela central contra o banco real', () => {
  let app: INestApplication<App>;
  let sefaz: Server;
  let token: string;
  let series: number;
  let series55: number;
  let sessionId: string;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const received: { path: string; body: string; clientCertificate: boolean }[] = [];
  // O que a Sefaz falsa responde, por chave: na consulta e na autorização.
  const onStatus = new Map<string, string>();
  const onAuthorization = new Map<string, string>();
  // Situação que a Sefaz falsa devolve no evento e na inutilização.
  let eventStatus = '135';
  let voidingStatus = '102';
  const server = () => app.getHttpServer();
  const admin = (method: 'get' | 'post', path: string, email = ADMIN_EMAIL) =>
    request(server())[method](`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  let sequence = 0;
  const push = (items: Json[]) =>
    request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
      .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
  const base = Math.floor(Date.now() / 1000) % 800000 + 1000;
  let numberOffset = 0;

  /** Venda e NFC-e do caixa. Devolve o id da nota. */
  async function saleWithNote(note: Json, number = base + numberOffset++) {
    const saleId = uuidV7();
    const sale = {
      id: saleId, number, cash_session_id: sessionId, operator_id: OPERATOR_ID, customer_id: null, sold_at: new Date().toISOString(), fiscal_model: '65',
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 1, unit_price: 12.9, discount: 0, total: 12.9 }],
      payments: [{ id: uuidV7(), method: 'cash', amount: 12.9, change: 0 }], subtotal: 12.9, discount_total: 0, total: 12.9,
    };
    expect((await push([{ kind: 'sale', payload: sale }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    const id = uuidV7();
    const accessKey = `35261111222333000181650${String(series).padStart(3, '0')}${String(number).padStart(9, '0')}1${String(randomInt(1e8)).padStart(8, '0')}`;
    expect((await push([{ kind: 'nfce', payload: {
      id, sale_id: saleId, series, number, access_key: accessKey, environment: 2, emission_type: 1, status: 'authorized',
      protocol: '135260000000123', status_code: '100', reason: 'Autorizado o uso da NF-e',
      xml: `<?xml version="1.0" encoding="UTF-8"?><NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe Id="NFe${accessKey}" versao="4.00">${'<x/>'.repeat(30)}</infNFe></NFe>`,
      emitted_at: new Date().toISOString(), authorized_at: new Date().toISOString(), ...note,
    } }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    return { id, accessKey, saleId };
  }
  const contingency = (hoursAgo: number) => ({
    status: 'contingency', emission_type: 9, protocol: null, status_code: null, reason: null, authorized_at: null,
    emitted_at: new Date(Date.now() - hoursAgo * 3_600_000).toISOString(),
  });

  beforeAll(async () => {
    const tls = localhostCertificate();
    sefaz = createServer({ key: tls.key, cert: tls.cert, requestCert: true, rejectUnauthorized: false }, (req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (chunk: Buffer) => chunks.push(chunk));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        const path = req.url ?? '';
        received.push({ path, body, clientCertificate: Object.keys((req.socket as TLSSocket).getPeerCertificate()).length > 0 });
        const key = keyOf(body);
        let answer = '';
        if (path.endsWith('/status')) {
          answer = soap(onStatus.get(key) ?? '<retConsSitNFe versao="4.00"><cStat>217</cStat><xMotivo>NF-e nao consta</xMotivo></retConsSitNFe>');
        } else if (path.endsWith('/authorization')) {
          answer = soap(onAuthorization.get(key) ?? `<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo>${prot(key, '100', '135260000000555')}</retEnviNFe>`);
        } else if (path.endsWith('/event')) {
          answer = soap(`<retEnvEvento versao="1.00"><cStat>128</cStat><xMotivo>Lote processado</xMotivo><retEvento versao="1.00"><infEvento>`
            + (eventStatus === '573'
              // Evento repetido: a Sefaz não devolve protocolo.
              ? '<cStat>573</cStat><xMotivo>Rejeicao: Duplicidade de evento</xMotivo></infEvento></retEvento></retEnvEvento>'
              : `<cStat>${eventStatus}</cStat><xMotivo>${eventStatus === '135' ? 'Evento registrado' : 'Prazo de cancelamento superior ao previsto'}</xMotivo><nProt>135260000000888</nProt><dhRegEvento>2026-11-26T10:10:05-03:00</dhRegEvento></infEvento></retEvento></retEnvEvento>`));
        } else if (path.endsWith('/voiding')) {
          answer = soap(`<retInutNFe versao="4.00"><infInut><tpAmb>2</tpAmb><cStat>${voidingStatus}</cStat><xMotivo>${voidingStatus === '102' ? 'Inutilizacao homologada' : 'Numero ja inutilizado'}</xMotivo>`
            + '<nProt>135260000000999</nProt><dhRecbto>2026-11-26T11:00:00-03:00</dhRecbto></infInut></retInutNFe>');
        }
        res.writeHead(answer ? 200 : 404, { 'Content-Type': 'application/soap+xml; charset=utf-8' });
        res.end(answer);
      });
    });
    await new Promise<void>((resolve) => sefaz.listen(0, '127.0.0.1', resolve));
    process.env.SEFAZ_NFCE_URL = `https://localhost:${(sefaz.address() as AddressInfo).port}`;
    // A NF-e 55 fala com os serviços da NF-e: o mesmo servidor falso, noutro caminho.
    process.env.SEFAZ_NFE_URL = `https://localhost:${(sefaz.address() as AddressInfo).port}/nfe`;
    process.env.SEFAZ_TEST_CA = tls.cert;
    process.env.FISCAL_WORKER = 'off';

    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() })))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN_EMAIL, OPERATOR_EMAIL]) {
      sessions.set(email, ((await request(server()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: DEV_PASSWORD }).expect(200)).body as Json).token as string);
    }
    await admin('post', `/fiscal/branches/${CENTRO}/certificate`)
      .send({ file: buildPfx({ password: PFX_PASSWORD }).toString('base64'), password: PFX_PASSWORD }).expect(201);

    // Terminal de verdade na filial Centro.
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const key = publicKey.export({ format: 'jwk' }).x!;
    const signText = (message: string) => sign(null, Buffer.from(message), privateKey).toString('base64url');
    const pairing = (await request(server()).post('/terminals/pairing/requests').set('X-Forwarded-For', ip).send({
      publicKey: key, signature: signText(pairingProofMessage(key)), platform: 'windows', deviceName: 'CAIXA-FISCAL', appVersion: '0.2.3', keyStorage: 'system',
    }).expect(201)).body as Json;
    const terminalId = ((await admin('post', `/pairing/${pairing.code}/claim`).send({ branchId: CENTRO }).expect(201)).body as Json).terminalId as string;
    await admin('post', `/terminals/${terminalId}/approve`).send({ name: `Caixa fiscal ${Date.now()}`, profile: 'cashier' }).expect(200);
    const challenge = ((await request(server()).post('/terminals/auth/challenge').set('X-Forwarded-For', ip).send({ terminalId }).expect(200)).body as Json).challenge as string;
    token = ((await request(server()).post('/terminals/auth/token').set('X-Forwarded-For', ip)
      .send({ challenge, signature: signText(challengeMessage(challenge)) }).expect(200)).body as Json).accessToken as string;
    const fiscal = ((await request(server()).post('/terminals/sync/pull').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`).send({ cursor: null }).expect(200)).body as Json)
      .items.find((item: Json) => item.type === 'fiscal')?.data as Json;
    series = (fiscal.series as Json[]).find((row) => row.model === '65')?.series as number;
    series55 = (fiscal.series as Json[]).find((row) => row.model === '55')?.series as number;
    sessionId = uuidV7();
    await push([{ kind: 'cash_session_open', payload: { id: sessionId, operator_id: OPERATOR_ID, opened_at: new Date().toISOString(), opening_float: 0 } }]).expect(200);
  });

  afterAll(async () => {
    await app.close();
    await new Promise((resolve) => sefaz.close(resolve));
    delete process.env.SEFAZ_NFCE_URL;
    delete process.env.SEFAZ_NFE_URL;
    delete process.env.SEFAZ_TEST_CA;
    delete process.env.FISCAL_WORKER;
  });

  it('cancela a NFC-e na Sefaz e a venda junto; o XML do cancelamento fica para baixar', async () => {
    const note = await saleWithNote({});
    expect(codeOf(await admin('post', `/fiscal-documents/${note.id}/cancel`).send({ reason: 'curto' }).expect(422))).toBe('FA005');
    expect(codeOf(await admin('post', `/fiscal-documents/${note.id}/cancel`, OPERATOR_EMAIL).send({ reason: 'Cliente desistiu da compra' }).expect(404))).toBe('FA006');
    const result = (await admin('post', `/fiscal-documents/${note.id}/cancel`).send({ reason: 'Cliente desistiu da compra' }).expect(200)).body as Json;
    expect(result).toMatchObject({ cash_refund: 'same_session', sefaz: '135 Evento registrado' });
    const event = received.filter((r) => r.path.endsWith('/event')).at(-1)!;
    expect(event.clientCertificate).toBe(true);
    expect(event.body).toContain(`<chNFe>${note.accessKey}</chNFe>`);
    expect(event.body).toContain('<cOrgao>35</cOrgao>');
    expect(event.body).toContain('<xJust>Cliente desistiu da compra</xJust>');
    const listed = ((await admin('get', '/fiscal-documents?status=canceled').expect(200)).body as Json[]).find((row) => row.id === note.id);
    expect(listed).toMatchObject({ status: 'canceled', access_key: note.accessKey });
    const file = await admin('get', `/fiscal-documents/${note.id}/xml?kind=cancel`).expect(200);
    expect(file.headers['content-disposition']).toContain(`Cancelamento-NFCe-${note.accessKey}.xml`);
    expect(file.text).toContain('<procEventoNFe');
    expect(((await admin('get', '/sales').expect(200)).body as Json[]).some((row) => row.id === note.saleId)).toBe(false);
    expect(codeOf(await admin('post', `/fiscal-documents/${note.id}/cancel`).send({ reason: 'Cliente desistiu da compra' }).expect(409))).toBe('FA753');
  });

  it('reenvio automático: consulta, envia o que não chegou, e a recusada vira aviso', async () => {
    const lost = await saleWithNote(contingency(13));
    const fresh = await saleWithNote(contingency(13));
    const refused = await saleWithNote(contingency(13));
    // Chegou na Sefaz, mas o caixa ficou sem o protocolo.
    onStatus.set(lost.accessKey, `<retConsSitNFe versao="4.00"><cStat>100</cStat><xMotivo>Autorizado</xMotivo>${prot(lost.accessKey, '100', '135260000000444')}</retConsSitNFe>`);
    onAuthorization.set(refused.accessKey, `<retEnviNFe><cStat>104</cStat><xMotivo>Lote processado</xMotivo>${prot(refused.accessKey, '778', '135260000000000')}</retEnviNFe>`);
    const done = await app.get(NfceActionsService).tick();
    expect(done).toBeGreaterThanOrEqual(3);
    const rows = (await admin('get', '/fiscal-documents').expect(200)).body as Json[];
    const of = (id: string) => rows.find((row) => row.id === id) as Json;
    expect(of(lost.id)).toMatchObject({ status: 'authorized', resend_status: 'authorized' });
    expect(of(fresh.id)).toMatchObject({ status: 'authorized', resend_status: 'authorized' });
    expect(of(refused.id)).toMatchObject({ status: 'rejected', resend_status: 'refused', alert: true, resend_message: '778 Motivo 778' });
    // A que estava na Sefaz não foi enviada de novo.
    expect(received.some((r) => r.path.endsWith('/authorization') && r.body.includes(lost.accessKey))).toBe(false);
    const alerts = (await admin('get', '/fiscal-documents?alerts=1').expect(200)).body as Json[];
    expect(alerts.map((row) => row.id)).toContain(refused.id);
    await admin('post', `/fiscal-documents/${refused.id}/dismiss`).expect(200);
    expect(((await admin('get', '/fiscal-documents?alerts=1').expect(200)).body as Json[]).map((row) => row.id)).not.toContain(refused.id);
    // Na mesma hora, a rotina não pega outro lote.
    expect(await app.get(NfceActionsService).tick()).toBe(0);
    // O botão reenvia a recusada (agora a Sefaz autoriza).
    onAuthorization.delete(refused.accessKey);
    expect((await admin('post', `/fiscal-documents/${refused.id}/resend`).expect(200)).body).toEqual({ status: 'authorized' });
  });

  it('consulta pela chave acerta a nota pendente', async () => {
    const pending = await saleWithNote({ ...contingency(0), status: 'pending', emission_type: 1 });
    onStatus.set(pending.accessKey, `<retConsSitNFe versao="4.00"><cStat>100</cStat><xMotivo>Autorizado</xMotivo>${prot(pending.accessKey, '100', '135260000000666')}</retConsSitNFe>`);
    expect((await admin('post', `/fiscal-documents/${pending.id}/consult`).expect(200)).body).toEqual({ status: 'authorized' });
    const file = await admin('get', `/fiscal-documents/${pending.id}/xml`).expect(200);
    expect(file.text).toContain('<nProt>135260000000666</nProt>');
  });

  it('inutiliza o buraco de numeração sugerido', async () => {
    const first = base + 500;
    await saleWithNote({}, first);
    await saleWithNote({}, first + 3);
    const gap = ((await admin('get', `/fiscal-documents/gaps?branch=${CENTRO}`).expect(200)).body as Json[])
      .find((row) => row.series === series && Number(row.first_number) === first + 1);
    expect(gap).toMatchObject({ last_number: String(first + 2), quantity: '2' });
    expect(codeOf(await admin('post', '/fiscal-documents/voids').send({ branchId: CENTRO, series, first, last: first + 1, reason: 'Numeracao pulada no caixa' }).expect(422))).toBe('FA755');
    const voided = (await admin('post', '/fiscal-documents/voids').send({ branchId: CENTRO, series, first: first + 1, last: first + 2, reason: 'Numeracao pulada no caixa' }).expect(201)).body as Json;
    expect(voided.protocol).toBe('135260000000999');
    const message = received.filter((r) => r.path.endsWith('/voiding')).at(-1)!;
    expect(message.body).toContain(`<serie>${series}</serie><nNFIni>${first + 1}</nNFIni><nNFFin>${first + 2}</nNFFin>`);
    expect(((await admin('get', `/fiscal-documents/voids?branch=${CENTRO}`).expect(200)).body as Json[])[0]).toMatchObject({ protocol: '135260000000999' });
    expect(codeOf(await admin('post', '/fiscal-documents/voids', OPERATOR_EMAIL).send({ branchId: CENTRO, series, first: first + 1, last: first + 1, reason: 'Numeracao pulada no caixa' }).expect(403))).toBe('FA002');
  });

  it('recusa da Sefaz no cancelamento e na inutilização volta com o código e o motivo', async () => {
    const note = await saleWithNote({});
    eventStatus = '501';
    const refused = (await admin('post', `/fiscal-documents/${note.id}/cancel`).send({ reason: 'Cliente desistiu da compra' }).expect(422)).body as Json;
    eventStatus = '135';
    expect(refused).toMatchObject({ code: 'FA754' });
    expect(String(refused.detail)).toMatch(/^Sefaz 501: /);
    // A nota continua autorizada e a venda, de pé.
    expect(((await admin('get', '/fiscal-documents?status=authorized').expect(200)).body as Json[]).map((row) => row.id)).toContain(note.id);

    const first = base + 700;
    await saleWithNote({}, first);
    await saleWithNote({}, first + 2);
    voidingStatus = '563';
    const voidRefused = (await admin('post', '/fiscal-documents/voids').send({ branchId: CENTRO, series, first: first + 1, last: first + 1, reason: 'Numeracao pulada no caixa' }).expect(422)).body as Json;
    voidingStatus = '102';
    expect(voidRefused).toMatchObject({ code: 'FA754' });
    expect(String(voidRefused.detail)).toMatch(/^Sefaz 563: /);
  });

  it('o caixa pede o cancelamento com o supervisor; repetido responde que já está feito', async () => {
    const note = await saleWithNote({});
    const terminal = (path: string) => request(server()).post(path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
    const adminId = ((await request(server()).get('/auth/me').set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${sessions.get(ADMIN_EMAIL)}`).expect(200)).body as Json).userId as string;
    const path = `/terminals/fiscal-documents/${note.id}/cancel`;
    expect(codeOf(await terminal(path).send({ reason: 'curto', supervisorId: adminId }).expect(422))).toBe('FA005');
    // O operador do seed não tem "Cancelar NFC-e".
    expect(codeOf(await terminal(path).send({ reason: 'Cliente desistiu no caixa', supervisorId: OPERATOR_ID }).expect(403))).toBe('FA002');
    const done = (await terminal(path).send({ reason: 'Cliente desistiu no caixa', supervisorId: adminId }).expect(200)).body as Json;
    expect(done).toMatchObject({ cash_refund: 'same_session', sefaz: '135 Evento registrado' });
    const sent = () => received.filter((r) => r.path.endsWith('/event') && r.body.includes(note.accessKey));
    expect(sent()).toHaveLength(1);
    // Pedido de novo (o caixa não viu a resposta): já está feito, sem chamar a Sefaz.
    expect((await terminal(path).send({ reason: 'Cliente desistiu no caixa', supervisorId: adminId }).expect(200)).body).toEqual({ already: true });
    expect(sent()).toHaveLength(1);
    // Sem o token do caixa, nada.
    await request(server()).post(path).set('X-Forwarded-For', ip).send({ reason: 'Cliente desistiu no caixa', supervisorId: adminId }).expect(401);
  });

  it('pedido repetido (573, sem protocolo): consulta a chave e registra com o evento que a Sefaz guardou', async () => {
    const canceledAt = (key: string, protocol: string) => '<retConsSitNFe versao="4.00"><cStat>101</cStat><xMotivo>Cancelamento de NF-e homologado</xMotivo>'
      + `${prot(key, '100', '135260000000123')}<procEventoNFe versao="1.00"><evento versao="1.00"><infEvento Id="ID110111${key}01"><chNFe>${key}</chNFe>`
      + '<tpEvento>110111</tpEvento><detEvento versao="1.00"><nProt>135260000000123</nProt></detEvento></infEvento></evento>'
      + `<retEvento versao="1.00"><infEvento><tpEvento>110111</tpEvento><cStat>135</cStat><xMotivo>Evento registrado</xMotivo><nProt>${protocol}</nProt>`
      + '<dhRegEvento>2026-11-26T10:10:05-03:00</dhRegEvento></infEvento></retEvento></procEventoNFe></retConsSitNFe>';
    const adminId = ((await request(server()).get('/auth/me').set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${sessions.get(ADMIN_EMAIL)}`).expect(200)).body as Json).userId as string;
    eventStatus = '573';
    try {
      // Pela retaguarda.
      const fromAdmin = await saleWithNote({});
      onStatus.set(fromAdmin.accessKey, canceledAt(fromAdmin.accessKey, '135260000000901'));
      expect((await admin('post', `/fiscal-documents/${fromAdmin.id}/cancel`).send({ reason: 'Cliente desistiu da compra' }).expect(200)).body)
        .toMatchObject({ cash_refund: 'same_session', sefaz: '573 Rejeicao: Duplicidade de evento' });
      const file = (await admin('get', `/fiscal-documents/${fromAdmin.id}/xml?kind=cancel`).expect(200)).text;
      expect(file).toContain('<nProt>135260000000901</nProt>');
      // Grava o protocolo do evento de cancelamento, não o da autorização.
      const eventOf = (documentId: string) => app.get(DatabaseService).withContext(async (client) => (await client.query<{ protocol: string; registered_at: Date }>(
        "SELECT protocol, registered_at FROM public.fiscal_event WHERE fiscal_document_id = $1 AND kind = 'cancellation'", [documentId])).rows[0], { userId: adminId });
      expect(await eventOf(fromAdmin.id)).toMatchObject({ protocol: '135260000000901', registered_at: new Date('2026-11-26T13:10:05Z') });
      // Pelo caixa.
      const fromTerminal = await saleWithNote({});
      onStatus.set(fromTerminal.accessKey, canceledAt(fromTerminal.accessKey, '135260000000902'));
      expect((await request(server()).post(`/terminals/fiscal-documents/${fromTerminal.id}/cancel`).set('X-Forwarded-For', ip)
        .set('Authorization', `Bearer ${token}`).send({ reason: 'Cliente desistiu no caixa', supervisorId: adminId }).expect(200)).body)
        .toMatchObject({ cash_refund: 'same_session' });
      expect((await admin('get', `/fiscal-documents/${fromTerminal.id}/xml?kind=cancel`).expect(200)).text).toContain('<nProt>135260000000902</nProt>');
      expect((await eventOf(fromTerminal.id)).protocol).toBe('135260000000902');
      // 573 e a consulta ainda mostra autorizada: não cancela nada e diz o motivo.
      const still = await saleWithNote({});
      onStatus.set(still.accessKey, `<retConsSitNFe versao="4.00"><cStat>100</cStat><xMotivo>Autorizado</xMotivo>${prot(still.accessKey, '100', '135260000000123')}</retConsSitNFe>`);
      const refused = (await admin('post', `/fiscal-documents/${still.id}/cancel`).send({ reason: 'Cliente desistiu da compra' }).expect(422)).body as Json;
      expect(refused).toMatchObject({ code: 'FA754' });
      expect(String(refused.detail)).toMatch(/^Sefaz 573: /);
      expect(((await admin('get', '/fiscal-documents?status=authorized').expect(200)).body as Json[]).some((row) => row.id === still.id)).toBe(true);
    } finally {
      eventStatus = '135';
    }
  });

  it('NF-e de venda (55) do caixa: XML e DANFE A4; consulta e cancelamento nos serviços da NF-e, com a venda desfeita', async () => {
    const saleId = uuidV7();
    const number = base + numberOffset++;
    expect((await push([{ kind: 'sale', payload: {
      id: saleId, number, cash_session_id: sessionId, operator_id: OPERATOR_ID, customer_id: DEMO_CUSTOMER, sold_at: new Date().toISOString(), fiscal_model: '55',
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 1, unit_price: 12.9, discount: 0, total: 12.9 }],
      payments: [{ id: uuidV7(), method: 'cash', amount: 12.9, change: 0 }], subtotal: 12.9, discount_total: 0, total: 12.9,
    } }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    const nfe = saleNfe({ series: series55, number });
    const id = uuidV7();
    expect((await push([{ kind: 'nfce', payload: {
      id, model: '55', sale_id: saleId, series: series55, number, access_key: nfe.key, environment: 2, emission_type: 1, status: 'authorized',
      protocol: '135260000000124', status_code: '100', reason: 'Autorizado o uso da NF-e', xml: nfe.xml,
      emitted_at: new Date().toISOString(), authorized_at: new Date().toISOString(),
    } }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });

    const listed = ((await admin('get', '/fiscal-documents').expect(200)).body as Json[]).find((row) => row.id === id);
    expect(listed).toMatchObject({ model: '55', series: series55 });
    // Cancelável por 24 horas (a NFC-e, 30 minutos).
    expect(new Date(listed!.cancelable_until as string).getTime() - Date.now()).toBeGreaterThan(23 * 3_600_000);
    const xml = await admin('get', `/fiscal-documents/${id}/xml`).expect(200);
    expect(xml.headers['content-disposition']).toContain(`NFe-${nfe.key}.xml`);
    const danfe = await admin('get', `/fiscal-documents/${id}/danfe`).buffer(true).parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => done(null, Buffer.concat(chunks)));
    }).expect(200);
    expect(danfe.headers['content-type']).toContain('application/pdf');
    expect((danfe.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');

    // Autorizada não se reenvia (o código da NF-e) e nada vai à Sefaz.
    const before = received.length;
    expect(codeOf(await admin('post', `/fiscal-documents/${id}/resend`).expect(409))).toBe('FA787');
    expect(received.length).toBe(before);
    // A consulta vai ao serviço de consulta da NF-e (não ao da NFC-e).
    await admin('post', `/fiscal-documents/${id}/consult`).expect(200);
    expect(received.at(-1)).toMatchObject({ path: '/nfe/status', clientCertificate: true });
    expect(received.at(-1)!.body).toContain(`<chNFe>${nfe.key}</chNFe>`);

    // Cancela no evento da NF-e e desfaz a venda.
    const canceled = (await admin('post', `/fiscal-documents/${id}/cancel`).send({ reason: 'Cliente pediu nota com outro CNPJ' }).expect(200)).body as Json;
    expect(canceled).toMatchObject({ cash_refund: 'same_session', sefaz: '135 Evento registrado' });
    const event = received.at(-1)!;
    expect(event.path).toBe('/nfe/event');
    expect(event.body).toContain(`<chNFe>${nfe.key}</chNFe>`);
    expect(event.body).toContain('<nProt>135260000000124</nProt>');
    expect(event.body).toContain('<cOrgao>35</cOrgao>');
    expect(((await admin('get', '/sales').expect(200)).body as Json[]).some((row) => row.id === saleId)).toBe(false);
    const cancelFile = await admin('get', `/fiscal-documents/${id}/xml?kind=cancel`).expect(200);
    expect(cancelFile.headers['content-disposition']).toContain(`Cancelamento-NFe-${nfe.key}.xml`);
    expect(codeOf(await admin('post', `/fiscal-documents/${id}/cancel`).send({ reason: 'Cliente pediu nota com outro CNPJ' }).expect(409))).toBe('FA787');

    // A NFC-e não tem DANFE A4 aqui (o cupom sai no caixa).
    const note = await saleWithNote({});
    expect(codeOf(await admin('get', `/fiscal-documents/${note.id}/danfe`).expect(404))).toBe('FA006');
    expect((await admin('get', `/fiscal-documents/${note.id}/xml`).expect(200)).headers['content-disposition']).toContain('NFCe-');
  });
});
