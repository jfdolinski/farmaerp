// Rotas de estoque contra o banco real, com o seed de desenvolvimento.
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
const CENTRO = '019a0000-0000-7000-8000-000000000005';
const SUL = '019a0000-0000-7000-8000-000000000006';
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

describe('estoque contra o banco real', () => {
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
    const { id } = (
      await call('post', '/admin/products')
        .send({ displayName: `Estoque ${randomBytes(4).toString('hex')}`, barcode })
        .expect(201)
    ).body as { id: string };
    return { id, barcode };
  };
  const adjust = (barcode: string, body: object = {}, email = ADMIN) =>
    call('post', '/admin/stock/adjustments', email).send({
      productLookup: barcode, branchId: CENTRO, direction: 'in', quantity: 10, reason: 'Teste', ...body,
    });
  const stockOf = async (id: string, email = ADMIN) =>
    (await call('get', `/admin/products/${id}/stock`, email).expect(200)).body as { balances: Json[]; tracking: Json[] };

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

  it('sem sessão, responde 401', async () => {
    await request(app.getHttpServer()).get('/admin/stock').set('X-Forwarded-For', newIp()).expect(401);
  });

  it('mostra o saldo do seed: uma loja com lote e outra sem', async () => {
    const { balances, tracking } = await stockOf(SEED_PRODUCT);
    const centro = balances.find((row) => row.branch_id === CENTRO) as Json;
    expect(centro).toMatchObject({ batch_number: 'DEMO1', expires_on: '2030-06-30' });
    expect(balances.find((row) => row.branch_id === SUL)).toMatchObject({ batch_number: null });
    expect(tracking.find((row) => row.branch_id === CENTRO)).toMatchObject({ tracks_batches: true });
    expect(tracking.find((row) => row.branch_id === SUL)).toMatchObject({ tracks_batches: false });
  });

  it('a validade volta como o dia exato, sem mudar pelo fuso', async () => {
    const { id, barcode } = await newProduct();
    await call('post', `/admin/products/${id}/batch-tracking`).send({ branchId: CENTRO, tracks: true }).expect(200);
    await adjust(barcode, { batchNumber: 'DIA', expiresOn: '2090-03-01' }).expect(201);
    const { balances } = await stockOf(id);
    expect(balances[0].expires_on).toBe('2090-03-01');
  });

  it('ajuste, perda e estorno mudam o saldo, e a conferência fica zerada', async () => {
    const { id, barcode } = await newProduct();
    const entry = (await adjust(barcode).expect(201)).body as { id: string };
    await call('post', '/admin/stock/losses')
      .send({ productLookup: barcode, branchId: CENTRO, quantity: 2.5, reason: 'Quebra' })
      .expect(201);
    expect(Number((await stockOf(id)).balances[0].quantity)).toBe(7.5);

    const blocked = await call('post', `/admin/stock/movements/${entry.id}/reverse`).send({ reason: 'Errado' }).expect(409);
    expect(codeOf(blocked)).toBe('FA801');

    const { divergences } = (await call('get', '/admin/stock/check').expect(200)).body as { divergences: number };
    expect(divergences).toBe(0);
  });

  it('o histórico mostra autor, motivo e estorno', async () => {
    const { barcode } = await newProduct();
    const entry = (await adjust(barcode, { reason: 'Carga do histórico' }).expect(201)).body as { id: string };
    await call('post', `/admin/stock/movements/${entry.id}/reverse`).send({ reason: 'Errado' }).expect(201);
    const movements = (await call('get', '/admin/stock/movements').expect(200)).body as Json[];
    expect(movements.find((row) => row.id === entry.id)).toMatchObject({
      reason: 'Carga do histórico', author: 'Administrador', reversed: true, movement_type: 'adjustment',
    });
  });

  it.each<[string, object, number, string]>([
    ['saída maior que o saldo', { direction: 'out', quantity: 1 }, 409, 'FA801'],
    ['sem motivo', { reason: null }, 422, 'FA302'],
    ['quantidade zero', { quantity: 0 }, 422, 'FA810'],
    ['quatro decimais', { quantity: 1.2345 }, 422, 'FA005'],
    ['quantidade em texto', { quantity: 'abc' }, 422, 'FA005'],
    ['validade inválida', { batchNumber: 'X', expiresOn: '2090-02-31' }, 422, 'FA005'],
    ['lote em produto sem controle', { batchNumber: 'X', expiresOn: '2090-01-01' }, 422, 'FA803'],
    ['produto inexistente', { productLookup: 'naoexiste' }, 422, 'FA004'],
  ])('recusa %s', async (_label, body, status, code) => {
    const { barcode } = await newProduct();
    const response = await adjust(barcode, body).expect(status);
    expect(codeOf(response)).toBe(code);
  });

  it('nada fica gravado quando a saída é recusada', async () => {
    const { id, barcode } = await newProduct();
    await adjust(barcode, { direction: 'out', quantity: 1 }).expect(409);
    expect((await stockOf(id)).balances).toEqual([]);
  });

  it('controle de lote: liga por filial, recusa com saldo e edita o lote', async () => {
    const { id, barcode } = await newProduct();
    await adjust(barcode, { branchId: SUL }).expect(201);
    const blocked = await call('post', `/admin/products/${id}/batch-tracking`).send({ branchId: SUL, tracks: true }).expect(409);
    expect(codeOf(blocked)).toBe('FA809');

    await call('post', `/admin/products/${id}/batch-tracking`).send({ branchId: CENTRO, tracks: true }).expect(200);
    const noBatch = await adjust(barcode).expect(422);
    expect(codeOf(noBatch)).toBe('FA802');
    await adjust(barcode, { batchNumber: 'abc', expiresOn: '2090-01-01' }).expect(201);

    const { balances } = await stockOf(id);
    const batch = balances.find((row) => row.branch_id === CENTRO) as Json;
    expect(batch.batch_number).toBe('ABC');
    await call('patch', `/admin/stock/batches/${batch.batch_id}`)
      .send({ batchNumber: 'ABD', expiresOn: '2091-01-01', reason: 'Nota corrigida' })
      .expect(200);
    const after = (await stockOf(id)).balances.find((row) => row.branch_id === CENTRO) as Json;
    expect(after).toMatchObject({ batch_number: 'ABD', expires_on: '2091-01-01' });
  });

  it('a busca acha pelo número do lote', async () => {
    const rows = (await call('get', '/admin/stock?q=demo1').expect(200)).body as Json[];
    expect(rows.map((row) => row.product_id)).toContain(SEED_PRODUCT);
    expect(rows.every((row) => row.batch_number === 'DEMO1')).toBe(true);
  });

  describe('transferência e inventário', () => {
    const tracked = async () => {
      const product = await newProduct();
      for (const branchId of [CENTRO, SUL]) {
        await call('post', `/admin/products/${product.id}/batch-tracking`).send({ branchId, tracks: true }).expect(200);
      }
      await adjust(product.barcode, { batchNumber: 'TARDE', expiresOn: '2092-01-01', quantity: 5 }).expect(201);
      await adjust(product.barcode, { batchNumber: 'CEDO', expiresOn: '2090-01-01', quantity: 3 }).expect(201);
      return product;
    };
    const transfer = (barcode: string, body: object = {}, email = ADMIN) =>
      call('post', '/admin/stock/transfers', email).send({
        productLookup: barcode, fromBranchId: CENTRO, toBranchId: SUL, quantity: 4, reason: 'Reposição', ...body,
      });
    const batchesAt = async (id: string, branch: string) =>
      Object.fromEntries(
        (await stockOf(id)).balances
          .filter((row) => row.branch_id === branch)
          .map((row) => [row.batch_number, Number(row.quantity)]),
      );

    it('sem lote informado, sai pelo vencimento e leva a validade', async () => {
      const product = await tracked();
      await transfer(product.barcode).expect(201);
      expect(await batchesAt(product.id, CENTRO)).toEqual({ TARDE: 4 });
      expect(await batchesAt(product.id, SUL)).toEqual({ CEDO: 3, TARDE: 1 });
      const destination = (await stockOf(product.id)).balances.find((row) => row.branch_id === SUL && row.batch_number === 'CEDO') as Json;
      expect(destination.expires_on).toBe('2090-01-01');
    });

    it('fora da ordem: o Gerente tem a permissão, e a movimentação fica marcada', async () => {
      const product = await tracked();
      await transfer(product.barcode, { batchNumber: 'TARDE', quantity: 1 }, MANAGER).expect(201);
      const movements = (await call('get', '/admin/stock/movements').expect(200)).body as Json[];
      const out = movements.find((row) => row.product_code && row.batch_number === 'TARDE' && row.movement_type === 'transfer' && Number(row.quantity) < 0) as Json;
      expect(out).toMatchObject({ fefo_override: true, author: 'Gerente Centro' });
    });

    it.each<[string, object, number, string]>([
      ['mesma filial', { toBranchId: CENTRO }, 422, 'FA815'],
      ['mais do que há', { quantity: 9 }, 409, 'FA801'],
      ['destino inválido', { toBranchId: 'abc' }, 422, 'FA005'],
    ])('recusa %s', async (_label, body, status, code) => {
      const product = await tracked();
      const response = await transfer(product.barcode, body).expect(status);
      expect(codeOf(response)).toBe(code);
    });

    it('inventário lança a diferença e avisa quando não há o que lançar', async () => {
      const product = await newProduct();
      await adjust(product.barcode).expect(201);
      const counted = (await call('post', '/admin/stock/counts').send({
        productLookup: product.barcode, branchId: CENTRO, countedQuantity: 7, reason: 'Inventário',
      }).expect(201)).body as Json;
      expect(counted.changed).toBe(true);
      expect(Number((await stockOf(product.id)).balances[0].quantity)).toBe(7);

      const same = (await call('post', '/admin/stock/counts').send({
        productLookup: product.barcode, branchId: CENTRO, countedQuantity: 7, reason: 'Inventário',
      }).expect(201)).body as Json;
      expect(same).toEqual({ id: null, changed: false });

      const zero = (await call('post', '/admin/stock/counts').send({
        productLookup: product.barcode, branchId: CENTRO, countedQuantity: 0, reason: 'Inventário',
      }).expect(201)).body as Json;
      expect(zero.changed).toBe(true);
    });

    it('inventário recusa contagem negativa e o Gerente não faz', async () => {
      const product = await newProduct();
      const negative = await call('post', '/admin/stock/counts')
        .send({ productLookup: product.barcode, branchId: CENTRO, countedQuantity: -1, reason: 'x' })
        .expect(422);
      expect(codeOf(negative)).toBe('FA005');
      const manager = await call('post', '/admin/stock/counts', MANAGER)
        .send({ productLookup: product.barcode, branchId: CENTRO, countedQuantity: 1, reason: 'x' })
        .expect(403);
      expect(codeOf(manager)).toBe('FA002');
    });

    it('a grade do produto diz se vende em cada filial', async () => {
      const product = await newProduct();
      await call('post', `/admin/products/${product.id}/status`)
        .send({ branchIds: [CENTRO], status: 'blocked', reason: 'Saiu do mix' })
        .expect(200);
      const detail = (await call('get', `/admin/products/${product.id}`).expect(200)).body as Json;
      const centro = (detail.grid as Json[]).find((row) => row.branch_id === CENTRO) as Json;
      const sul = (detail.grid as Json[]).find((row) => row.branch_id === SUL) as Json;
      expect(centro).toMatchObject({ sellable: false, notice: 'unavailable', auto_purchase: false });
      expect(sul).toMatchObject({ sellable: true, notice: null, auto_purchase: true });
    });
  });

  describe('permissões', () => {
    it('Gerente vê só a filial dele e registra perda nela, mas não ajusta nem liga lote', async () => {
      const { balances } = await stockOf(SEED_PRODUCT, MANAGER);
      expect(balances.map((row) => row.branch_id)).toEqual([CENTRO]);

      const product = await newProduct();
      await adjust(product.barcode).expect(201);
      await call('post', '/admin/stock/losses', MANAGER)
        .send({ productLookup: product.barcode, branchId: CENTRO, quantity: 1, reason: 'Quebra' })
        .expect(201);

      const other = await call('post', '/admin/stock/losses', MANAGER)
        .send({ productLookup: product.barcode, branchId: SUL, quantity: 1, reason: 'Quebra' })
        .expect(403);
      expect(codeOf(other)).toBe('FA002');
      const adjustment = await adjust(product.barcode, {}, MANAGER).expect(403);
      expect(codeOf(adjustment)).toBe('FA002');
      const tracking = await call('post', `/admin/products/${product.id}/batch-tracking`, MANAGER)
        .send({ branchId: CENTRO, tracks: true })
        .expect(403);
      expect(codeOf(tracking)).toBe('FA002');
    });

    it('Operador não vê estoque', async () => {
      expect((await call('get', '/admin/stock', OPERATOR).expect(200)).body).toEqual([]);
      expect((await call('get', '/admin/stock/movements', OPERATOR).expect(200)).body).toEqual([]);
    });
  });
});
