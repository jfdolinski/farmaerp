// Imagem da tela de entrada contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { createHash, randomBytes, randomInt } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const MANAGER = 'gerente@farmaerp.test';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const jpeg = () =>
  Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(500)]);
const sha = (buffer: Buffer) =>
  createHash('sha256').update(buffer).digest('hex');

describe('imagem da tela de entrada contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();
  const newIp = () =>
    `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const server = () => request(app.getHttpServer());
  const upload = (body: Buffer, type = 'image/jpeg', email = ADMIN) =>
    server()
      .put('/platform/login-image')
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`)
      .set('Content-Type', type)
      .send(body);
  const clear = (email = ADMIN) =>
    server()
      .delete('/platform/login-image')
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);

  beforeAll(async () => {
    const destination = new Writable({
      write(_chunk: Buffer, _encoding, callback) {
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
    for (const email of [ADMIN, MANAGER]) {
      const response = await server()
        .post('/auth/login')
        .set('X-Forwarded-For', newIp())
        .send({ email, password: PASSWORD })
        .expect(200);
      sessions.set(email, (response.body as Json).token as string);
    }
  });

  afterAll(async () => {
    await clear();
    await app.close();
  });

  it('o administrador da plataforma envia; a tela de entrada lê sem sessão, com resumo e cache', async () => {
    const image = jpeg();
    expect((await upload(image).expect(200)).body).toEqual({
      sha256: sha(image),
    });

    expect(
      (await server().get('/public/login-image/info').expect(200)).body,
    ).toEqual({
      sha256: sha(image),
      mime: 'image/jpeg',
      size: image.length,
    });
    const response = await server()
      .get('/public/login-image')
      .buffer(true)
      .parse((res, done) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => done(null, Buffer.concat(chunks)));
      })
      .expect(200);
    expect(response.headers['content-type']).toBe('image/jpeg');
    expect(response.headers.etag).toBe(`"${sha(image)}"`);
    expect(Buffer.compare(response.body as Buffer, image)).toBe(0);
    await server()
      .get('/public/login-image')
      .set('If-None-Match', `"${sha(image)}"`)
      .expect(304);
  });

  it('voltar ao padrão tira a imagem', async () => {
    await upload(jpeg()).expect(200);
    await clear().expect(200);
    expect(
      (await server().get('/public/login-image/info').expect(200)).body,
    ).toEqual({ sha256: null });
    expect(
      (await server().get('/public/login-image').expect(404)).body,
    ).toMatchObject({ code: 'FA006' });
  });

  it('quem não é administrador da plataforma não troca nem tira; sem sessão também não', async () => {
    expect(
      (await upload(jpeg(), 'image/jpeg', MANAGER).expect(403)).body,
    ).toMatchObject({ code: 'FA002' });
    expect((await clear(MANAGER).expect(403)).body).toMatchObject({
      code: 'FA002',
    });
    await server()
      .put('/platform/login-image')
      .set('Content-Type', 'image/jpeg')
      .send(jpeg())
      .expect(401);
  });

  it('tipo errado, arquivo que não é imagem e arquivo grande demais são recusados com FA225', async () => {
    for (const response of [
      await upload(
        Buffer.concat([Buffer.from('GIF89a'), randomBytes(100)]),
        'image/gif',
      ),
      await upload(randomBytes(500), 'image/png'),
      await upload(Buffer.alloc(3 * 1024 * 1024 + 1, 1), 'image/jpeg'),
    ]) {
      expect(response.status).toBe(422);
      expect((response.body as Json).code).toBe('FA225');
    }
  });
});
