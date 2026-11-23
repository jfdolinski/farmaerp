// Descida para o PDV contra o banco real: terminal pareado de verdade, carga e incremental.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { generateKeyPairSync, randomInt, sign } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { challengeMessage, pairingProofMessage } from './../src/terminals/terminal-crypto.js';

const ADMIN_EMAIL = 'admin@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('descida para o PDV contra o banco real', () => {
  let app: INestApplication<App>;
  let session: string;
  let terminalId: string;
  let token: string;
  let ip: string;

  const server = () => app.getHttpServer();
  const admin = (method: 'get' | 'post', path: string) =>
    request(server())[method](`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${session}`);
  const pull = (body: Json, bearer = token) =>
    request(server())
      .post('/terminals/sync/pull')
      .set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${bearer}`)
      .set('Accept-Encoding', 'gzip')
      .send(body);

  /** A janela inteira, pacote por pacote. */
  async function pullAll(cursor: string | null) {
    const items: Json[] = [];
    let page = (await pull({ cursor }).expect(200)).body as Json;
    const until = page.until as string;
    items.push(...page.items);
    while (page.next) {
      page = (await pull({ cursor, until, after: page.next }).expect(200)).body as Json;
      items.push(...page.items);
    }
    return { until, items, find: (type: string, id: string) => items.find((i) => i.type === type && i.id === id) };
  }

  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() }))))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;

    session = (
      (await request(server()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email: ADMIN_EMAIL, password: DEV_PASSWORD }).expect(200)).body as Json
    ).token as string;

    // Terminal de verdade: chave no aparelho, código, aprovação e token.
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const key = publicKey.export({ format: 'jwk' }).x!;
    const signText = (message: string) => sign(null, Buffer.from(message), privateKey).toString('base64url');
    const pairing = (await request(server()).post('/terminals/pairing/requests').set('X-Forwarded-For', ip).send({
      publicKey: key, signature: signText(pairingProofMessage(key)), platform: 'windows',
      deviceName: 'CAIXA-SYNC', appVersion: '0.1.0', keyStorage: 'system',
    }).expect(201)).body as Json;
    terminalId = ((await admin('post', `/pairing/${pairing.code}/claim`).send({ branchId: BRANCH_CENTRO }).expect(201)).body as Json)
      .terminalId as string;
    await admin('post', `/terminals/${terminalId}/approve`).send({ name: `Caixa sync ${Date.now()}`, profile: 'cashier' }).expect(200);
    const challenge = ((await request(server()).post('/terminals/auth/challenge').set('X-Forwarded-For', ip)
      .send({ terminalId }).expect(200)).body as Json).challenge as string;
    token = ((await request(server()).post('/terminals/auth/token').set('X-Forwarded-For', ip)
      .send({ challenge, signature: signText(challengeMessage(challenge)) }).expect(200)).body as Json).accessToken as string;
  });

  afterAll(async () => {
    await app.close();
  });

  it('carga inicial compactada, com a filial, os usuários e os produtos com preço e estoque', async () => {
    const response = await pull({}).expect(200);
    expect(response.headers['content-encoding']).toBe('gzip');
    expect(response.headers['cache-control']).toBe('no-store');
    const page = response.body as Json;
    expect(page).toMatchObject({ format: 1, until: expect.stringMatching(/^\d+$/) });
    expect(page.items[0]).toMatchObject({ type: 'fiscal', id: BRANCH_CENTRO });
    expect(page.items[0].data.series.map((s: Json) => s.model)).toEqual(['55', '65']);

    const load = await pullAll(null);
    expect(load.find('product', DIPIRONA)?.data).toMatchObject({ price: 12.9, status: 'active' });
    expect(load.find('stock', DIPIRONA)?.data).toHaveProperty('quantity');
    expect(load.items.some((i) => i.type === 'user' && i.data.permissions.length > 0)).toBe(true);

    // Sem gzip no pedido, a resposta vem sem compactar.
    const plain = await request(server()).post('/terminals/sync/pull').set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${token}`).set('Accept-Encoding', 'identity').send({}).expect(200);
    expect(plain.headers['content-encoding']).toBeUndefined();
    expect((plain.body as Json).items[0].type).toBe('fiscal');
  });

  it('incremental: só o que mudou depois do cursor', async () => {
    const { until } = await pullAll(null);
    expect((await pullAll(until)).items).toEqual([]);

    await admin('post', `/products/${DIPIRONA}/prices`)
      .send({ branchId: BRANCH_CENTRO, price: 11.5, reason: 'Teste da descida' }).expect(201);
    const step = await pullAll(until);
    expect(step.find('product', DIPIRONA)?.data).toMatchObject({ price: 11.5 });
    expect(step.items.every((i) => ['product', 'stock'].includes(i.type as string))).toBe(true);

    await admin('post', `/products/${DIPIRONA}/prices`).send({ branchId: BRANCH_CENTRO, price: null }).expect(201);
    expect((await pullAll(step.until)).find('product', DIPIRONA)?.data).toMatchObject({ price: 12.9 });
  });

  it('recusa pedido fora do formato, sem token e de terminal bloqueado', async () => {
    for (const body of [{ cursor: 'abc' }, { cursor: 12 }, { until: '1', after: '9:x' }, { cursor: 'x'.repeat(65) }]) {
      expect((await pull(body).expect(422)).body).toMatchObject({ code: 'FA956' });
    }
    expect((await pull({}, 'token-falso').expect(401)).body).toMatchObject({ code: 'FA306' });

    await admin('post', `/terminals/${terminalId}/block`).send({ reason: 'Teste da descida' }).expect(200);
    expect((await pull({}).expect(403)).body).toMatchObject({ code: 'FA304' });
    await admin('post', `/terminals/${terminalId}/revoke`).send({ reason: 'Fim do teste da descida' }).expect(200);
  });
});
