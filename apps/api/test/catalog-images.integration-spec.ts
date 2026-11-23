// Imagens do Catálogo pela API, com a imagem de demonstração do seed (Dipirona).
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt, randomUUID } from 'node:crypto';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';

const PASSWORD = 'farmaerp-dev-123';
const MANAGER = 'gerente@farmaerp.test';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

describe('imagens do Catálogo contra o banco real', () => {
  let app: INestApplication<App>;
  let token: string;
  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const get = (path: string) =>
    request(app.getHttpServer()).get(path).set('X-Forwarded-For', newIp()).set('Authorization', `Bearer ${token}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  // O corpo da imagem vem em binário.
  const binary = (res: request.Response, done: (error: Error | null, body: Buffer) => void) => {
    const chunks: Buffer[] = [];
    res.on('data', (chunk: Buffer) => chunks.push(chunk));
    res.on('end', () => done(null, Buffer.concat(chunks)));
  };

  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] }).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    const login = await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', newIp())
      .send({ email: MANAGER, password: PASSWORD }).expect(200);
    token = (login.body as Json).token as string;
  });

  afterAll(async () => {
    await app.close();
  });

  it('o detalhe e as buscas trazem a imagem principal', async () => {
    const detail = (await get(`/admin/products/${DIPIRONA}`).expect(200)).body as Json;
    expect(detail.images).toEqual([{ id: expect.any(String), is_main: true, width: 600, height: 600 }]);
    const found = ((await get('/admin/products?q=Dipirona').expect(200)).body as Json[]).find((row) => row.id === DIPIRONA) as Json;
    expect(found.main_image_id).toBe(detail.images[0].id);
    const catalog = ((await get('/admin/catalog?q=Paracetamol').expect(200)).body as Json[])[0];
    expect(catalog).toMatchObject({ main_image_id: null });
  });

  it('entrega o WebP com cache longo e responde 304 para quem já tem', async () => {
    const detail = (await get(`/admin/products/${DIPIRONA}`).expect(200)).body as Json;
    const imageId = detail.images[0].id as string;
    const full = await get(`/admin/catalog-images/${imageId}/full`).buffer(true).parse(binary).expect(200);
    expect(full.headers['content-type']).toBe('image/webp');
    expect(full.headers['cache-control']).toBe('private, max-age=31536000, immutable');
    const body = full.body as Buffer;
    expect(body.toString('ascii', 0, 4)).toBe('RIFF');
    expect(body.toString('ascii', 8, 12)).toBe('WEBP');
    const thumb = await get(`/admin/catalog-images/${imageId}/thumb`).buffer(true).parse(binary).expect(200);
    expect((thumb.body as Buffer).length).toBeLessThan(body.length);
    expect(thumb.headers.etag).not.toBe(full.headers.etag);
    await get(`/admin/catalog-images/${imageId}/full`).set('If-None-Match', full.headers.etag as string).expect(304);
  });

  it('recusa tamanho desconhecido, imagem inexistente e quem não está logado', async () => {
    const detail = (await get(`/admin/products/${DIPIRONA}`).expect(200)).body as Json;
    expect(codeOf(await get(`/admin/catalog-images/${detail.images[0].id as string}/original`).expect(422))).toBe('FA005');
    expect(codeOf(await get(`/admin/catalog-images/${randomUUID()}/full`).expect(404))).toBe('FA006');
    await request(app.getHttpServer()).get(`/admin/catalog-images/${detail.images[0].id as string}/full`).set('X-Forwarded-For', newIp()).expect(401);
  });
});
