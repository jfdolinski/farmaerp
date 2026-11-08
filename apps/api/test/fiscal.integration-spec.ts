// Rotas fiscais contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import pg from 'pg';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { buildPfx } from './fiscal-pfx.js';
import { open } from './../src/fiscal/secret-box.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const COMPANY = '019a0000-0000-7000-8000-000000000002';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const SUL = '019a0000-0000-7000-8000-000000000006';
const PFX_PASSWORD = 'senha-secreta-do-pfx';
const CSC_TOKEN = 'TOKENDECSCDOTESTE123';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch' | 'put';

describe('configuração fiscal contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const logLines: string[] = [];

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const upload = (branch: string, pfx: Buffer, password = PFX_PASSWORD, email = ADMIN) =>
    call('post', `/admin/fiscal/branches/${branch}/certificate`, email).send({ file: pfx.toString('base64'), password });
  const valid = (options = {}) => buildPfx({ password: PFX_PASSWORD, ...options });
  const overview = async (email = ADMIN) => (await call('get', '/admin/fiscal', email).expect(200)).body as Json[];
  const rowOf = async (branch: string, email = ADMIN) => (await overview(email)).find((row) => row.branch_id === branch);

  const stored = async (sql: string, params: unknown[]) => {
    const client = new pg.Client({
      host: process.env.DB_HOST ?? '127.0.0.1',
      port: Number(process.env.DB_PORT ?? 5432),
      user: 'farmaerp_migrator',
      password: process.env.FARMAERP_MIGRATOR_PASSWORD,
      database: process.env.DB_NAME,
    });
    await client.connect();
    try {
      return (await client.query(sql, params)).rows as Json[];
    } finally {
      await client.end();
    }
  };

  beforeAll(async () => {
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        logLines.push(chunk.toString());
        callback();
      },
    });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(destination)))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();

    for (const email of [ADMIN, MANAGER, OPERATOR]) {
      const response = await request(app.getHttpServer())
        .post('/auth/login')
        .set('X-Forwarded-For', newIp())
        .send({ email, password: PASSWORD })
        .expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
  });

  afterAll(async () => {
    await app.close();
  });

  it('sem sessão, responde 401', async () => {
    await request(app.getHttpServer()).get('/admin/fiscal').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('grava regime e inscrição estadual, e recusa valores errados', async () => {
    await call('patch', `/admin/fiscal/companies/${COMPANY}/regime`).send({ regime: 1 }).expect(200);
    expect(codeOf(await call('patch', `/admin/fiscal/companies/${COMPANY}/regime`).send({ regime: 9 }).expect(422))).toBe('FA917');
    expect(codeOf(await call('patch', `/admin/fiscal/companies/${COMPANY}/regime`).send({ regime: '1' }).expect(422))).toBe('FA917');

    await call('patch', `/admin/fiscal/branches/${CENTRO}/state-registration`).send({ stateRegistration: '110.042.490.114' }).expect(200);
    expect(codeOf(await call('patch', `/admin/fiscal/branches/${CENTRO}/state-registration`).send({ stateRegistration: '110.042.490.115' }).expect(422))).toBe('FA908');

    expect(await rowOf(CENTRO)).toMatchObject({ tax_regime: 1, state_registration: '110042490114' });
  });

  it('envia o certificado, guarda criptografado e o conteúdo abre só com o contexto da empresa', async () => {
    const pfx = valid();
    const { body } = await upload(CENTRO, pfx).expect(201);
    expect(body).toMatchObject({ cnpj: '11222333000181', subjectName: 'EMPRESA TESTE:11222333000181' });
    expect(JSON.stringify(body)).not.toContain('encrypted');

    const row = await rowOf(CENTRO);
    expect(row).toMatchObject({ certificate_cnpj: '11222333000181', can_certificate: true, can_manage: true, can_regime: true });
    expect(row?.certificate_days_left).toBeGreaterThan(190);
    expect(JSON.stringify(row)).not.toContain('encrypted');

    const [saved] = await stored(
      'SELECT encrypted_pfx, encrypted_password FROM branch_certificate WHERE branch_id = $1 AND deleted_at IS NULL',
      [CENTRO],
    );
    expect((saved.encrypted_pfx as Buffer).includes(pfx.subarray(0, 32))).toBe(false);
    expect((saved.encrypted_password as Buffer).toString('latin1')).not.toContain(PFX_PASSWORD);
    const context = `certificate:${COMPANY}`;
    expect(open(saved.encrypted_pfx as Buffer, context).equals(pfx)).toBe(true);
    expect(open(saved.encrypted_password as Buffer, context).toString()).toBe(PFX_PASSWORD);
    expect(() => open(saved.encrypted_pfx as Buffer, `certificate:${CENTRO}`)).toThrow();
  });

  it.each([
    ['senha errada', () => upload(CENTRO, valid(), 'errada'), 'FA912'],
    ['arquivo inválido', () => upload(CENTRO, Buffer.from('não é um pfx')), 'FA912'],
    ['outra empresa', () => upload(CENTRO, valid({ commonName: 'OUTRA:33000167000101' })), 'FA913'],
    ['sem CNPJ', () => upload(CENTRO, valid({ commonName: 'PESSOA' })), 'FA913'],
    ['vencido', () => upload(CENTRO, valid({ daysLeft: -1 })), 'FA914'],
  ])('recusa certificado: %s', async (_label, send, code) => {
    expect(codeOf(await send().expect(422))).toBe(code);
  });

  it('recusa corpo sem arquivo, base64 quebrado e arquivo grande demais', async () => {
    const path = `/admin/fiscal/branches/${CENTRO}/certificate`;
    expect(codeOf(await call('post', path).send({ password: 'x' }).expect(422))).toBe('FA912');
    expect(codeOf(await call('post', path).send({ file: '%%%', password: 'x' }).expect(422))).toBe('FA912');
    expect(codeOf(await call('post', path).send({ file: 'A'.repeat(64_001), password: 'x' }).expect(422))).toBe('FA912');
  });

  it('copia o certificado para outra filial da empresa', async () => {
    await upload(CENTRO, valid()).expect(201);
    const { body } = await call('post', `/admin/fiscal/branches/${CENTRO}/certificate/copy`).send({ targets: [SUL] }).expect(200);
    expect(body).toEqual({ copied: 1 });
    const [centro, sul] = [await rowOf(CENTRO), await rowOf(SUL)];
    expect(sul?.certificate_cnpj).toBe(centro?.certificate_cnpj);
    expect(sul?.certificate_valid_to).toBe(centro?.certificate_valid_to);
    expect((await call('post', `/admin/fiscal/branches/${CENTRO}/certificate/copy`).send({ targets: [] }).expect(422)).status).toBe(422);
  });

  it('grava o CSC criptografado com o contexto da filial', async () => {
    await call('put', `/admin/fiscal/branches/${CENTRO}/csc`).send({ cscId: '000001', token: CSC_TOKEN }).expect(200);
    expect(await rowOf(CENTRO)).toMatchObject({ csc_id: '000001' });
    const [saved] = await stored(
      'SELECT encrypted_token FROM branch_csc WHERE branch_id = $1 AND deleted_at IS NULL',
      [CENTRO],
    );
    expect(open(saved.encrypted_token as Buffer, `csc:${CENTRO}`).toString()).toBe(CSC_TOKEN);
    expect(() => open(saved.encrypted_token as Buffer, `csc:${SUL}`)).toThrow();
    for (const body of [{ cscId: 'abc', token: CSC_TOKEN }, { cscId: '1', token: 'com espaço' }, { cscId: '1', token: 'x'.repeat(37) }, { cscId: '1' }]) {
      expect(codeOf(await call('put', `/admin/fiscal/branches/${CENTRO}/csc`).send(body).expect(422))).toBe('FA916');
    }
  });

  it('o Gerente atualiza certificado e CSC, mas não regime nem inscrição', async () => {
    await upload(CENTRO, valid(), PFX_PASSWORD, MANAGER).expect(201);
    await call('put', `/admin/fiscal/branches/${CENTRO}/csc`, MANAGER).send({ cscId: '2', token: CSC_TOKEN }).expect(200);
    expect(codeOf(await call('patch', `/admin/fiscal/companies/${COMPANY}/regime`, MANAGER).send({ regime: 1 }).expect(403))).toBe('FA002');
    expect(codeOf(await call('patch', `/admin/fiscal/branches/${CENTRO}/state-registration`, MANAGER).send({ stateRegistration: '110042490114' }).expect(403))).toBe('FA002');
  });

  it('sem permissão, não vê nada nem envia arquivo', async () => {
    expect(await overview(OPERATOR)).toEqual([]);
    expect(codeOf(await upload(CENTRO, valid(), PFX_PASSWORD, OPERATOR).expect(403))).toBe('FA002');
    expect(codeOf(await upload(CENTRO, Buffer.from('lixo'), 'x', OPERATOR).expect(403))).toBe('FA002');
    expect(codeOf(await call('put', `/admin/fiscal/branches/${CENTRO}/csc`, OPERATOR).send({ cscId: '1', token: 'x' }).expect(403))).toBe('FA002');
  });

  it('sem a chave do servidor, a API segue no ar e o envio avisa com FA915', async () => {
    const saved = process.env.FISCAL_ENCRYPTION_KEY;
    delete process.env.FISCAL_ENCRYPTION_KEY;
    try {
      expect(codeOf(await upload(CENTRO, valid()).expect(503))).toBe('FA915');
      expect(codeOf(await call('put', `/admin/fiscal/branches/${CENTRO}/csc`).send({ cscId: '1', token: CSC_TOKEN }).expect(503))).toBe('FA915');
      await call('get', '/admin/fiscal').expect(200);
    } finally {
      process.env.FISCAL_ENCRYPTION_KEY = saved;
    }
  });

  it('o log não recebe senha, token nem arquivo', () => {
    const log = logLines.join('');
    expect(log.length).toBeGreaterThan(0);
    expect(log).not.toContain(PFX_PASSWORD);
    expect(log).not.toContain(CSC_TOKEN);
  });
});
