// Cópia do Catálogo externo contra o banco real e um Catálogo falso (HTTP local): chave por filial
// (conferida e cifrada), verificação de cada filial com a ETag, só o que mudou, item que saiu,
// imagens dos vinculados, consulta na hora com a chave da filial do usuário e a tela da Plataforma.
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
import { CatalogSyncService } from './../src/catalog/catalog-sync.service.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const COMPANY = '019a0000-0000-7000-8000-000000000002';
const SUL = '019a0000-0000-7000-8000-000000000006';
const KEY_CENTRO = 'cat_chave_do_centro_123';
const KEY_SUL = 'cat_chave_do_sul_456';
const KEY_SUSPENDED = 'cat_empresa_suspensa_789';
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
  let linkedProduct = '';
  const run = randomInt(1e6, 9e6);
  const codes = { dorflex: gtin(), rivotril: gtin(), saiu: gtin(), novo: gtin(), desconhecido: gtin() };

  const admin = (method: 'get' | 'post' | 'put' | 'patch' | 'delete', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const etag = () => `W/"${run}-v${version}"`;

  function answer(req: IncomingMessage): { status: number; body?: unknown; headers?: Record<string, string>; raw?: Buffer } {
    const url = new URL(req.url ?? '/', base);
    if (url.pathname.startsWith('/files/')) return { status: 200, raw: png, headers: { 'Content-Type': 'image/png' } };
    const key = req.headers['x-api-key'];
    if (key === KEY_SUSPENDED) return { status: 403, body: { error: 'Empresa suspensa' } };
    if (key !== KEY_CENTRO && key !== KEY_SUL) return { status: 401, body: { error: 'Chave inválida' } };
    if (url.pathname === '/api/v1/categories') return { status: 200, body: [] };
    if (url.pathname === '/api/v1/catalog.json') {
      if (req.headers['if-none-match'] === etag()) return { status: 304, headers: { ETag: etag() } };
      return { status: 200, body: { generated_at: new Date().toISOString(), total: items.length, items }, headers: { ETag: etag() } };
    }
    const taxOf = /^\/api\/v1\/products\/(\d+)\/tax$/.exec(url.pathname)?.[1];
    if (taxOf) {
      if (!items.some((item) => String(item.id) === taxOf)) return { status: 404, body: { error: 'Produto não encontrado' } };
      return { status: 200, body: { product_id: Number(taxOf), uf: url.searchParams.get('uf'), values: { cfop: '5405', cst_icms: '60', cst_pis: '04', pis_rate: '0', cst_cofins: '04', cofins_rate: '0' } } };
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
        id: run + 1, name: `Dorflex C/10 Comp ${run}`, brand: 'Dorflex', manufacturer: 'Sanofi', category: 'Medicamento', anvisa_registry: '1030000850011', med_controlled: '',
        ncm: '30049099', cest: '1300100', tax_origin: '0', actives: [{ name: 'dipirona', concentration: '300 mg' }], barcodes: [{ code: codes.dorflex }],
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
    for (const email of [ADMIN, MANAGER, OPERATOR]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
  });

  afterAll(async () => {
    for (const branch of [CENTRO, SUL]) await admin('delete', `/admin/catalog-keys/${branch}`).expect(200);
    service.useCatalog(null);
    await app.close();
    await new Promise((resolve) => catalog.close(resolve));
  });

  it('sem o endereço do Catálogo, a Plataforma vê a ligação desligada; chave e "Atualizar agora" avisam', async () => {
    service.useCatalog(null);
    expect((await admin('get', '/platform/catalog-sync').expect(200)).body).toMatchObject({ configured: false });
    expect(codeOf(await admin('post', '/platform/catalog-sync/run').expect(409))).toBe('FA228');
    expect(codeOf(await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: KEY_CENTRO }).expect(409))).toBe('FA228');
    expect(codeOf(await admin('get', '/platform/catalog-sync', MANAGER).expect(403))).toBe('FA002');
    expect(codeOf(await admin('post', '/platform/catalog-sync/run', MANAGER).expect(403))).toBe('FA002');
    service.useCatalog(base);
  });

  it('chave por filial: conferida no Catálogo antes de guardar; a lista mostra só o começo', async () => {
    const before = requests.length;
    expect(codeOf(await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: 'curta' }).expect(422))).toBe('FA231');
    expect(codeOf(await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: 123 }).expect(422))).toBe('FA231');
    // Sem a permissão do certificado: recusa antes de falar com o Catálogo.
    expect(codeOf(await admin('put', `/admin/catalog-keys/${CENTRO}`, OPERATOR).send({ key: KEY_CENTRO }).expect(403))).toBe('FA002');
    expect(requests.length).toBe(before);
    expect(codeOf(await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: 'cat_chave_que_nao_existe' }).expect(422))).toBe('FA229');
    expect(codeOf(await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: KEY_SUSPENDED }).expect(422))).toBe('FA229');
    expect((await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: ` ${KEY_CENTRO} ` }).expect(200)).body).toEqual({ keyPrefix: 'cat_chav' });
    expect(requests.at(-1)).toMatchObject({ path: '/api/v1/categories', key: KEY_CENTRO });
    await admin('put', `/admin/catalog-keys/${SUL}`).send({ key: KEY_SUL }).expect(200);
    const list = (await admin('get', '/admin/catalog-keys').expect(200)).body as Json;
    expect(list.configured).toBe(true);
    expect(list.branches.find((b: Json) => b.branch_id === CENTRO)).toMatchObject({ key_prefix: 'cat_chav', can_manage: true });
    expect(JSON.stringify(list)).not.toContain(KEY_CENTRO);
    // Catálogo fora do ar na conferência: FA230.
    service.useCatalog('http://127.0.0.1:1');
    expect(codeOf(await admin('put', `/admin/catalog-keys/${SUL}`).send({ key: KEY_SUL }).expect(503))).toBe('FA230');
    service.useCatalog(base);
  });

  it('cada filial verifica com a própria chave: a primeira copia, a outra recebe 304; a busca acha pelo código e pelo nome', async () => {
    const before = requests.length;
    expect(await service.sync('manual')).toBe('updated');
    const copies = requests.slice(before).filter((r) => r.path === '/api/v1/catalog.json');
    expect(copies).toHaveLength(2);
    expect(new Set(copies.map((r) => r.key))).toEqual(new Set([KEY_CENTRO, KEY_SUL]));
    expect(copies[1].etag).toBe(etag());
    const byCode = (await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[];
    expect(byCode).toHaveLength(1);
    expect(byCode[0]).toMatchObject({ name: `Dorflex C/10 Comp ${run}`, manufacturer: 'Sanofi', brand: 'Dorflex', department: 'Medicamento', active_ingredient: 'dipirona 300 mg', ncm: '30049099', pending: false });
    expect(((await admin('get', `/admin/catalog?q=rivotril ${run}`).expect(200)).body as Json[])[0]).toMatchObject({ controlled_class: 'B1', manufacturer: 'Roche' });

    expect(await service.sync('schedule')).toBe('unchanged');
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status).toMatchObject({ configured: true });
    expect(status.runs.slice(0, 2).map((r: Json) => r.status)).toEqual(['unchanged', 'unchanged']);
    expect(status.runs.slice(0, 4).map((r: Json) => r.branch)).toEqual(
      expect.arrayContaining([expect.stringContaining('Loja Centro'), expect.stringContaining('Loja Sul')]),
    );
    expect(status.runs.find((r: Json) => r.status === 'updated')).toMatchObject({ trigger: 'manual', changed: 3, failed: 0 });
  });

  it('nova versão: só o que mudou é gravado; o que saiu some da busca', async () => {
    version += 1;
    items = [{ ...items[0], name: `Dorflex C/30 Comp ${run}` }, items[1]];
    expect(await service.sync('schedule')).toBe('updated');
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    const updated = status.runs.find((r: Json) => r.status === 'updated');
    expect(updated).toMatchObject({ items: 2, changed: 1 });
    expect(updated.removed).toBeGreaterThanOrEqual(1);
    expect((await admin('get', `/admin/catalog?q=${codes.saiu}`).expect(200)).body).toEqual([]);
    expect(((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])[0].name).toBe(`Dorflex C/30 Comp ${run}`);
  });

  it('Catálogo fora do ar: as verificações ficam como falha, sem marcar nada como fora', async () => {
    service.useCatalog('http://127.0.0.1:1');
    expect(await service.sync('manual')).toBe('failed');
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status.runs[0]).toMatchObject({ status: 'failed', message: 'O Catálogo não respondeu.' });
    expect(JSON.stringify(status)).not.toContain(KEY_CENTRO);
    expect(((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])).toHaveLength(1);
    service.useCatalog(base);
  });

  it('código que a cópia não tem é consultado na hora com a chave da filial do usuário; desconhecido lá volta pendente e não vincula', async () => {
    version += 1;
    items = [...items, { id: run + 4, name: `Novo depois da cópia ${run}`, barcodes: [{ code: codes.novo }], images: [], pending: false, active: true }];
    const found = (await admin('get', `/admin/catalog?q=${codes.novo}`).expect(200)).body as Json[];
    expect(found).toHaveLength(1);
    expect(found[0]).toMatchObject({ name: `Novo depois da cópia ${run}`, pending: false });
    expect(requests.at(-1)?.path).toBe(`/api/v1/barcodes/${codes.novo}`);
    expect([KEY_CENTRO, KEY_SUL]).toContain(requests.at(-1)?.key);

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

  it('sem chave nas filiais, a consulta na hora não sai e a verificação não começa', async () => {
    await admin('delete', `/admin/catalog-keys/${CENTRO}`).expect(200);
    await admin('delete', `/admin/catalog-keys/${SUL}`).expect(200);
    const before = requests.length;
    expect((await admin('get', `/admin/catalog?q=${gtin()}`).expect(200)).body).toEqual([]);
    expect(await service.sync('manual')).toBe('no_key');
    expect(requests.length).toBe(before);
    const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
    expect(status.withoutKey).toEqual(expect.arrayContaining([expect.stringContaining('Loja Centro')]));
    await admin('put', `/admin/catalog-keys/${CENTRO}`).send({ key: KEY_CENTRO }).expect(200);
    await admin('put', `/admin/catalog-keys/${SUL}`).send({ key: KEY_SUL }).expect(200);
  });

  it('imagens: só do item vinculado, reduzidas para o caixa, sem a chave', async () => {
    const dorflex = ((await admin('get', `/admin/catalog?q=${codes.dorflex}`).expect(200)).body as Json[])[0];
    expect(await service.syncImages()).toBe(0);
    linkedProduct = ((await admin('post', '/admin/products').send({ displayName: `Dorflex vinculado ${run}`, barcode: gtin(), catalogProductId: dorflex.id }).expect(201)).body as Json).id as string;
    expect(await service.syncImages()).toBe(1);
    // O cadastro do produto mostra o fabricante, a marca e o departamento do Catálogo.
    expect((await admin('get', `/admin/products/${linkedProduct}`).expect(200)).body).toMatchObject({
      catalog_manufacturer: 'Sanofi', catalog_brand: 'Dorflex', catalog_department: 'Medicamento',
    });
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

  it('tributação: o item vinculado recebe a do estado das filiais com chave, com o CST convertido para o Simples', async () => {
    const regime = await admin('patch', `/admin/fiscal/companies/${COMPANY}/regime`).send({ regime: 1 });
    expect(regime.status, JSON.stringify(regime.body)).toBe(200);
    const before = requests.length;
    expect(await service.syncTaxes()).toBeGreaterThanOrEqual(1);
    const taxCalls = requests.slice(before).filter((r) => r.path === `/api/v1/products/${run + 1}/tax?uf=SP`);
    expect(taxCalls).toHaveLength(1);
    expect([KEY_CENTRO, KEY_SUL]).toContain(taxCalls[0].key);
    const rules = (await admin('get', `/admin/products/${linkedProduct}/tax`).expect(200)).body as Json[];
    expect(rules.find((r) => r.branch_id === CENTRO)).toMatchObject({ status: 'ok', cfop: '5405', icms_csosn: '500', icms_cst: null, origin: 0, pis_cst: '04' });
    // Já buscada hoje: não busca de novo.
    expect(requests.slice(before).length).toBeGreaterThan(0);
    const again = requests.length;
    await service.syncTaxes();
    expect(requests.slice(again).some((r) => r.path.startsWith(`/api/v1/products/${run + 1}/tax`))).toBe(false);
    const coverage = (await admin('get', '/admin/fiscal/tax-coverage').expect(200)).body as Json[];
    expect(coverage.find((r) => r.branch_id === CENTRO)).toMatchObject({ has_catalog_key: true });
    expect((await admin('get', `/admin/fiscal/branches/${CENTRO}/catalog-tax-problems`).expect(200)).body).toEqual([]);
  });

  it('"Atualizar agora" começa a verificação e responde na hora', async () => {
    version += 1;
    expect((await admin('post', '/platform/catalog-sync/run').expect(202)).body).toEqual({ started: true });
    for (let i = 0; i < 50; i += 1) {
      const status = (await admin('get', '/platform/catalog-sync').expect(200)).body as Json;
      const manual = status.runs.filter((r: Json) => r.trigger === 'manual').slice(0, 2);
      if (manual.length === 2 && manual.every((r: Json) => r.status !== 'running') && manual.some((r: Json) => r.status === 'updated')) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error('A verificação manual não terminou');
  });
});
