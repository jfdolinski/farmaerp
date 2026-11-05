// Rotas do motor de regras contra o banco real, com o seed de desenvolvimento.
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
const SEED_BARCODE = '7890000000017';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';
const BRANCH_SUL = '019a0000-0000-7000-8000-000000000006';

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

describe('motor de regras contra o banco real', () => {
  let app: INestApplication<App>;
  const sessions = new Map<string, string>();

  const newIp = () => `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const call = (method: Method, path: string, email = ADMIN) =>
    request(app.getHttpServer())
      [method](path)
      .set('X-Forwarded-For', newIp())
      .set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;
  const newProduct = async () => {
    const barcode = gtin();
    await call('post', '/admin/products')
      .send({ displayName: `Regra ${randomBytes(4).toString('hex')}`, barcode })
      .expect(201);
    return barcode;
  };
  const simulate = async (barcode: string, branch?: string) => {
    const query = `product=${barcode}${branch ? `&branch=${branch}` : ''}`;
    return (await call('get', `/admin/rules/simulate?${query}`).expect(200)).body as { product: Json; rules: Json[] };
  };
  const ruleOf = async (barcode: string, type: string, branch?: string) =>
    (await simulate(barcode, branch)).rules.find((row) => row.type_code === type) as Json;
  const createRule = async (data: object) =>
    ((await call('post', '/admin/rules').send({ typeCode: 'max_discount', value: 1, ...data }).expect(201)).body as { id: string }).id;

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
    await request(app.getHttpServer()).get('/admin/rules').set('X-Forwarded-For', newIp()).expect(401);
  });

  describe('simulador', () => {
    it('mostra o seed: comissão pela subcategoria e cashback pela família', async () => {
      const { product, rules } = await simulate(SEED_BARCODE);
      expect(product.display_name).toContain('Dipirona');
      expect(rules.map((row) => row.type_code)).toHaveLength(4);
      expect(rules.map((row) => row.type_code)).toEqual(
        expect.arrayContaining(['cashback', 'commission', 'cost_tolerance', 'max_discount']),
      );
      expect(rules.find((row) => row.type_code === 'commission')).toMatchObject({ level: 'subcategory', target_name: 'Comprimidos', value: '3.0000' });
      expect(rules.find((row) => row.type_code === 'cashback')).toMatchObject({ level: 'price_family', target_name: 'Dipironas' });
    });

    it('produto novo, sem regra própria, cai no padrão da loja', async () => {
      const barcode = await newProduct();
      expect(await ruleOf(barcode, 'cost_tolerance')).toMatchObject({ level: 'store_default', value: '5.0000' });
    });

    it('produto que não existe responde 404', async () => {
      const response = await call('get', '/admin/rules/simulate?product=naoexiste').expect(404);
      expect(codeOf(response)).toBe('FA006');
    });

    it('sem produto é recusado', async () => {
      const response = await call('get', '/admin/rules/simulate').expect(422);
      expect(codeOf(response)).toBe('FA005');
    });
  });

  describe('cadastro', () => {
    it('regra do produto, localizada pelo código de barras, vence a da loja', async () => {
      const barcode = await newProduct();
      await createRule({ typeCode: 'cost_tolerance', level: 'product', productLookup: barcode, value: 9.5 });
      expect(await ruleOf(barcode, 'cost_tolerance')).toMatchObject({ level: 'product', value: '9.5000' });
    });

    it('regra de filial vale só nela', async () => {
      const barcode = await newProduct();
      await createRule({ typeCode: 'commission', level: 'product', productLookup: barcode, value: 4, branchId: BRANCH_CENTRO });
      expect(await ruleOf(barcode, 'commission', BRANCH_CENTRO)).toMatchObject({ value: '4.0000', branch_id: BRANCH_CENTRO });
      expect((await ruleOf(barcode, 'commission', BRANCH_SUL)).rule_id).toBeNull();
    });

    it('editar troca o identificador, muda o valor e deixa o histórico', async () => {
      const barcode = await newProduct();
      const old = await createRule({ level: 'product', productLookup: barcode, value: 3, reason: 'Inicial' });
      const fresh = ((await call('patch', `/admin/rules/${old}`).send({ value: 6, reason: 'Revisão' }).expect(200)).body as { id: string }).id;
      expect(fresh).not.toBe(old);
      expect((await ruleOf(barcode, 'max_discount')).value).toBe('6.0000');

      const active = (await call('get', '/admin/rules').expect(200)).body as Json[];
      expect(active.map((row) => row.id)).toContain(fresh);
      expect(active.map((row) => row.id)).not.toContain(old);
      const history = (await call('get', '/admin/rules?historico=1').expect(200)).body as Json[];
      expect(history.find((row) => row.id === old)).toMatchObject({ state: 'ended', reason: 'Inicial', author: 'Administrador' });
    });

    it('encerrar tira a regra da resolução', async () => {
      const barcode = await newProduct();
      const id = await createRule({ level: 'product', productLookup: barcode, value: 3 });
      await call('post', `/admin/rules/${id}/end`).expect(200);
      expect((await ruleOf(barcode, 'max_discount')).rule_id).toBeNull();
    });

    it.each([
      ['valor em texto', { value: 'abc' }],
      ['cinco decimais', { value: 1.23456 }],
      ['prioridade quebrada', { priority: 1.5 }],
      ['data inválida', { validTo: 'amanhã' }],
    ])('recusa %s com FA005, antes do banco', async (_label, extra) => {
      const response = await call('post', '/admin/rules')
        .send({ typeCode: 'commission', level: 'store_default', value: 1, ...extra })
        .expect(422);
      expect(codeOf(response)).toBe('FA005');
    });

    it.each<[string, object, string]>([
      ['fora da faixa', { level: 'store_default', value: 101 }, 'FA701'],
      ['sem alvo', { level: 'manufacturer' }, 'FA702'],
      ['produto inexistente', { level: 'product', productLookup: 'naoexiste' }, 'FA702'],
      ['validade invertida', { level: 'store_default', validFrom: '2030-02-01T00:00:00Z', validTo: '2030-01-01T00:00:00Z' }, 'FA703'],
      ['nível desconhecido', { level: 'galaxia' }, 'FA704'],
    ])('recusa %s com o código do catálogo', async (_label, body, code) => {
      const response = await call('post', '/admin/rules').send({ typeCode: 'commission', value: 1, ...body }).expect(422);
      expect(codeOf(response)).toBe(code);
    });

    it('opções trazem os tipos e os fabricantes usados na rede', async () => {
      const options = (await call('get', '/admin/rule-options').expect(200)).body as { types: Json[]; manufacturers: Json[] };
      expect(options.types).toHaveLength(4);
      expect(options.manufacturers.map((row) => row.name)).toContain('Laboratório Demonstração');
    });
  });

  describe('permissões', () => {
    it('Gerente não vê regras nem altera', async () => {
      expect((await call('get', '/admin/rules', MANAGER).expect(200)).body).toEqual([]);
      const response = await call('post', '/admin/rules', MANAGER)
        .send({ typeCode: 'commission', level: 'store_default', value: 1, branchId: BRANCH_CENTRO })
        .expect(403);
      expect(codeOf(response)).toBe('FA002');
    });

    it('o simulador não revela regra a quem não pode ver', async () => {
      const { rules } = (await call('get', `/admin/rules/simulate?product=${SEED_BARCODE}`, MANAGER).expect(200)).body as { rules: Json[] };
      expect(rules.every((row) => row.rule_id === null)).toBe(true);
    });
  });
});
