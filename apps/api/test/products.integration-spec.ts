// Rotas de produtos contra o banco real, com o seed de desenvolvimento.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomBytes, randomInt } from 'node:crypto';
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
const OPERATOR = 'operador@farmaerp.test';
const SEED_PRODUCT = '019a0000-0000-7000-8000-000000000027';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Method = 'get' | 'post' | 'patch';

function gtin(): string {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base
    .split('')
    .reverse()
    .reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

describe('produtos contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const name = () => `Teste ${randomBytes(4).toString('hex')}`;
  const newProduct = async (extra: object = {}) =>
    (
      await call('post', '/admin/products')
        .send({ displayName: name(), barcode: gtin(), ...extra })
        .expect(201)
    ).body as { id: string };
  const detail = async (id: string, email = ADMIN) =>
    (await call('get', `/admin/products/${id}`, email).expect(200)).body as Json;

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

  describe('sem sessão', () => {
    it.each(['/admin/products', '/admin/catalog', '/admin/product-structure'])(
      '%s responde 401',
      async (path) => {
        await request(app.getHttpServer())
          .get(path)
          .set('X-Forwarded-For', newIp())
          .expect(401);
      },
    );
  });

  describe('cadastro', () => {
    it('cria, busca e abre o produto', async () => {
      const displayName = name();
      const barcode = gtin();
      const { id } = await newProduct({ displayName, barcode, fractionQuantity: 2.5 });

      const found = (await call('get', `/admin/products?q=${encodeURIComponent(displayName)}`).expect(200)).body as Json[];
      expect(found.map((row) => row.id)).toEqual([id]);

      const product = await detail(id);
      expect(product.display_name).toBe(displayName);
      expect(Number(product.fraction_quantity)).toBe(2.5);
      expect(product.barcodes).toHaveLength(1);
      expect(product.barcodes[0]).toMatchObject({ code: barcode, is_primary: true });
      expect(Number(product.barcodes[0].effective_fraction)).toBe(2.5);
    });

    it('produto do Catálogo mostra os dados do Catálogo', async () => {
      const product = await detail(SEED_PRODUCT);
      expect(product.catalog_name).toContain('Dipirona');
      expect(product.catalog_manufacturer).toBe('Laboratório Demonstração');
      expect(product.ncm).toBe('30049099');
    });

    it('edita o produto', async () => {
      const { id } = await newProduct();
      const displayName = name();
      await call('patch', `/admin/products/${id}`)
        .send({ displayName, usesPmc: true, ownManufacturer: 'Marca' })
        .expect(200);
      expect(await detail(id)).toMatchObject({
        display_name: displayName,
        uses_pmc: true,
        own_manufacturer: 'Marca',
      });
    });

    it.each([
      ['sem nome', { barcode: '7891000000001' }],
      ['sem código', { displayName: 'X' }],
      ['fracionamento em texto', { displayName: 'X', barcode: '1', fractionQuantity: 'abc' }],
      ['subcategoria inválida', { displayName: 'X', barcode: '1', categoryId: 'abc' }],
      ['canal fora do formato', { displayName: 'X', barcode: '1', usesPmc: 'sim' }],
    ])('recusa %s com FA005, antes do banco', async (_label, body) => {
      const response = await call('post', '/admin/products').send(body).expect(422);
      expect(codeOf(response)).toBe('FA005');
    });

    it('recusa dígito verificador errado com FA602', async () => {
      const response = await call('post', '/admin/products')
        .send({ displayName: name(), barcode: '7891000000000' })
        .expect(422);
      expect(codeOf(response)).toBe('FA602');
    });

    it('recusa código repetido com FA601, e nada fica gravado', async () => {
      const barcode = gtin();
      await newProduct({ barcode });
      const displayName = name();
      const response = await call('post', '/admin/products')
        .send({ displayName, barcode })
        .expect(409);
      expect(codeOf(response)).toBe('FA601');
      const found = (await call('get', `/admin/products?q=${encodeURIComponent(displayName)}`).expect(200)).body as Json[];
      expect(found).toEqual([]);
    });

    it('produto que não existe responde 404', async () => {
      const response = await call('get', '/admin/products/019a0000-0000-7000-8000-0000000fffff').expect(404);
      expect(codeOf(response)).toBe('FA006');
    });
  });

  describe('códigos de barras', () => {
    it('remover o principal é recusado ao confirmar, com FA603', async () => {
      const { id } = await newProduct();
      const [primary] = (await detail(id)).barcodes as Json[];
      const response = await call('post', `/admin/barcodes/${primary.id}/remove`).expect(422);
      expect(codeOf(response)).toBe('FA603');
      expect((await detail(id)).barcodes).toHaveLength(1);
    });

    it('adiciona, troca o principal e remove o antigo', async () => {
      const { id } = await newProduct();
      const [oldPrimary] = (await detail(id)).barcodes as Json[];
      const code = gtin();
      const added = (
        await call('post', `/admin/products/${id}/barcodes`).send({ code, fractionQuantity: 10 }).expect(201)
      ).body as { id: string };

      await call('post', `/admin/barcodes/${added.id}/primary`).expect(200);
      await call('post', `/admin/barcodes/${oldPrimary.id}/remove`).expect(200);

      const { barcodes } = await detail(id);
      expect(barcodes).toHaveLength(1);
      expect(barcodes[0]).toMatchObject({ code, is_primary: true });
      expect(Number(barcodes[0].effective_fraction)).toBe(10);
    });

    it('edita opções e canais', async () => {
      const { id } = await newProduct();
      const added = (
        await call('post', `/admin/products/${id}/barcodes`).send({ code: gtin() }).expect(201)
      ).body as { id: string };
      const channel = (
        await call('post', '/admin/sales-channels').send({ name: name() }).expect(201)
      ).body as { id: string };

      await call('patch', `/admin/barcodes/${added.id}`)
        .send({ scanEnabled: false, sendsToSupplier: false, channels: [channel.id] })
        .expect(200);

      const row = ((await detail(id)).barcodes as Json[]).find((item) => item.id === added.id) as Json;
      expect(row).toMatchObject({
        scan_enabled: false,
        sends_to_supplier: false,
        channels: [channel.id],
      });
    });

    it('desligar a leitura do principal é recusado com FA606', async () => {
      const { id } = await newProduct();
      const [primary] = (await detail(id)).barcodes as Json[];
      const response = await call('patch', `/admin/barcodes/${primary.id}`).send({ scanEnabled: false }).expect(422);
      expect(codeOf(response)).toBe('FA606');
    });
  });

  describe('Catálogo', () => {
    it('consulta e marca o que já está na loja', async () => {
      const rows = (await call('get', '/admin/catalog?q=dipirona').expect(200)).body as Json[];
      const seeded = rows.find((row) => row.name.includes('Dipirona')) as Json;
      expect(seeded.product_id).toBe(SEED_PRODUCT);
    });

    it('cadastrar item já vinculado é recusado com FA604', async () => {
      const [row] = (await call('get', '/admin/catalog?q=dipirona').expect(200)).body as Json[];
      const response = await call('post', '/admin/products')
        .send({ displayName: name(), catalogProductId: row.id, barcode: gtin() })
        .expect(409);
      expect(codeOf(response)).toBe('FA604');
    });

    it('a consulta longa demais é recusada', async () => {
      const response = await call('get', `/admin/catalog?q=${'x'.repeat(201)}`).expect(422);
      expect(codeOf(response)).toBe('FA005');
    });
  });

  describe('estrutura', () => {
    it('cria os três níveis, renomeia e exclui', async () => {
      const create = async (parentId?: string) =>
        ((await call('post', '/admin/product-categories').send({ parentId, name: name() }).expect(201)).body as { id: string }).id;
      const department = await create();
      const category = await create(department);
      const leaf = await create(category);

      const newName = name();
      await call('patch', `/admin/product-categories/${leaf}`).send({ name: newName }).expect(200);
      const { categories } = (await call('get', '/admin/product-structure').expect(200)).body as { categories: Json[] };
      expect(categories.find((row) => row.id === leaf)).toMatchObject({ name: newName, level: 3, parent_id: category });

      const blocked = await call('post', `/admin/product-categories/${department}/delete`).expect(409);
      expect(codeOf(blocked)).toBe('FA105');
      await call('post', `/admin/product-categories/${leaf}/delete`).expect(200);
    });

    it('grupo: cria, renomeia e não exclui em uso', async () => {
      const group = (await call('post', '/admin/product-groups').send({ kind: 'pricing', name: name() }).expect(201)).body as { id: string };
      await call('patch', `/admin/product-groups/${group.id}`).send({ name: name() }).expect(200);
      await newProduct({ pricingGroupId: group.id });
      const blocked = await call('post', `/admin/product-groups/${group.id}/delete`).expect(409);
      expect(codeOf(blocked)).toBe('FA105');
    });

    it('canal: cria, renomeia e exclui', async () => {
      const channel = (await call('post', '/admin/sales-channels').send({ name: name() }).expect(201)).body as { id: string };
      await call('patch', `/admin/sales-channels/${channel.id}`).send({ name: name() }).expect(200);
      await call('post', `/admin/sales-channels/${channel.id}/delete`).expect(200);
    });
  });

  describe('permissões', () => {
    it('Gerente vê, mas não altera', async () => {
      const rows = (await call('get', '/admin/products', MANAGER).expect(200)).body as Json[];
      expect(rows.map((row) => row.id)).toContain(SEED_PRODUCT);
      await detail(SEED_PRODUCT, MANAGER);

      const writes: [Method, string, object][] = [
        ['post', '/admin/products', { displayName: name(), barcode: gtin() }],
        ['patch', `/admin/products/${SEED_PRODUCT}`, { displayName: 'X' }],
        ['post', `/admin/products/${SEED_PRODUCT}/barcodes`, { code: gtin() }],
        ['post', '/admin/product-categories', { name: name() }],
        ['post', '/admin/product-groups', { kind: 'pricing', name: name() }],
        ['post', '/admin/sales-channels', { name: name() }],
      ];
      for (const [method, path, body] of writes) {
        const response = await call(method, path, MANAGER).send(body);
        expect([path, response.status, codeOf(response)]).toEqual([path, 403, 'FA002']);
      }
    });

    it('Operador não vê produtos nem a estrutura', async () => {
      const rows = (await call('get', '/admin/products', OPERATOR).expect(200)).body as Json[];
      expect(rows).toEqual([]);
      const response = await call('get', `/admin/products/${SEED_PRODUCT}`, OPERATOR).expect(404);
      expect(codeOf(response)).toBe('FA006');
      const structure = (await call('get', '/admin/product-structure', OPERATOR).expect(200)).body as Json;
      expect(structure).toEqual({ categories: [], groups: [], channels: [] });
    });
  });
});
