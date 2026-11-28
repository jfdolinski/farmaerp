// PBM pela central contra o banco real, com o programa de teste: configuração na retaguarda e as
// duas fases no caixa (autoriza, confirma ou desfaz). Nenhum programa de verdade é chamado.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { generateKeyPairSync, randomInt, randomUUID, sign } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { challengeMessage, pairingProofMessage } from './../src/terminals/terminal-crypto.js';

const ADMIN_EMAIL = 'admin@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';
const OTHER = '019a0000-0000-7000-8000-000000000033';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('PBM contra o banco real', () => {
  let app: INestApplication<App>;
  let token: string;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const server = () => app.getHttpServer();
  const admin = (method: 'get' | 'post' | 'patch', path: string, email = ADMIN_EMAIL) =>
    request(server())[method](`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const terminal = (method: 'get' | 'post', path: string) =>
    request(server())[method](`/terminals/pbm${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  beforeAll(async () => {
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
    // Terminal de verdade na filial Centro.
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const key = publicKey.export({ format: 'jwk' }).x!;
    const signText = (message: string) => sign(null, Buffer.from(message), privateKey).toString('base64url');
    const pairing = (await request(server()).post('/terminals/pairing/requests').set('X-Forwarded-For', ip).send({
      publicKey: key, signature: signText(pairingProofMessage(key)), platform: 'windows', deviceName: 'CAIXA-PBM', appVersion: '0.2.30', keyStorage: 'system',
    }).expect(201)).body as Json;
    const terminalId = ((await admin('post', `/pairing/${pairing.code}/claim`).send({ branchId: CENTRO }).expect(201)).body as Json).terminalId as string;
    await admin('post', `/terminals/${terminalId}/approve`).send({ name: `Caixa PBM ${Date.now()}`, profile: 'cashier' }).expect(200);
    const challenge = ((await request(server()).post('/terminals/auth/challenge').set('X-Forwarded-For', ip).send({ terminalId }).expect(200)).body as Json).challenge as string;
    token = ((await request(server()).post('/terminals/auth/token').set('X-Forwarded-For', ip)
      .send({ challenge, signature: signText(challengeMessage(challenge)) }).expect(200)).body as Json).accessToken as string;
  });

  afterAll(async () => {
    await app.close();
  });

  it('retaguarda: cria o programa, liga na filial, guarda os dados de acesso sem devolver e mantém as regras; quem não tem a permissão fica de fora', async () => {
    expect(codeOf(await admin('get', '/pbm/programs', OPERATOR_EMAIL).expect(403))).toBe('FA002');
    expect(codeOf(await admin('post', '/pbm/programs').send({ name: '' }).expect(422))).toBe('FA005');
    const name = `Programa de teste ${randomInt(1e9)}`;
    const { id } = (await admin('post', '/pbm/programs').send({ name }).expect(201)).body as Json;
    expect(codeOf(await admin('post', '/pbm/programs').send({ name }).expect(409))).toBe('FA799');
    await admin('post', `/pbm/programs/${id}/branches/${CENTRO}`).send({ active: true }).expect(200);
    await admin('post', `/pbm/programs/${id}/branches/${CENTRO}/credentials`).send({ credentials: { usuario: 'loja-teste', senha: 'segredo-de-teste' } }).expect(200);
    expect(codeOf(await admin('post', `/pbm/programs/${id}/branches/${CENTRO}/credentials`).send({ credentials: { 'campo inválido': 'x' } }).expect(422))).toBe('FA005');
    await admin('post', `/pbm/programs/${id}/rules`).send({ productId: DIPIRONA, percent: 40 }).expect(200);
    // Pela tela: o código de barras do produto; produto que não existe, FA004.
    await admin('post', `/pbm/programs/${id}/rules`).send({ productLookup: '7890000000055', percent: 15 }).expect(200);
    expect(codeOf(await admin('post', `/pbm/programs/${id}/rules`).send({ productLookup: '0000000000000', percent: 15 }).expect(422))).toBe('FA004');
    await admin('post', `/pbm/programs/${id}/rules`).send({ productId: OTHER, percent: null }).expect(200);
    expect(codeOf(await admin('post', `/pbm/programs/${id}/rules`).send({ productId: DIPIRONA, percent: 150 }).expect(422))).toBe('FA798');
    const listed = ((await admin('get', '/pbm/programs').expect(200)).body as Json[]).find((program) => program.id === id)!;
    expect(listed).toMatchObject({ name, connector: 'test', active: true, rules: [{ product_id: DIPIRONA, discount_percent: 40 }] });
    expect((listed.branches as Json[]).find((row) => row.branch_id === CENTRO)).toMatchObject({ active: true, credentials_set_at: expect.any(String) });
    expect(JSON.stringify(listed)).not.toContain('segredo-de-teste');
    await admin('patch', `/pbm/programs/${id}`).send({ active: false }).expect(200);
    expect(((await terminal('get', '/programs').expect(200)).body as Json[]).map((p) => p.id)).not.toContain(id);
  });

  it('caixa: autoriza só os itens do programa, confirma com a venda (repetido também) e desfaz a que não virou venda; o relatório mostra mascarado', async () => {
    const { id: programId } = (await admin('post', '/pbm/programs').send({ name: `Programa caixa ${randomInt(1e9)}` }).expect(201)).body as Json;
    // Desligado na filial: o caixa não usa.
    const off = await terminal('post', '/authorize').send({ programId, beneficiary: '529.982.247-25', items: [{ productId: DIPIRONA, quantity: 1, unitPrice: 12.9 }] }).expect(409);
    expect(codeOf(off)).toBe('FA793');
    await admin('post', `/pbm/programs/${programId}/branches/${CENTRO}`).send({ active: true }).expect(200);
    await admin('post', `/pbm/programs/${programId}/rules`).send({ productId: DIPIRONA, percent: 40 }).expect(200);
    expect(((await terminal('get', '/programs').expect(200)).body as Json[]).map((p) => p.id)).toContain(programId);

    const authorize = (beneficiary: string, items: Json[]) => terminal('post', '/authorize').send({ programId, beneficiary, items });
    const cart = [{ productId: DIPIRONA, quantity: 2, unitPrice: 12.9 }, { productId: OTHER, quantity: 1, unitPrice: 5 }];
    expect(codeOf(await authorize('11144477730', cart).expect(422))).toBe('FA794');
    expect(codeOf(await authorize('FORA-1234', cart).expect(503))).toBe('FA797');
    expect(codeOf(await authorize('52998224725', [{ productId: OTHER, quantity: 1, unitPrice: 5 }]).expect(422))).toBe('FA796');
    expect(codeOf(await authorize('52998224725', [{ productId: DIPIRONA, quantity: 1, unitPrice: 0 }]).expect(422))).toBe('FA005');

    const done = (await authorize('529.982.247-25', cart).expect(200)).body as Json;
    expect(done).toMatchObject({
      id: expect.any(String), list_total: 25.8, pbm_total: 15.48, benefit: 10.32,
      items: [{ productId: DIPIRONA, quantity: 2, listPrice: 12.9, pbmPrice: 7.74 }],
    });
    const saleId = randomUUID();
    expect((await terminal('post', `/${done.id}/confirm`).send({ saleId }).expect(200)).body).toEqual({ status: 'confirmed' });
    expect((await terminal('post', `/${done.id}/confirm`).send({ saleId }).expect(200)).body).toEqual({ status: 'confirmed' });
    expect(codeOf(await terminal('post', `/${done.id}/confirm`).send({ saleId: randomUUID() }).expect(409))).toBe('FA795');
    expect(codeOf(await terminal('post', `/${done.id}/undo`).send({}).expect(409))).toBe('FA795');

    const dropped = (await authorize('52998224725', cart).expect(200)).body as Json;
    expect((await terminal('post', `/${dropped.id}/undo`).send({ reason: 'Cliente desistiu' }).expect(200)).body).toEqual({ status: 'undone' });
    expect((await terminal('post', `/${dropped.id}/undo`).send({}).expect(200)).body).toEqual({ status: 'undone' });
    expect(codeOf(await terminal('post', `/${dropped.id}/confirm`).send({ saleId: randomUUID() }).expect(409))).toBe('FA795');

    const report = (await admin('get', `/pbm/authorizations?branch=${CENTRO}`).expect(200)).body as Json[];
    expect(report.find((row) => row.id === done.id)).toMatchObject({ status: 'confirmed', beneficiary: '********725', benefit: 10.32, missing_sale: true });
    expect(report.find((row) => row.id === dropped.id)).toMatchObject({ status: 'undone', undo_reason: 'Cliente desistiu' });
    expect(JSON.stringify(report)).not.toContain('52998224725');
    expect(codeOf(await admin('get', '/pbm/authorizations?from=ontem').expect(422))).toBe('FA005');
  });
});
