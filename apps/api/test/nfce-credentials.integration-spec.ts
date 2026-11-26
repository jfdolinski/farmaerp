// NFC-e no caixa pela API contra o banco real: "Emitir NFC-e" na filial, chave de criptografia do
// caixa e a entrega do certificado e do CSC cifrados para aquele caixa.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import {
  createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, randomInt, sign, verify, X509Certificate,
} from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { type CredentialEnvelope, envelopeContext, openForTerminal } from './../src/terminals/credential-envelope.js';
import { challengeMessage, pairingProofMessage } from './../src/terminals/terminal-crypto.js';
import { fiscalKeyMessage } from './../src/terminals/terminal-nfce.controller.js';
import { buildPfx } from './fiscal-pfx.js';

const ADMIN_EMAIL = 'admin@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const COMPANY = '019a0000-0000-7000-8000-000000000002';
const BRANCH_SUL = '019a0000-0000-7000-8000-000000000006';
const PFX_PASSWORD = 'senha-do-pfx-da-nfce';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('NFC-e no caixa contra o banco real', () => {
  let app: INestApplication<App>;
  let ip: string;
  let token: string;
  let terminalId: string;
  let signText: (message: string) => string;
  const sessions = new Map<string, string>();
  const server = () => app.getHttpServer();
  const as = (email: string, method: 'get' | 'post' | 'put' | 'patch', path: string) =>
    request(server())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const asTerminal = (method: 'post', path: string) =>
    request(server())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const fiscalKey = () => {
    const seed = randomBytes(32);
    const privateKey = createPrivateKey({
      key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), seed]), format: 'der', type: 'pkcs8',
    });
    return { seed, publicKey: createPublicKey(privateKey).export({ format: 'jwk' }).x! };
  };
  const setNfce = (body: Json, email = ADMIN_EMAIL) => as(email, 'put', `/admin/fiscal/branches/${BRANCH_SUL}/nfce`).send(body);
  const nfceRow = async () =>
    ((await as(ADMIN_EMAIL, 'get', '/admin/fiscal/nfce').expect(200)).body as Json[]).find((row) => row.branch_id === BRANCH_SUL);

  beforeAll(async () => {
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
    // Terminal de caixa de verdade, como no PDV.
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const key = publicKey.export({ format: 'jwk' }).x!;
    signText = (message: string) => sign(null, Buffer.from(message), privateKey).toString('base64url');
    const pairing = (await request(server()).post('/terminals/pairing/requests').set('X-Forwarded-For', ip).send({
      publicKey: key, signature: signText(pairingProofMessage(key)), platform: 'windows',
      deviceName: 'CAIXA-NFCE', appVersion: '0.2.1', keyStorage: 'system',
    }).expect(201)).body as Json;
    terminalId = ((await as(ADMIN_EMAIL, 'post', `/admin/pairing/${pairing.code}/claim`).send({ branchId: BRANCH_SUL }).expect(201)).body as Json)
      .terminalId as string;
    await as(ADMIN_EMAIL, 'post', `/admin/terminals/${terminalId}/approve`).send({ name: `Caixa NFC-e ${Date.now()}`, profile: 'cashier' }).expect(200);
    const challenge = ((await request(server()).post('/terminals/auth/challenge').set('X-Forwarded-For', ip)
      .send({ terminalId }).expect(200)).body as Json).challenge as string;
    token = ((await request(server()).post('/terminals/auth/token').set('X-Forwarded-For', ip)
      .send({ challenge, signature: signText(challengeMessage(challenge)) }).expect(200)).body as Json).accessToken as string;

    // Filial completa: regime, inscrição, certificado e CSC.
    await as(ADMIN_EMAIL, 'patch', `/admin/fiscal/companies/${COMPANY}/regime`).send({ regime: 1 }).expect(200);
    await as(ADMIN_EMAIL, 'patch', `/admin/fiscal/branches/${BRANCH_SUL}/state-registration`).send({ stateRegistration: '110042490114' }).expect(200);
  });

  afterAll(async () => {
    await setNfce({ enabled: false, environment: 2, contingencyHours: 24 });
    await app.close();
  });

  it('liga a NFC-e só com permissão e valores válidos', async () => {
    expect(codeOf(await setNfce({ enabled: true, environment: 2, contingencyHours: 24 }, OPERATOR_EMAIL).expect(403))).toBe('FA002');
    expect(codeOf(await setNfce({ enabled: 'sim', environment: 2, contingencyHours: 24 }).expect(422))).toBe('FA728');
    expect(codeOf(await setNfce({ enabled: true, environment: 5, contingencyHours: 24 }).expect(422))).toBe('FA728');
    expect(codeOf(await setNfce({ enabled: true, environment: 2, contingencyHours: 1.5 }).expect(422))).toBe('FA728');

    await as(ADMIN_EMAIL, 'post', `/admin/fiscal/branches/${BRANCH_SUL}/certificate`)
      .send({ file: buildPfx({ password: PFX_PASSWORD }).toString('base64'), password: PFX_PASSWORD }).expect(201);
    await as(ADMIN_EMAIL, 'put', `/admin/fiscal/branches/${BRANCH_SUL}/csc`).send({ cscId: '000002', token: 'CSCDANFCEDOTESTE0001' }).expect(200);
    await setNfce({ enabled: true, environment: 2, contingencyHours: 24 }).expect(200);
    expect(await nfceRow()).toMatchObject({ enabled: true, environment: 2, has_certificate: true, has_csc: true, can_manage: true });
  });

  it('o caixa registra a chave assinada e recebe o certificado e o CSC que só ele abre', async () => {
    const own = fiscalKey();
    // Sem chave registrada não há entrega.
    expect(codeOf(await asTerminal('post', '/terminals/nfce/credentials').expect(422))).toBe('FA731');
    // Assinatura de outra chave, ou de outro terminal, não vale.
    const other = generateKeyPairSync('ed25519').privateKey;
    const forged = sign(null, Buffer.from(fiscalKeyMessage(terminalId, own.publicKey)), other).toString('base64url');
    expect(codeOf(await asTerminal('post', '/terminals/nfce/key').send({ publicKey: own.publicKey, signature: forged }).expect(422))).toBe('FA731');
    const wrongTerminal = signText(fiscalKeyMessage(BRANCH_SUL, own.publicKey));
    expect(codeOf(await asTerminal('post', '/terminals/nfce/key').send({ publicKey: own.publicKey, signature: wrongTerminal }).expect(422))).toBe('FA731');
    await request(server()).post('/terminals/nfce/key').set('X-Forwarded-For', ip).send({ publicKey: own.publicKey }).expect(401);

    await asTerminal('post', '/terminals/nfce/key')
      .send({ publicKey: own.publicKey, signature: signText(fiscalKeyMessage(terminalId, own.publicKey)) }).expect(200);
    const delivered = (await asTerminal('post', '/terminals/nfce/credentials').expect(200)).body as {
      credentialVersion: string; validTo: string; envelope: CredentialEnvelope;
    };
    expect(delivered.credentialVersion).toMatch(/^[0-9a-f-]{36}:[0-9a-f-]{36}$/);
    expect(JSON.stringify(delivered)).not.toContain('CSCDANFCE');

    const plain = JSON.parse(openForTerminal(
      delivered.envelope, own.seed, envelopeContext(terminalId, delivered.credentialVersion),
    ).toString('utf8')) as Json;
    expect(plain).toMatchObject({ credentialVersion: delivered.credentialVersion, cscId: expect.stringMatching(/^\d{1,6}$/) });
    expect(plain.csc).toEqual(expect.any(String));
    // A chave assina e o certificado da entrega confere a assinatura.
    const signature = sign('sha1', Buffer.from('nota'), createPrivateKey(plain.privateKey as string));
    expect(verify('sha1', Buffer.from('nota'), new X509Certificate(plain.certificate as string).publicKey, signature)).toBe(true);
    // Outra chave não abre.
    expect(() => openForTerminal(delivered.envelope, fiscalKey().seed, envelopeContext(terminalId, delivered.credentialVersion))).toThrow();
    expect((await nfceRow())!.terminals_ready).toBeGreaterThanOrEqual(1);
  });

  it('filial desligada não entrega', async () => {
    await setNfce({ enabled: false, environment: 2, contingencyHours: 24 }).expect(200);
    expect(codeOf(await asTerminal('post', '/terminals/nfce/credentials').expect(409))).toBe('FA730');
  });
});
