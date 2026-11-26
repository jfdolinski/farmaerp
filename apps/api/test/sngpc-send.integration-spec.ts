// Envio do SNGPC pela API contra o banco real e uma Anvisa falsa (servidor HTTP local).
// Usa a Loja Sul do seed de desenvolvimento, com o banco zerado (como no CI).
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomBytes, randomInt } from 'node:crypto';
import { createServer, IncomingMessage, Server } from 'node:http';
import { AddressInfo } from 'node:net';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { SngpcService } from './../src/sngpc/sngpc.service.js';

const ADMIN = 'admin@farmaerp.test';
const PASSWORD = 'farmaerp-dev-123';
const SUL = '019a0000-0000-7000-8000-000000000006';
const CLONAZEPAM = '019a0000-0000-7000-8000-000000000033';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** Anvisa falsa: aceita o usuário "farmaceutico", guarda os envios e responde a situação combinada. */
function fakeAnvisa() {
  const received: { cnpj: string; xml: string; hash: string }[] = [];
  let next: { situacao: string; motivo?: string } = { situacao: 'aceito' };
  const user = (req: IncomingMessage) =>
    Buffer.from((req.headers.authorization ?? '').replace('Basic ', ''), 'base64').toString().split(':')[0];
  const server: Server = createServer((req, res) => {
    if (user(req) !== 'farmaceutico') {
      res.writeHead(401).end();
      return;
    }
    if (req.method === 'POST' && req.url === '/envios') {
      let body = '';
      req.on('data', (chunk: Buffer) => (body += chunk.toString()));
      req.on('end', () => {
        const json = JSON.parse(body) as { cnpj: string; arquivo: string; hash: string };
        received.push({ cnpj: json.cnpj, xml: Buffer.from(json.arquivo, 'base64').toString('utf8'), hash: json.hash });
        res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ protocolo: `P${received.length}` }));
      });
      return;
    }
    if (req.method === 'GET' && req.url?.startsWith('/envios/')) {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(next));
      return;
    }
    res.writeHead(404).end();
  });
  return { server, received, answer: (value: typeof next) => (next = value) };
}

describe('envio do SNGPC contra o banco real e a Anvisa falsa', () => {
  let app: INestApplication<App>;
  let service: SngpcService;
  let token: string;
  let ip: string;
  const anvisa = fakeAnvisa();
  const previous = { ...process.env };
  const call = (method: 'get' | 'post' | 'put' | 'patch', path: string) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);

  beforeAll(async () => {
    await new Promise<void>((resolve) => anvisa.server.listen(0, '127.0.0.1', resolve));
    process.env.SNGPC_LIVE = 'true';
    process.env.SNGPC_URL = `http://127.0.0.1:${(anvisa.server.address() as AddressInfo).port}`;
    process.env.SNGPC_WORKER = 'off';
    process.env.FISCAL_ENCRYPTION_KEY = randomBytes(32).toString('base64');
    const destination = new Writable({ write(_chunk: Buffer, _encoding, callback) { callback(); } });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(destination))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    service = app.get(SngpcService);
    ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
    token = ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
      .send({ email: ADMIN, password: PASSWORD }).expect(200)).body as Json).token as string;
  });

  afterAll(async () => {
    await app.close();
    await new Promise((resolve) => anvisa.server.close(resolve));
    process.env = previous;
  });

  const pending = async () => (await call('get', `/admin/sngpc/branches/${SUL}/movements`).expect(200)).body as Json[];
  const confirmAll = async () => {
    const ids = (await pending()).map((row) => row.id as string);
    if (ids.length === 0) return;
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date());
    await call('post', `/admin/sngpc/branches/${SUL}/confirm`).send({ ids, sendOn: today, password: PASSWORD }).expect(200);
  };
  const submissions = async () => (await call('get', `/admin/sngpc/branches/${SUL}/submissions`).expect(200)).body as Json[];

  it('inventário vai primeiro, com o arquivo guardado; a Anvisa aceita', async () => {
    const batch = `SUL${randomInt(1000, 9999)}`;
    await call('post', `/admin/products/${CLONAZEPAM}/batch-tracking`).send({ branchId: SUL, tracks: true }).expect(200);
    await call('post', '/admin/stock/adjustments').send({
      productLookup: '7890000000055', branchId: SUL, direction: 'in', quantity: 5, batchNumber: batch,
      expiresOn: '2031-01-31', msRegistration: '1000000000004', reason: 'Estoque inicial da Loja Sul',
    }).expect(201);
    await call('post', `/admin/sngpc/branches/${SUL}/open`).expect(200);
    await confirmAll();

    // Sem credencial, nada sai.
    await service.tick();
    expect(anvisa.received).toHaveLength(0);
    expect((await call('get', `/admin/sngpc/branches/${SUL}/send-info`).expect(200)).body).toMatchObject({ credential_at: null });
    expect((await call('put', `/admin/sngpc/branches/${SUL}/credential`).send({ username: '', password: 'x' }).expect(422)).body.code).toBe('FA005');
    await call('put', `/admin/sngpc/branches/${SUL}/credential`).send({ username: 'farmaceutico', password: 'senha-do-sngpc' }).expect(200);
    expect((await call('get', `/admin/sngpc/branches/${SUL}/send-info`).expect(200)).body.credential_at).toEqual(expect.any(String));

    await service.tick();
    expect(anvisa.received).toHaveLength(1);
    expect(anvisa.received[0].cnpj).toBe('11222333000262');
    expect(anvisa.received[0].xml).toContain('<mensagemSNGPCInventario');
    expect(anvisa.received[0].xml).toContain(`<numeroLoteMedicamento>${batch}</numeroLoteMedicamento>`);
    let list = await submissions();
    expect(list[0]).toMatchObject({ kind: 'inventory', status: 'sent', protocol: 'P1', attempts: 1 });
    const file = await call('get', `/admin/sngpc/submissions/${list[0].id}/file`).expect(200);
    expect(file.headers['content-type']).toContain('application/xml');
    expect(file.text).toBe(anvisa.received[0].xml);

    await service.tick();
    list = await submissions();
    expect(list[0]).toMatchObject({ status: 'accepted' });
  });

  it('credencial recusada fica registrada; recusa da Anvisa volta para o farmacêutico', async () => {
    const [stock] = (await call('get', `/admin/sngpc/branches/${SUL}/batches?productId=${CLONAZEPAM}`).expect(200)).body as Json[];
    await call('post', '/admin/stock/losses').send({
      productLookup: '7890000000055', branchId: SUL, quantity: 1, batchNumber: stock.batch_number, reason: 'Frasco quebrado',
    }).expect(201);
    const [loss] = await pending();
    await call('patch', `/admin/sngpc/movements/${loss.id}`).send({ lossReason: 'damage' }).expect(200);
    await confirmAll();

    await call('put', `/admin/sngpc/branches/${SUL}/credential`).send({ username: 'errado', password: 'x' }).expect(200);
    await service.tick();
    expect((await submissions())[0]).toMatchObject({ kind: 'movements', status: 'built', attempts: 1, last_error: expect.stringContaining('FA722') });

    await call('put', `/admin/sngpc/branches/${SUL}/credential`).send({ username: 'farmaceutico', password: 'senha-do-sngpc' }).expect(200);
    anvisa.answer({ situacao: 'recusado', motivo: 'Motivo de perda incompatível' });
    await service.tick();
    expect(anvisa.received.at(-1)?.xml).toContain('<motivoPerda>2</motivoPerda>');
    await service.tick();
    expect((await submissions())[0]).toMatchObject({ status: 'rejected', reject_reason: 'Motivo de perda incompatível' });
    const rejected = (await call('get', `/admin/sngpc/branches/${SUL}/movements?status=rejected`).expect(200)).body as Json[];
    expect(rejected).toEqual([expect.objectContaining({ id: loss.id, status_reason: 'Motivo de perda incompatível' })]);
    await call('post', `/admin/sngpc/movements/${loss.id}/reopen`).expect(200);
    expect((await pending()).map((row) => row.id)).toContain(loss.id);
    anvisa.answer({ situacao: 'aceito' });
  });
});
