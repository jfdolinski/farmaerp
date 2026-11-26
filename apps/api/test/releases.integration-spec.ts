// Versões do PDV pela API contra o banco real: envio do CI, liberação e download pelo terminal.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { createHash, generateKeyPairSync, randomBytes, randomInt, sign } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { releaseMessage } from './../src/releases/release-signature.js';
import { challengeMessage, pairingProofMessage } from './../src/terminals/terminal-crypto.js';

const ADMIN_EMAIL = 'admin@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';
const UPLOAD_TOKEN = randomBytes(24).toString('hex');
const MAJOR = randomInt(1000, 9000);

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('versões do PDV contra o banco real', () => {
  let app: INestApplication<App>;
  let dir: string;
  let ip: string;
  let token: string;
  let terminalId: string;
  const sessions = new Map<string, string>();
  const releaseKeys = generateKeyPairSync('ed25519');
  const previous = { ...process.env };
  const server = () => app.getHttpServer();
  const as = (email: string, method: 'get' | 'post', path: string) =>
    request(server())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const asTerminal = (method: 'get' | 'post', path: string) =>
    request(server())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  function signed(version: string, content: Buffer, overrides: Json = {}) {
    const sha256 = createHash('sha256').update(content).digest('hex');
    const manifest = { app: 'pdv', platform: 'windows', version, sha256, size: content.length };
    const signature = sign(null, releaseMessage(manifest), releaseKeys.privateKey).toString('base64');
    return { ...manifest, signature, fileName: `FarmaERP-PDV-Setup-${version}.exe`, ...overrides };
  }
  const upload = (query: Json, content: Buffer, auth = UPLOAD_TOKEN) =>
    request(server()).post('/releases').query(query).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${auth}`)
      .set('Content-Type', 'application/octet-stream').send(content);

  beforeAll(async () => {
    dir = mkdtempSync(join(tmpdir(), 'farmaerp-releases-'));
    process.env.RELEASES_DIR = dir;
    process.env.RELEASE_UPLOAD_TOKEN = UPLOAD_TOKEN;
    process.env.UPDATE_TEST_PUBLIC_KEY = releaseKeys.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
    const destination = new Writable({ write(_chunk: Buffer, _encoding, callback) { callback(); } });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(destination))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
    for (const email of [ADMIN_EMAIL, OPERATOR_EMAIL]) {
      sessions.set(email, ((await request(server()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: DEV_PASSWORD }).expect(200)).body as Json).token as string);
    }
    // Terminal de verdade, como no PDV.
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const key = publicKey.export({ format: 'jwk' }).x!;
    const signText = (message: string) => sign(null, Buffer.from(message), privateKey).toString('base64url');
    const pairing = (await request(server()).post('/terminals/pairing/requests').set('X-Forwarded-For', ip).send({
      publicKey: key, signature: signText(pairingProofMessage(key)), platform: 'windows',
      deviceName: 'CAIXA-VERSOES', appVersion: '0.1.0', keyStorage: 'system',
    }).expect(201)).body as Json;
    terminalId = ((await as(ADMIN_EMAIL, 'post', `/admin/pairing/${pairing.code}/claim`).send({ branchId: BRANCH_CENTRO }).expect(201)).body as Json)
      .terminalId as string;
    await as(ADMIN_EMAIL, 'post', `/admin/terminals/${terminalId}/approve`).send({ name: `Caixa versões ${Date.now()}`, profile: 'cashier' }).expect(200);
    const challenge = ((await request(server()).post('/terminals/auth/challenge').set('X-Forwarded-For', ip)
      .send({ terminalId }).expect(200)).body as Json).challenge as string;
    token = ((await request(server()).post('/terminals/auth/token').set('X-Forwarded-For', ip)
      .send({ challenge, signature: signText(challengeMessage(challenge)) }).expect(200)).body as Json).accessToken as string;
  });

  afterAll(async () => {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
    process.env = previous;
  });

  it('envio do CI: token, assinatura e resumo conferidos; versão repetida recusada', async () => {
    const version = `${MAJOR}.0.0`;
    const content = randomBytes(4096);
    const query = signed(version, content);
    expect(codeOf(await upload(query, content, 'token-errado').expect(403))).toBe('FA876');
    expect(codeOf(await upload({ ...query, version: `${version.split('.')[0]}.0.1` }, content).expect(422))).toBe('FA869');
    expect(codeOf(await upload(query, randomBytes(4096)).expect(422))).toBe('FA869');
    expect(codeOf(await upload({ ...query, fileName: '../fora.exe' }, content).expect(422))).toBe('FA869');
    const created = (await upload(query, content).expect(201)).body as Json;
    expect(created.id).toEqual(expect.any(String));
    expect(codeOf(await upload(query, content).expect(409))).toBe('FA874');
    const list = (await as(ADMIN_EMAIL, 'get', '/platform/releases').expect(200)).body as Json[];
    expect(list.find((r) => r.id === created.id)).toMatchObject({ app_version: version, status: 'test', size_bytes: '4096' });
    expect(codeOf(await as(OPERATOR_EMAIL, 'get', '/platform/releases').expect(403))).toBe('FA002');
    // Retirada, para não ser oferecida nos testes seguintes.
    await as(ADMIN_EMAIL, 'post', `/platform/releases/${created.id}/status`).send({ status: 'withdrawn' }).expect(200);
  });

  it('terminal de teste recebe, baixa por partes e informa; a rede só depois da liberação', async () => {
    const version = `${MAJOR}.1.0`;
    const content = randomBytes(10_000);
    const id = ((await upload(signed(version, content), content).expect(201)).body as Json).id as string;
    const check = async () => ((await asTerminal('get', `/terminals/updates?platform=windows&current=${MAJOR}.0.9`).expect(200)).body as Json);
    expect(codeOf(await asTerminal('get', '/terminals/updates?platform=mac&current=1.0.0').expect(422))).toBe('FA005');
    expect((await check()).release?.id).not.toBe(id);
    expect(codeOf(await asTerminal('get', `/terminals/updates/${id}/file`).expect(404))).toBe('FA875');

    expect(codeOf(await as(ADMIN_EMAIL, 'post', `/admin/terminals/${terminalId}/update-ring`).send({ ring: 'beta' }).expect(422))).toBe('FA878');
    await as(ADMIN_EMAIL, 'post', `/admin/terminals/${terminalId}/update-ring`).send({ ring: 'test' }).expect(200);
    const offered = await check();
    expect(offered).toMatchObject({ available: true, release: { id, version, size: 10_000 } });

    const whole = await asTerminal('get', `/terminals/updates/${id}/file`).buffer(true).parse((res, done) => {
      const parts: Buffer[] = [];
      res.on('data', (chunk: Buffer) => parts.push(chunk));
      res.on('end', () => done(null, Buffer.concat(parts)));
    }).expect(200);
    expect(Buffer.compare(whole.body as Buffer, content)).toBe(0);
    const part = await asTerminal('get', `/terminals/updates/${id}/file`).set('Range', 'bytes=9000-').buffer(true).parse((res, done) => {
      const parts: Buffer[] = [];
      res.on('data', (chunk: Buffer) => parts.push(chunk));
      res.on('end', () => done(null, Buffer.concat(parts)));
    }).expect(206);
    expect(Buffer.compare(part.body as Buffer, content.subarray(9000))).toBe(0);

    expect(codeOf(await asTerminal('post', `/terminals/updates/${id}/report`).send({ status: 'quebrou' }).expect(422))).toBe('FA005');
    await asTerminal('post', `/terminals/updates/${id}/report`).send({ status: 'applied' }).expect(200);
    const terminals = (await as(ADMIN_EMAIL, 'get', '/admin/terminals').expect(200)).body as Json[];
    expect(terminals.find((t) => t.id === terminalId)).toMatchObject({ update_ring: 'test', last_update_status: 'applied', last_update_version: version });

    expect(codeOf(await as(ADMIN_EMAIL, 'post', `/platform/releases/${id}/status`).send({ status: 'test' }).expect(409))).toBe('FA877');
    await as(ADMIN_EMAIL, 'post', `/platform/releases/${id}/status`).send({ status: 'withdrawn' }).expect(200);
    expect(codeOf(await asTerminal('get', `/terminals/updates/${id}/file`).expect(404))).toBe('FA875');
    await as(ADMIN_EMAIL, 'post', `/admin/terminals/${terminalId}/update-ring`).send({ ring: 'general' }).expect(200);
  });

  it('sem o terminal autenticado, nada', async () => {
    await request(server()).get('/terminals/updates?platform=windows&current=1.0.0').set('X-Forwarded-For', ip).expect(401);
  });
});
