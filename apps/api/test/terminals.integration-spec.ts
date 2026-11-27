// Fluxo completo do terminal contra o banco real, com chaves Ed25519 de verdade.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { generateKeyPairSync, randomInt, sign } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';
import {
  challengeMessage,
  issueChallenge,
  pairingProofMessage,
} from './../src/terminals/terminal-crypto.js';

const ADMIN = '019a0000-0000-7000-8000-000000000008';
const ADMIN_EMAIL = 'admin@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const MANAGER_EMAIL = 'gerente@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const BRANCH = '019a0000-0000-7000-8000-000000000005';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

function newDevice() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const signText = (message: string) =>
    sign(null, Buffer.from(message), privateKey).toString('base64url');
  return { publicKey: publicKey.export({ format: 'jwk' }).x!, sign: signText };
}
type Device = ReturnType<typeof newDevice>;

describe('terminais contra o banco real', () => {
  let app: INestApplication<App>;
  let logs: string[] = [];
  let ip: string;
  let nameCounter = 0;
  const sessions = new Map<string, string>();

  // Cada teste usa outro IP, para o limite de tentativas não misturar os testes.
  const post = (path: string) =>
    request(app.getHttpServer()).post(path).set('X-Forwarded-For', ip);
  const admin = (method: 'get' | 'post', path: string, email = ADMIN_EMAIL) =>
    request(app.getHttpServer())
      [method](`/admin${path}`)
      .set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${sessions.get(email)}`);

  const pairingBody = (device: Device) => ({
    publicKey: device.publicKey,
    signature: device.sign(pairingProofMessage(device.publicKey)),
    platform: 'windows',
    deviceName: 'CAIXA-TESTE',
    appVersion: '0.1.0',
    keyStorage: 'system',
  });

  async function pair(device: Device) {
    const response = await post('/terminals/pairing/requests')
      .send(pairingBody(device))
      .expect(201);
    return response.body as Json;
  }

  async function claim(device: Device) {
    const pairing = await pair(device);
    const response = await admin('post', `/pairing/${pairing.code}/claim`)
      .send({ branchId: BRANCH })
      .expect(201);
    return { ...pairing, terminalId: (response.body as Json).terminalId as string };
  }

  async function approved(device: Device) {
    const claimed = await claim(device);
    nameCounter += 1;
    await admin('post', `/terminals/${claimed.terminalId}/approve`)
      .send({ name: `Caixa ${Date.now()}-${nameCounter}`, profile: 'cashier' })
      .expect(200);
    return claimed;
  }

  async function login(device: Device, terminalId: string) {
    const challenge = await post('/terminals/auth/challenge')
      .send({ terminalId })
      .expect(200);
    const value = (challenge.body as Json).challenge as string;
    const token = await post('/terminals/auth/token')
      .send({ challenge: value, signature: device.sign(challengeMessage(value)) })
      .expect(200);
    return (token.body as Json).accessToken as string;
  }

  const heartbeat = (token: string) =>
    post('/terminals/heartbeat')
      .set('Authorization', `Bearer ${token}`)
      .send({ appVersion: '0.2.0' });

  const expectCode = (response: request.Response, code: string) =>
    expect((response.body as Json).code).toBe(code);

  beforeAll(async () => {
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        logs.push(chunk.toString());
        callback();
      },
    });
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(destination)))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();

    for (const email of [ADMIN_EMAIL, OPERATOR_EMAIL, MANAGER_EMAIL]) {
      const response = await request(app.getHttpServer())
        .post('/auth/login')
        .set('X-Forwarded-For', '10.255.255.254')
        .send({ email, password: DEV_PASSWORD })
        .expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
  });

  beforeEach(() => {
    logs = [];
    ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  });

  afterAll(async () => {
    await app.close();
  });

  it('percorre o fluxo inteiro, do código à revogação', async () => {
    const device = newDevice();

    // 1. O aparelho abre a solicitação.
    const pairing = await pair(device);
    expect(pairing.code).toMatch(/^[A-HJ-NP-Z2-9]{8}$/);
    const status = () =>
      post('/terminals/pairing/status')
        .send({ requestId: pairing.requestId, publicKey: device.publicKey })
        .expect(200);
    expect((await status()).body).toMatchObject({ status: 'waiting' });

    // 2. O admin confere o aparelho e aceita o código.
    const found = await admin('get', `/pairing/${pairing.code}`).expect(200);
    expect(found.body).toMatchObject({
      platform: 'windows',
      deviceName: 'CAIXA-TESTE',
      keyStorage: 'system',
    });
    const claimed = await admin('post', `/pairing/${pairing.code}/claim`)
      .send({ branchId: BRANCH })
      .expect(201);
    const { terminalId } = claimed.body as { terminalId: string };
    expect((await status()).body).toMatchObject({
      status: 'claimed',
      terminalId,
      terminalStatus: 'pending',
    });

    // Pendente ainda não autentica.
    expectCode(
      await post('/terminals/auth/challenge').send({ terminalId }).expect(403),
      'FA307',
    );

    // 3. O admin aprova, e o aparelho autentica e envia sinal de vida.
    await admin('post', `/terminals/${terminalId}/approve`)
      .send({ name: `Caixa fluxo ${Date.now()}`, profile: 'cashier' })
      .expect(200);
    expect((await status()).body).toMatchObject({ terminalStatus: 'active' });

    const approvedStatus = (await status()).body as Json;
    expect(approvedStatus.terminalNumber).toBeGreaterThan(0);

    const token = await login(device, terminalId);
    const beat = await heartbeat(token).expect(200);
    expect(beat.body).toEqual({
      status: 'active',
      terminalNumber: approvedStatus.terminalNumber,
    });

    const monitor = await admin('get', '/terminals').expect(200);
    expect(
      (monitor.body as Json[]).find((terminal) => terminal.id === terminalId),
    ).toMatchObject({
      status: 'active',
      number: approvedStatus.terminalNumber,
      connectivity: 'online',
      app_version: '0.2.0',
      device_name: 'CAIXA-TESTE',
      last_sync_at: null,
    });

    // 4. O bloqueio vale na hora, mesmo com o token ainda válido.
    await admin('post', `/terminals/${terminalId}/block`)
      .send({ reason: 'Suspeita de fraude' })
      .expect(200);
    expectCode(await heartbeat(token).expect(403), 'FA304');
    expectCode(
      await post('/terminals/auth/challenge').send({ terminalId }).expect(403),
      'FA304',
    );

    // 5. O desbloqueio devolve o acesso.
    await admin('post', `/terminals/${terminalId}/unblock`).send({}).expect(200);
    await heartbeat(token).expect(200);

    // 6. A revogação é definitiva, e a mesma chave não pareia de novo.
    await admin('post', `/terminals/${terminalId}/revoke`)
      .send({ reason: 'Aparelho roubado' })
      .expect(200);
    expectCode(await heartbeat(token).expect(403), 'FA305');
    expectCode(
      await post('/terminals/pairing/requests')
        .send(pairingBody(device))
        .expect(409),
      'FA220',
    );
    expectCode(
      await admin('post', `/terminals/${terminalId}/unblock`).send({}).expect(409),
      'FA303',
    );

    // 7. Com chave nova, o aparelho consegue parear.
    await pair(newDevice());

    // 8. O histórico guarda cada passo, com autor e motivo.
    const events = await admin('get', `/terminals/${terminalId}/events`).expect(200);
    expect(
      (events.body as Json[]).map((event) => [event.event_type, event.reason]),
    ).toEqual([
      ['requested', null],
      ['approved', null],
      ['blocked', 'Suspeita de fraude'],
      ['unblocked', null],
      ['revoked', 'Aparelho roubado'],
    ]);
    expect((events.body as Json[])[2].updated_by).toBe(ADMIN);
  });

  describe('solicitação', () => {
    it('rejeita quem não prova ter a chave', async () => {
      const device = newDevice();
      const other = newDevice();
      const response = await post('/terminals/pairing/requests')
        .send({
          ...pairingBody(device),
          signature: other.sign(pairingProofMessage(device.publicKey)),
        })
        .expect(422);
      expectCode(response, 'FA308');
    });

    it('rejeita chave malformada', async () => {
      const device = newDevice();
      const response = await post('/terminals/pairing/requests')
        .send({ ...pairingBody(device), publicKey: 'curta' })
        .expect(422);
      expectCode(response, 'FA308');
    });

    it.each([
      ['plataforma desconhecida', { platform: 'macos' }, 'FA310'],
      ['sem nome do aparelho', { deviceName: undefined }, 'FA005'],
      ['armazenamento desconhecido', { keyStorage: 'nuvem' }, 'FA310'],
    ])('rejeita %s', async (_label, change, code) => {
      const response = await post('/terminals/pairing/requests')
        .send({ ...pairingBody(newDevice()), ...change })
        .expect(422);
      expectCode(response, code);
    });

    it('limita as tentativas por IP com mensagem clara', async () => {
      for (let i = 0; i < 10; i += 1) {
        await pair(newDevice());
      }
      const response = await post('/terminals/pairing/requests')
        .send(pairingBody(newDevice()))
        .expect(429);
      expectCode(response, 'FA009');
      expect((response.body as Json).retryable).toBe(true);
    });

    it('a consulta exige a chave certa', async () => {
      const pairing = await pair(newDevice());
      const response = await post('/terminals/pairing/status')
        .send({ requestId: pairing.requestId, publicKey: newDevice().publicKey })
        .expect(404);
      expectCode(response, 'FA301');
    });
  });

  describe('autenticação', () => {
    it('rejeita assinatura de outra chave', async () => {
      const device = newDevice();
      const { terminalId } = await approved(device);
      const challenge = await post('/terminals/auth/challenge')
        .send({ terminalId })
        .expect(200);
      const value = (challenge.body as Json).challenge as string;

      const response = await post('/terminals/auth/token')
        .send({
          challenge: value,
          signature: newDevice().sign(challengeMessage(value)),
        })
        .expect(401);
      expectCode(response, 'FA306');
    });

    it('rejeita o desafio de outro terminal assinado com a própria chave', async () => {
      const deviceA = newDevice();
      const deviceB = newDevice();
      const a = await approved(deviceA);
      await approved(deviceB);
      const challenge = await post('/terminals/auth/challenge')
        .send({ terminalId: a.terminalId })
        .expect(200);
      const value = (challenge.body as Json).challenge as string;

      await post('/terminals/auth/token')
        .send({ challenge: value, signature: deviceB.sign(challengeMessage(value)) })
        .expect(401);
    });

    it('rejeita desafio vencido, mesmo com a assinatura certa', async () => {
      const device = newDevice();
      const { terminalId } = await approved(device);
      const { value } = issueChallenge(terminalId, Date.now() - 61_000);

      await post('/terminals/auth/token')
        .send({ challenge: value, signature: device.sign(challengeMessage(value)) })
        .expect(401);
    });

    it('terminal inexistente não recebe desafio', async () => {
      const response = await post('/terminals/auth/challenge')
        .send({ terminalId: '019a0000-0000-7000-8000-00000000dead' })
        .expect(401);
      expectCode(response, 'FA306');
    });

    it.each([
      ['sem token', undefined],
      ['token inválido', 'Bearer abc.def'],
      ['outro esquema', 'Basic abc'],
    ])('sinal de vida %s é recusado', async (_label, header) => {
      const call = post('/terminals/heartbeat');
      if (header) call.set('Authorization', header);
      expectCode(await call.send({}).expect(401), 'FA306');
    });

    it('um desafio não serve como token de acesso', async () => {
      const device = newDevice();
      const { terminalId } = await approved(device);
      const challenge = await post('/terminals/auth/challenge')
        .send({ terminalId })
        .expect(200);
      await heartbeat((challenge.body as Json).challenge as string).expect(401);
    });

    it('o log não recebe token nem assinatura', async () => {
      const device = newDevice();
      const { terminalId } = await approved(device);
      const token = await login(device, terminalId);
      await heartbeat(token).expect(200);

      const joined = logs.join('');
      expect(joined).toContain(terminalId);
      expect(joined).not.toContain(token);
    });

    it('o log registra o terminal do sinal de vida', async () => {
      const device = newDevice();
      const { terminalId } = await approved(device);
      const token = await login(device, terminalId);
      logs = [];
      await heartbeat(token).expect(200);
      expect(logs.join('')).toContain(`"terminal_id":"${terminalId}"`);
    });
  });

  describe('sinal de vida', () => {
    it.each([
      ['pendências negativas', { outboxPending: -1 }],
      ['pendências em texto', { outboxPending: '3' }],
      ['data inválida', { lastSyncAt: 'ontem' }],
    ])('rejeita %s', async (_label, body) => {
      const device = newDevice();
      const { terminalId } = await approved(device);
      const token = await login(device, terminalId);
      const response = await post('/terminals/heartbeat')
        .set('Authorization', `Bearer ${token}`)
        .send(body)
        .expect(422);
      expectCode(response, 'FA005');
    });
  });

  describe('administração', () => {
    it('sem sessão é recusado', async () => {
      const response = await request(app.getHttpServer())
        .get('/admin/terminals')
        .set('X-Forwarded-For', ip)
        .expect(401);
      expectCode(response, 'FA402');
    });

    it('o banco barra o usuário sem permissão', async () => {
      const { code } = await pair(newDevice());
      expectCode(await admin('get', `/pairing/${code}`, OPERATOR_EMAIL).expect(403), 'FA002');
    });

    it('o operador de caixa não vê terminais', async () => {
      const response = await admin('get', '/terminals', OPERATOR_EMAIL).expect(200);
      expect(response.body).toEqual([]);
    });

    it('o gerente só vê os terminais da própria filial', async () => {
      const response = await admin('get', '/terminals', MANAGER_EMAIL).expect(200);
      const branches = new Set((response.body as Json[]).map((t) => t.branch_id));
      expect([...branches]).toEqual([BRANCH]);
    });

    it('lista as filiais para a escolha', async () => {
      const response = await admin('get', '/branches').expect(200);
      expect((response.body as Json[]).map((branch) => branch.name)).toEqual(
        expect.arrayContaining(['Loja Centro', 'Loja Sul']),
      );
    });

    it('bloquear sem motivo informa o erro certo', async () => {
      const { terminalId } = await approved(newDevice());
      const response = await admin('post', `/terminals/${terminalId}/block`)
        .send({})
        .expect(422);
      expectCode(response, 'FA302');
    });

    it('vendedor padrão: as opções, escolher, aparecer no monitor e tirar', async () => {
      const { terminalId } = await approved(newDevice());
      const options = (await admin('get', '/terminals/seller-options').expect(200)).body as Json[];
      const choice = options.find((row) => row.branch_id === BRANCH && row.user_id === ADMIN);
      expect(choice).toMatchObject({ code: expect.any(Number), name: expect.any(String) });
      await admin('post', `/terminals/${terminalId}/fixed-seller`).send({ userId: ADMIN }).expect(200);
      const monitor = ((await admin('get', '/terminals').expect(200)).body as Json[]).find((row) => row.id === terminalId);
      expect(monitor).toMatchObject({ fixed_seller_id: ADMIN, fixed_seller_name: `${choice!.code} · ${choice!.name}` });
      // O gerente não aprova terminais: nem opções nem mudança.
      expect((await admin('get', '/terminals/seller-options', MANAGER_EMAIL).expect(200)).body).toEqual([]);
      expectCode(await admin('post', `/terminals/${terminalId}/fixed-seller`, MANAGER_EMAIL).send({ userId: null }).expect(403), 'FA002');
      expectCode(await admin('post', `/terminals/${terminalId}/fixed-seller`).send({ userId: 'x' }).expect(422), 'FA005');
      await admin('post', `/terminals/${terminalId}/fixed-seller`).send({ userId: null }).expect(200);
      const cleared = ((await admin('get', '/terminals').expect(200)).body as Json[]).find((row) => row.id === terminalId);
      expect(cleared).toMatchObject({ fixed_seller_id: null, fixed_seller_name: null });
    });

    it('código errado informa o erro certo', async () => {
      expectCode(await admin('get', '/pairing/AAAAAAAA').expect(404), 'FA301');
    });

    it('limita as tentativas de código por IP', async () => {
      for (let i = 0; i < 20; i += 1) {
        await admin('get', '/pairing/AAAAAAAA').expect(404);
      }
      expectCode(await admin('get', '/pairing/AAAAAAAA').expect(429), 'FA009');
    });

    it('identificador malformado não vira erro técnico', async () => {
      const response = await admin('post', '/terminals/abc/block')
        .send({ reason: 'x' })
        .expect(422);
      expectCode(response, 'FA005');
    });
  });
});
