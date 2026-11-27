// Cópia do Catálogo externo contra o banco real e um Catálogo falso (HTTP local): cópia com ETag,
// só o que mudou, item que saiu, imagens dos vinculados, consulta na hora e a tela da Plataforma.
// Nada sai para o Catálogo de verdade.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { createServer, IncomingMessage, Server } from 'node:http';
import { AddressInfo } from 'node:net';
import { randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import sharp from 'sharp';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { CatalogClient } from './../src/catalog/catalog-client.js';
import { CatalogSyncService } from './../src/catalog/catalog-sync.service.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const KEY = 'cat_chave_de_teste';
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** GTIN-13 com dígito certo, ao acaso. */
function gtin(): string {
  let base = '789';
  for (let i = 0; i < 9; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

describe('cópia do Catálogo externo contra o banco real', () => {
  let app: INestApplication<App>;
  let catalog: Server;
  let base: string;
  let service: CatalogSyncService;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const requests: { path: string; key: string | undefined; etag: string | undefined }[] = [];
  // O que o Catálogo falso tem.
  let items: Json[] = [];
  let version = 1;
  let png: Buffer;
  const run = randomInt(1e6, 9e6);
  const codes = { dorflex: gtin(), rivotril: gtin(), saiu: gtin(), novo: gtin(), desconhecido: gtin() };

  const admin = (method: 'get' | 'post', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  function answer(req: IncomingMessage): { status: number; body?: unknown; headers?: Record<string, string>; raw?: Buffer } {
    const url = new URL(req.url ?? '/', base);
    const etag = `W/"v${version}"`;
    if (url.pathname === '/api/v1/catalog.json') {
      if (req.headers['if-none-match'] === etag) return { status: 304, headers: { ETag: etag } };
      return { status: 200, body: { generated_at: new Date().toISOString(), total: items.length, items }, headers: { ETag: etag } };
    }
    const barcode = /^\/api\/v1\/barcodes\/(\d+)$/.exec(url.pathname)?.[1];
    if (barcode) {
      const found = items.find((item) => (item.barcodes as Json[]).some((b) => b.code === barcode));
      if (found) return { status: 200, body: found };
      // Produto inativo lá: 404, e não é recriado.
      if (barcode === codes.saiu) return { status: 404, body: { error: 'Código de barras não encontrado' } };
      // Código desconhecido: o Catálogo cria o cadastro provisório e devolve como pendente.
      return { status: 200, body: { id: run + 900, name: `PRODUTO NÃO CADASTRADO ${barcode}`, barcodes: [{ code: barcode }], images: [{ url: `${base}/padrao/10.png`, placeholder: true }], pending: true, active: true } };
    }
    if (url.pathname.startsWith('/files/')) return { status: 200, raw: png, headers: { 'Content-Type': 'image/png' } };
    return { status: 404, body: { error: 'Rota não encontrada' } };
  }

  beforeAll(async () => {
    png = await sharp({ create: { width: 1200, height: 900, channels: 3, background: '#2266aa' } }).png().toBuffer();
    catalog = createServer((req, res) => {
      requests.push({ path: req.url ?? '', key: req.headers['x-api-key'] as string | undefined, etag: req.headers['if-none-match'] as string | undefined });
      const { status, body, headers = {}, raw } = answer(req);
      res.writeHead(status, { ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...headers });
      res.end(raw ?? (body !== undefined ? JSON.stringify(body) : undefined));
    });
    await new Promise<void>((resolve) => catalog.listen(0, '127.0.0.1', resolve));
    base = `http://127.0.0.1:${(catalog.address() as AddressInfo).port}`;
    items = [
      {
        id: run + 1, name: `Dorflex C/10 Comp ${run}`, brand: 'Sanofi', manufacturer: '', anvisa_registry: '1030000850011', med_controlled: '',
        ncm: '30049099', cest: '1300100', actives: [{ name: 'dipirona', concentration: '300 mg' }], barcodes: [{ code: codes.dorflex }],
        images: [{ url: `${base}/files/dorflex.png` }], pending: false, active: true,
      },
      {
        id: run + 2, name: `Rivotril 2mg ${run}`, manufacturer: 'Roche', med_controlled: 'B1', barcodes: [{ code: codes.rivotril }],
        images: [{ url: `${base}/padrao/10.png`, placeholder: true }], pending: false, active: true,
      },
      { id: run + 3, name: `Sai do catálogo ${run}`, barcodes: [{ code: codes.saiu }], images: [], pending: false, active: true },
    ];

    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() })))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    service = app.get(CatalogSyncService);
    for (const email of [ADMIN, MANAGER]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
  });

  afterAll(async () => {
    service.useClient(null);
    await app.close();
    await new Promise((resolve) => catalog.close(resolve));
  });

  it('sem configuração, a Plataforma vê a cópia desligada e "Atualizar agora" avisa', async () => {
    service.useClient(null);
    expect((await admin('get', '/platform/catalog-sync').expect(200)).body).toMatchObject({ configured: false });
    expect(codeOf(await admin('post', '/platform/catalog-sync/run').expect(409))).toBe('FA228');
    expect(codeOf(await admin('get', '/platform/catalog-sync', MANAGER).expect(403))).toBe('FA002');
    expect(codeOf(await admin('post', '/platform/catalog-sync/run', MANAGER).expect(403))).toBe('FA002');
    service.useClient(new CatalogClient({ url: base, key: KEY }));
  });

  it('copia o catálogo com a chave; a busca acha pelo código e pelo nome; a segunda cópia com a mesma ETag não baixa de novo', async () => {
    expect(await service.sync('manual')).toBe('updated');
    expect(requests.at(-1)).toMatchObject({ path: '/api/v1/catalog.json', key: KEY });
    const byCode = (await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[];
    expect(byCode).toHaveLength(1);
    expect(byCode[0]).toMatchObject({ name: `Dorflex C/10 Comp ${run}`, manufacturer: 'Sanofi', active_ingredient: 'dipirona 300 mg', ncm: '30049099', pending: false });
    expect(((await admin('get', `/admin/catalog?q=rivotril ${run}`).expect(200)).body as Json[])[0]).toMatchObject({ controlled_class: 'B1', manufacturer: 'Roche' });

    expect(await service.sync('schedule')).toBe('unchanged');
    expect(requests.at(-1)).toMatchObject({ etag: `W/"v${version}"` });
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status).toMatchObject({ configured: true });
    expect(status.runs[0]).toMatchObject({ status: 'unchanged', trigger: 'schedule' });
    expect(status.runs[1]).toMatchObject({ status: 'updated', trigger: 'manual', changed: 3, failed: 0 });
  });

  it('nova versão: só o que mudou é gravado; o que saiu some da busca', async () => {
    version += 1;
    items = [{ ...items[0], name: `Dorflex C/30 Comp ${run}` }, items[1]];
    expect(await service.sync('schedule')).toBe('updated');
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status.runs[0]).toMatchObject({ status: 'updated', items: 2, changed: 1 });
    expect(status.runs[0].removed).toBeGreaterThanOrEqual(1);
    expect((await admin('get', `/admin/catalog?q=${codes.saiu}`).expect(200)).body).toEqual([]);
    expect(((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])[0].name).toBe(`Dorflex C/30 Comp ${run}`);
  });

  it('Catálogo fora do ar: a cópia fica como falha, sem marcar nada como fora', async () => {
    service.useClient(new CatalogClient({ url: 'http://127.0.0.1:1', key: KEY }));
    expect(await service.sync('manual')).toBe('failed');
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status.runs[0]).toMatchObject({ status: 'failed', message: 'O Catálogo não respondeu.' });
    expect(JSON.stringify(status)).not.toContain(KEY);
    expect(((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])).toHaveLength(1);
    service.useClient(new CatalogClient({ url: base, key: KEY }));
  });

  it('código que a cópia não tem é consultado na hora; desconhecido lá volta pendente e não vincula', async () => {
    version += 1;
    items = [...items, { id: run + 4, name: `Novo depois da cópia ${run}`, barcodes: [{ code: codes.novo }], images: [], pending: false, active: true }];
    const found = (await admin('get', `/admin/catalog?q=${codes.novo}`).expect(200)).body as Json[];
    expect(found).toHaveLength(1);
    expect(found[0]).toMatchObject({ name: `Novo depois da cópia ${run}`, pending: false });
    expect(requests.at(-1)).toMatchObject({ path: `/api/v1/barcodes/${codes.novo}`, key: KEY });

    const unknown = (await admin('get', `/admin/catalog?q=${codes.desconhecido}`).expect(200)).body as Json[];
    expect(unknown).toEqual([expect.objectContaining({ name: `PRODUTO NÃO CADASTRADO ${codes.desconhecido}`, pending: true })]);
    const before = requests.length;
    // Já guardado: não consulta de novo.
    await admin('get', `/admin/catalog?q=${codes.desconhecido}`).expect(200);
    expect(requests.length).toBe(before);
    const refused = await admin('post', '/admin/products').send({ displayName: `Teste pendente ${run}`, barcode: gtin(), catalogProductId: unknown[0].id }).expect(409);
    expect(codeOf(refused)).toBe('FA226');
    // Nome não é consultado fora (só código de barras).
    await admin('get', `/admin/catalog?q=nada-${run}`).expect(200);
    expect(requests.length).toBe(before);
  });

  it('imagens: só do item vinculado, reduzidas para o caixa', async () => {
    const dorflex = ((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])[0];
    expect(await service.syncImages()).toBe(0);
    await admin('post', '/admin/products').send({ displayName: `Dorflex vinculado ${run}`, barcode: gtin(), catalogProductId: dorflex.id }).expect(201);
    expect(await service.syncImages()).toBe(1);
    expect(requests.some((r) => r.path === '/files/dorflex.png' && r.key === undefined)).toBe(true);
    const again = ((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])[0];
    expect(again.main_image_id).toEqual(expect.any(String));
    const binary = (path: string) => admin('get', path).buffer(true).parse((res, done) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => done(null, Buffer.concat(chunks)));
    }).expect(200);
    const full = await sharp((await binary(`/admin/catalog-images/${again.main_image_id}/full`)).body as Buffer).metadata();
    const thumb = await sharp((await binary(`/admin/catalog-images/${again.main_image_id}/thumb`)).body as Buffer).metadata();
    expect([full.format, full.width, full.height]).toEqual(['webp', 800, 600]);
    expect([thumb.width, thumb.height]).toEqual([200, 150]);
    expect(await service.syncImages()).toBe(0);
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status.imagesDue).toBe(0);
  });

  it('"Atualizar agora" começa a cópia e responde na hora', async () => {
    version += 1;
    expect((await admin('post', '/platform/catalog-sync/run').expect(202)).body).toEqual({ started: true });
    for (let i = 0; i < 50; i += 1) {
      const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
      if (status.runs[0].trigger === 'manual' && status.runs[0].status !== 'running') {
        expect(status.runs[0].status).toBe('updated');
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error('A cópia manual não terminou');
  });
});
