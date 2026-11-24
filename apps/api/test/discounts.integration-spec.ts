// Descontos automáticos e grupos de clientes contra o banco real, com o seed de desenvolvimento.
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

describe('descontos automáticos contra o banco real', () => {
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

  it('cria, lista, simula e encerra descontos; recusa tipo sem os campos e quem não pode', async () => {
    const barcode = await newProduct();
    const group = ((await call('post', '/admin/customer-groups').send({ name: `Idosos ${randomBytes(3).toString('hex')}` }).expect(201)).body as Json).id as string;
    expect(((await call('get', '/admin/customer-groups').expect(200)).body as Json[]).some((g) => g.id === group)).toBe(true);
    const product = ((await call('post', '/admin/discount-rules').send({
      name: 'Produto 10%', kind: 'product', level: 'product', productLookup: barcode, percent: 10, stacking: 'cumulative', branchId: BRANCH_CENTRO,
    }).expect(201)).body as Json).id as string;
    const buyPay = ((await call('post', '/admin/discount-rules').send({
      name: 'Leve 3 pague 2', kind: 'buy_x_pay_y', level: 'product', productLookup: barcode, buyQuantity: 3, payQuantity: 2, stacking: 'exclusive', branchId: BRANCH_CENTRO,
    }).expect(201)).body as Json).id as string;
    const list = (await call('get', `/admin/discount-rules?branch=${BRANCH_CENTRO}`).expect(200)).body as Json[];
    expect(list.find((r) => r.id === buyPay)).toMatchObject({ status: 'active', buy_quantity: 3, pay_quantity: 2, stacking: 'exclusive' });

    const simulated = (await call('post', '/admin/discount-rules/simulate').send({
      branchId: BRANCH_CENTRO, lines: [{ product: barcode, quantity: 3, unitPrice: 10 }, { product: barcode, quantity: 1, unitPrice: 10 }],
      paymentMethods: ['pix'],
    }).expect(200)).body as Json[];
    // 3 unidades: leve 3 pague 2 (exclusiva, R$ 10) passa dos 10% (R$ 3); 1 unidade: só os 10%.
    expect(simulated[0]).toMatchObject({ line: 1, total_cents: 1000, applied: [{ rule_id: buyPay, name: 'Leve 3 pague 2' }] });
    expect(simulated[1].applied.map((a: Json) => a.rule_id)).toContain(product);
    // Na Loja Sul as regras do Centro não valem.
    const south = (await call('post', '/admin/discount-rules/simulate').send({ branchId: BRANCH_SUL, lines: [{ product: barcode, quantity: 3, unitPrice: 10 }] }).expect(200)).body as Json[];
    expect(south[0].applied.map((a: Json) => a.rule_id)).not.toContain(buyPay);

    expect(codeOf(await call('post', '/admin/discount-rules').send({ name: 'Sem grupo', kind: 'customer_group', level: 'store_default', percent: 5, stacking: 'cumulative' }).expect(422))).toBe('FA826');
    expect(codeOf(await call('post', '/admin/discount-rules').send({ name: 'Promo', kind: 'promotion', level: 'store_default', percent: 5, stacking: 'cumulative' }).expect(422))).toBe('FA827');
    expect(codeOf(await call('post', '/admin/discount-rules').send({ name: 'x', kind: 'product', level: 'store_default', percent: 5.12345, stacking: 'cumulative' }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', '/admin/discount-rules/simulate').send({ branchId: BRANCH_CENTRO, lines: [] }).expect(422))).toBe('FA005');
    expect(codeOf(await call('post', '/admin/discount-rules/simulate').send({ branchId: BRANCH_CENTRO, lines: [{ product: '0000000000000', quantity: 1, unitPrice: 1 }] }).expect(404))).toBe('FA006');
    expect(codeOf(await call('post', '/admin/discount-rules', MANAGER).send({ name: 'Gerente', kind: 'product', level: 'store_default', percent: 5, stacking: 'cumulative' }).expect(403))).toBe('FA002');

    await call('post', `/admin/discount-rules/${product}/end`).expect(200);
    await call('post', `/admin/discount-rules/${buyPay}/end`).expect(200);
    const history = (await call('get', '/admin/discount-rules?historico=1').expect(200)).body as Json[];
    expect(history.find((r) => r.id === product)).toMatchObject({ status: 'ended' });
    expect(codeOf(await call('post', `/admin/discount-rules/${product}/end`).expect(404))).toBe('FA006');

    await call('post', `/admin/customer-groups/${group}`).send({ name: 'Idosos renomeado' }).expect(200);
    await call('post', `/admin/customer-groups/${group}/delete`).expect(200);
    expect(codeOf(await call('post', `/admin/customer-groups/${group}/delete`).expect(404))).toBe('FA006');
  });
});
