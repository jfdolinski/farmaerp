// Descida para o PDV contra o banco real: terminal pareado de verdade, carga e incremental.
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { generateKeyPairSync, randomBytes, randomInt, sign } from 'node:crypto';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';
import { challengeMessage, pairingProofMessage } from './../src/terminals/terminal-crypto.js';

const ADMIN_EMAIL = 'admin@farmaerp.test';
const MANAGER_EMAIL = 'gerente@farmaerp.test';
const OPERATOR_EMAIL = 'operador@farmaerp.test';
const DEV_PASSWORD = 'farmaerp-dev-123';
const BRANCH_CENTRO = '019a0000-0000-7000-8000-000000000005';
const DIPIRONA = '019a0000-0000-7000-8000-000000000027';
const DEMO_CUSTOMER = '019a0000-0000-7000-8000-000000000032';
const CLONAZEPAM = '019a0000-0000-7000-8000-000000000033';
const CLONAZEPAM_BATCH = '019a0000-0000-7000-8000-000000000036';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

// UUID v7, como o PDV gera.
let clockMs = Date.now();
function uuidV7() {
  clockMs += 1;
  const bytes = randomBytes(16);
  bytes.writeUIntBE(clockMs, 0, 6);
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
let sequence = 0;
const logItem = (payload: Json = {}) => {
  sequence += 1;
  return {
    id: uuidV7(), sequence, kind: 'log',
    payload: { level: 'warn', time: new Date().toISOString(), msg: 'Falha de conexão com a API', error_code: 'FA001', ...payload },
  };
};

describe('descida para o PDV contra o banco real', () => {
  let app: INestApplication<App>;
  let session: string;
  const sessions = new Map<string, string>();
  let terminalId: string;
  let token: string;
  let ip: string;

  const server = () => app.getHttpServer();
  const admin = (method: 'get' | 'post', path: string) =>
    request(server())[method](`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${session}`);
  const pull = (body: Json, bearer = token) =>
    request(server())
      .post('/terminals/sync/pull')
      .set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${bearer}`)
      .set('Accept-Encoding', 'gzip')
      .send(body);

  /** A janela inteira, pacote por pacote. */
  async function pullAll(cursor: string | null) {
    const items: Json[] = [];
    let page = (await pull({ cursor }).expect(200)).body as Json;
    const until = page.until as string;
    items.push(...page.items);
    while (page.next) {
      page = (await pull({ cursor, until, after: page.next }).expect(200)).body as Json;
      items.push(...page.items);
    }
    return { until, items, find: (type: string, id: string) => items.find((i) => i.type === type && i.id === id) };
  }

  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() }))))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;

    for (const email of [ADMIN_EMAIL, MANAGER_EMAIL, OPERATOR_EMAIL]) {
      sessions.set(email, (
        (await request(server()).post('/auth/login').set('X-Forwarded-For', ip)
          .send({ email, password: DEV_PASSWORD }).expect(200)).body as Json
      ).token as string);
    }
    session = sessions.get(ADMIN_EMAIL)!;

    // Terminal de verdade: chave no aparelho, código, aprovação e token.
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const key = publicKey.export({ format: 'jwk' }).x!;
    const signText = (message: string) => sign(null, Buffer.from(message), privateKey).toString('base64url');
    const pairing = (await request(server()).post('/terminals/pairing/requests').set('X-Forwarded-For', ip).send({
      publicKey: key, signature: signText(pairingProofMessage(key)), platform: 'windows',
      deviceName: 'CAIXA-SYNC', appVersion: '0.1.0', keyStorage: 'system',
    }).expect(201)).body as Json;
    terminalId = ((await admin('post', `/pairing/${pairing.code}/claim`).send({ branchId: BRANCH_CENTRO }).expect(201)).body as Json)
      .terminalId as string;
    await admin('post', `/terminals/${terminalId}/approve`).send({ name: `Caixa sync ${Date.now()}`, profile: 'cashier' }).expect(200);
    const challenge = ((await request(server()).post('/terminals/auth/challenge').set('X-Forwarded-For', ip)
      .send({ terminalId }).expect(200)).body as Json).challenge as string;
    token = ((await request(server()).post('/terminals/auth/token').set('X-Forwarded-For', ip)
      .send({ challenge, signature: signText(challengeMessage(challenge)) }).expect(200)).body as Json).accessToken as string;
  });

  afterAll(async () => {
    await app.close();
  });

  it('carga inicial compactada, com a filial, os usuários e os produtos com preço e estoque', async () => {
    const response = await pull({}).expect(200);
    expect(response.headers['content-encoding']).toBe('gzip');
    expect(response.headers['cache-control']).toBe('no-store');
    const page = response.body as Json;
    expect(page).toMatchObject({ format: 3, until: expect.stringMatching(/^\d+$/) });
    expect(page.items[0]).toMatchObject({ type: 'fiscal', id: BRANCH_CENTRO });
    expect(page.items[0].data.series.map((s: Json) => s.model)).toEqual(['55', '65']);

    const load = await pullAll(null);
    expect(load.find('product', DIPIRONA)?.data).toMatchObject({ price: 12.9, status: 'active' });
    expect(load.find('stock', DIPIRONA)?.data).toHaveProperty('quantity');
    expect(load.items.some((i) => i.type === 'user' && i.data.permissions.length > 0)).toBe(true);

    // Sem gzip no pedido, a resposta vem sem compactar.
    const plain = await request(server()).post('/terminals/sync/pull').set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${token}`).set('Accept-Encoding', 'identity').send({}).expect(200);
    expect(plain.headers['content-encoding']).toBeUndefined();
    expect((plain.body as Json).items[0].type).toBe('fiscal');
  });

  it('incremental: só o que mudou depois do cursor', async () => {
    const { until } = await pullAll(null);
    expect((await pullAll(until)).items).toEqual([]);

    await admin('post', `/products/${DIPIRONA}/prices`)
      .send({ branchId: BRANCH_CENTRO, price: 11.5, reason: 'Teste da descida' }).expect(201);
    const step = await pullAll(until);
    expect(step.find('product', DIPIRONA)?.data).toMatchObject({ price: 11.5 });
    expect(step.items.every((i) => ['product', 'stock'].includes(i.type as string))).toBe(true);

    await admin('post', `/products/${DIPIRONA}/prices`).send({ branchId: BRANCH_CENTRO, price: null }).expect(201);
    expect((await pullAll(step.until)).find('product', DIPIRONA)?.data).toMatchObject({ price: 12.9 });
  });

  it('subida: aplica, não duplica e transforma o recusado em conflito visível', async () => {
    const push = (body: Json) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`).send(body);
    const first = logItem();
    const bad = logItem({ level: 'info' });
    expect((await push({ items: [first, bad] }).expect(200)).body).toEqual({
      results: [
        { id: first.id, status: 'applied', code: null },
        { id: bad.id, status: 'conflict', code: 'FA958' },
      ],
    });
    expect((await push({ items: [first] }).expect(200)).body.results[0]).toMatchObject({ status: 'duplicate', result: 'applied' });
    for (const body of [{}, { items: 'x' }, { items: [] }, { items: Array.from({ length: 501 }, () => logItem()) }, { items: [{ id: 'x' }] }]) {
      expect((await push(body).expect(422)).body).toMatchObject({ code: 'FA956' });
    }

    const conflicts = (email: string, query = '') =>
      request(server()).get(`/admin/sync/conflicts${query}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
    const mine = ((await conflicts(MANAGER_EMAIL).expect(200)).body as Json[]).find((row) => row.payload.level === 'info' && row.terminal_id === terminalId);
    expect(mine).toMatchObject({ error_code: 'FA958', status: 'open', kind: 'log', can_resolve: true, branch_id: BRANCH_CENTRO });
    expect((await conflicts(OPERATOR_EMAIL).expect(200)).body).toEqual([]);
    expect((await conflicts(MANAGER_EMAIL, '?status=outro').expect(422)).body).toMatchObject({ code: 'FA005' });

    const resolve = (email: string, note: unknown) =>
      request(server()).post(`/admin/sync/conflicts/${mine!.id}/resolve`).set('X-Forwarded-For', ip)
        .set('Authorization', `Bearer ${sessions.get(email)}`).send({ note });
    expect((await resolve(OPERATOR_EMAIL, 'ok').expect(404)).body).toMatchObject({ code: 'FA006' });
    expect((await resolve(MANAGER_EMAIL, ' ').expect(422)).body).toMatchObject({ code: 'FA302' });
    expect((await resolve(MANAGER_EMAIL, 12).expect(422)).body).toMatchObject({ code: 'FA005' });
    await resolve(MANAGER_EMAIL, 'PDV antigo, atualizado.').expect(200);
    expect((await resolve(MANAGER_EMAIL, 'De novo').expect(409)).body).toMatchObject({ code: 'FA960' });
    const resolved = ((await conflicts(MANAGER_EMAIL, '?status=resolved').expect(200)).body as Json[]).find((row) => row.id === mine!.id);
    expect(resolved).toMatchObject({ status: 'resolved', resolution_note: 'PDV antigo, atualizado.', resolved_by_name: expect.any(String) });
  });

  it('clientes: busca mascarada, escolha completa, descida acompanhada e situação na retaguarda', async () => {
    const auth = (call: request.Test) => call.set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
    const found = (await auth(request(server()).post('/terminals/customers/search')).send({ query: 'demonstra' }).expect(200)).body as Json[];
    const demo = found.find((row) => row.id === DEMO_CUSTOMER);
    expect(demo).toMatchObject({ name: 'Cliente Demonstração', city: 'São Paulo' });
    expect(JSON.stringify(found)).not.toContain('11144477735');
    expect(((await auth(request(server()).post('/terminals/customers/search')).send({ query: '111.444.777-35' }).expect(200)).body as Json[])
      .map((row) => row.id)).toEqual([DEMO_CUSTOMER]);
    expect((await auth(request(server()).post('/terminals/customers/search')).send({ query: 'ab' }).expect(422)).body).toMatchObject({ code: 'FA961' });
    expect((await auth(request(server()).post('/terminals/customers/search')).send({ query: 12 }).expect(422)).body).toMatchObject({ code: 'FA005' });

    const { until } = await pullAll(null);
    const full = (await auth(request(server()).get(`/terminals/customers/${DEMO_CUSTOMER}`)).expect(200)).body as Json;
    expect(full).toMatchObject({ id: DEMO_CUSTOMER, data: { document: '11144477735', phone: '11999990000' } });
    expect((await auth(request(server()).get('/terminals/customers/nada')).expect(422)).body).toMatchObject({ code: 'FA005' });
    expect((await auth(request(server()).get('/terminals/customers/019a0000-0000-7000-8000-0000000000ff')).expect(404)).body)
      .toMatchObject({ code: 'FA006' });

    // Mudança no cadastro desce para este terminal.
    const current = (await admin('get', `/customers/${DEMO_CUSTOMER}`).expect(200)).body as Json;
    await request(server()).patch(`/admin/customers/${DEMO_CUSTOMER}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${session}`)
      .send({ personType: 'individual', document: current.document ?? '11144477735', name: 'Cliente Demonstração', phone: '11988880000', city: 'São Paulo', state: 'SP' })
      .expect(200);
    const step = await pullAll(until);
    expect(step.find('customer', DEMO_CUSTOMER)?.data).toMatchObject({ phone: '11988880000' });
    await request(server()).patch(`/admin/customers/${DEMO_CUSTOMER}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${session}`)
      .send({ personType: 'individual', document: current.document ?? '11144477735', name: 'Cliente Demonstração', phone: '11999990000', city: 'São Paulo', state: 'SP' })
      .expect(200);

    // A retaguarda vê a situação da sincronização do terminal.
    const monitor = ((await admin('get', '/terminals').expect(200)).body as Json[]).find((row) => row.id === terminalId);
    expect(monitor).toMatchObject({ pending_changes: expect.any(Number), open_conflicts: expect.any(Number) });
    expect(monitor!.initial_load_at).not.toBeNull();
    expect(monitor!.last_pull_at).not.toBeNull();
    expect(monitor!.last_push_at).not.toBeNull();
  });

  it('venda: turno e venda sobem pela outbox, e a retaguarda vê a venda com os alertas', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const sessionId = uuidV7();
    const opened = (await push([{ kind: 'cash_session_open', payload: { id: sessionId, operator_id: operatorId, opened_at: new Date().toISOString(), opening_float: 100 } }]).expect(200)).body as Json;
    expect(opened.results[0]).toMatchObject({ status: 'applied' });

    const saleId = uuidV7();
    const number = Math.floor(Date.now() / 1000) % 900000 + 1;
    const sale = {
      id: saleId, number, cash_session_id: sessionId, operator_id: operatorId, customer_id: null,
      sold_at: new Date().toISOString(), fiscal_model: '65',
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 2, unit_price: 12.9, discount: 0, total: 25.8 }],
      payments: [{ id: uuidV7(), method: 'pix', amount: 25.8 }],
      subtotal: 25.8, discount_total: 0, total: 25.8,
    };
    expect((await push([{ kind: 'sale', payload: sale }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied', code: null });
    const bad = { ...sale, id: uuidV7(), number: number + 1, total: 1 };
    expect((await push([{ kind: 'sale', payload: bad }]).expect(200)).body.results[0]).toMatchObject({ status: 'conflict', code: 'FA962' });

    const asManager = (path: string) => request(server()).get(`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`);
    const listed = ((await asManager('/sales').expect(200)).body as Json[]).find((row) => row.id === saleId);
    expect(listed).toMatchObject({ payment_methods: ['pix'], fiscal_status: 'pending', alert_count: 0, item_count: 1 });
    const detail = (await asManager(`/sales/${saleId}`).expect(200)).body as Json;
    expect(detail).toMatchObject({ total: 25.8, items: [{ product_id: DIPIRONA, quantity: 2, central_price: 12.9 }] });
    expect((await asManager('/sales?from=ontem').expect(422)).body).toMatchObject({ code: 'FA005' });
    expect((await asManager(`/sales/${uuidV7()}`).expect(404)).body).toMatchObject({ code: 'FA006' });
    const asOperator = request(server()).get(`/admin/sales/${saleId}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(OPERATOR_EMAIL)}`);
    expect((await asOperator.expect(404)).body).toMatchObject({ code: 'FA006' });
  });

  it('controlado: venda com receita e lote, pendente sem saldo e lista mascarada na retaguarda', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const adminId = '019a0000-0000-7000-8000-000000000008';
    const sessionId = uuidV7();
    await push([{ kind: 'cash_session_open', payload: { id: sessionId, operator_id: operatorId, opened_at: new Date().toISOString(), opening_float: 50 } }]).expect(200);
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' });
    const complete = {
      id: uuidV7(), status: 'complete', pharmacist_id: adminId, prescription_type: 'notification_b', prescription_number: 'SP-123456',
      prescription_date: today, prescriber_name: 'Dra. Fictícia', prescriber_council: 'CRM', prescriber_number: '123456',
      prescriber_state: 'SP', buyer_name: 'Comprador Fictício', buyer_document_type: 'rg', buyer_document: '123456789',
      buyer_issuer: 'SSP', buyer_state: 'SP',
    };
    const saleOf = (number: number, controlled: Json | null, batchId: string | null) => ({
      id: uuidV7(), number, cash_session_id: sessionId, operator_id: operatorId, customer_id: null,
      sold_at: new Date().toISOString(), fiscal_model: '65',
      items: [{ id: uuidV7(), line: 1, product_id: CLONAZEPAM, quantity: 1, unit_price: 24.5, discount: 0, total: 24.5, batch_id: batchId, controlled }],
      payments: [{ id: uuidV7(), method: 'cash', amount: 24.5 }],
      subtotal: 24.5, discount_total: 0, total: 24.5,
    });
    const number = Math.floor(Date.now() / 1000) % 900000 + 100001;
    const sold = saleOf(number, complete, CLONAZEPAM_BATCH);
    expect((await push([{ kind: 'sale', payload: sold }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied', code: null });
    const pending = saleOf(number + 1, { id: uuidV7(), status: 'pending', pharmacist_id: adminId, pending_reason: 'Nota de entrada ainda não lançada' }, null);
    expect((await push([{ kind: 'sale', payload: pending }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    const missing = saleOf(number + 2, { ...complete, id: uuidV7(), buyer_document: null }, CLONAZEPAM_BATCH);
    expect((await push([{ kind: 'sale', payload: missing }]).expect(200)).body.results[0]).toMatchObject({ status: 'conflict', code: 'FA990' });

    const asManager = (path: string) => request(server()).get(`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`);
    const all = (await asManager('/controlled').expect(200)).body as Json[];
    const row = all.find((item) => item.sale_id === sold.id);
    expect(row).toMatchObject({
      status: 'complete', batch_number: 'CLZ01', prescriber: 'Dra. Fictícia · CRM 123456/SP', buyer_document_masked: '******789',
      controlled_class: 'B1', pharmacist_name: 'Administrador',
    });
    expect(JSON.stringify(all)).not.toContain('123456789');
    const onlyPending = (await asManager(`/controlled?status=pending&from=${today}&to=${today}`).expect(200)).body as Json[];
    expect(onlyPending.map((item) => item.sale_id)).toContain(pending.id);
    expect(onlyPending.every((item) => item.status === 'pending')).toBe(true);
    expect((await asManager(`/sales/${pending.id}`).expect(200)).body.alerts).toEqual(
      expect.arrayContaining([expect.objectContaining({ kind: 'controlled_pending' })]),
    );
    for (const query of ['?status=nada', '?from=ontem', '?to=2026-02-30x']) {
      expect((await asManager(`/controlled${query}`).expect(422)).body).toMatchObject({ code: 'FA005' });
    }
    const asOperator = request(server()).get('/admin/controlled').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(OPERATOR_EMAIL)}`);
    expect((await asOperator.expect(200)).body).toEqual([]);
  });

  it('estoque das outras filiais e tempo sem internet para a venda sem estoque', async () => {
    const auth = (call: request.Test) => call.set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
    const network = (await auth(request(server()).get(`/terminals/stock/${DIPIRONA}`)).expect(200)).body as Json[];
    expect(network[0]).toMatchObject({ branch_id: BRANCH_CENTRO, own: true });
    expect(network.length).toBeGreaterThan(1);
    expect((await auth(request(server()).get('/terminals/stock/nada')).expect(422)).body).toMatchObject({ code: 'FA005' });
    expect((await auth(request(server()).get(`/terminals/stock/${uuidV7()}`)).expect(404)).body).toMatchObject({ code: 'FA006' });

    const post = (path: string, body: Json, email = ADMIN_EMAIL) =>
      request(server()).post(`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`).send(body);
    await post(`/branches/${BRANCH_CENTRO}/offline-minutes`, { minutes: 40 }).expect(200);
    await post(`/terminals/${terminalId}/offline-minutes`, { minutes: 15 }).expect(200);
    const fiscal = (await pullAll(null)).find('fiscal', BRANCH_CENTRO)?.data;
    expect(fiscal).toMatchObject({ offline_zero_stock_minutes: 15 });
    const monitor = ((await admin('get', '/terminals').expect(200)).body as Json[]).find((row) => row.id === terminalId);
    expect(monitor).toMatchObject({ offline_minutes: 15, branch_offline_minutes: 40 });
    await post(`/terminals/${terminalId}/offline-minutes`, { minutes: null }).expect(200);
    expect((await pullAll(null)).find('fiscal', BRANCH_CENTRO)?.data).toMatchObject({ offline_zero_stock_minutes: 40 });
    for (const body of [{ minutes: 2 }, { minutes: '30' }, { minutes: 30.5 }]) {
      expect((await post(`/branches/${BRANCH_CENTRO}/offline-minutes`, body).expect(422)).body).toMatchObject({ code: 'FA976' });
    }
    expect((await post(`/branches/${BRANCH_CENTRO}/offline-minutes`, { minutes: 50 }, OPERATOR_EMAIL).expect(403)).body).toMatchObject({ code: 'FA002' });
    await post(`/branches/${BRANCH_CENTRO}/offline-minutes`, { minutes: 30 }).expect(200);
  });

  it('recusa pedido fora do formato, sem token e de terminal bloqueado', async () => {
    for (const body of [{ cursor: 'abc' }, { cursor: 12 }, { until: '1', after: '9:x' }, { cursor: 'x'.repeat(65) }]) {
      expect((await pull(body).expect(422)).body).toMatchObject({ code: 'FA956' });
    }
    expect((await pull({}, 'token-falso').expect(401)).body).toMatchObject({ code: 'FA306' });

    await admin('post', `/terminals/${terminalId}/block`).send({ reason: 'Teste da descida' }).expect(200);
    expect((await pull({}).expect(403)).body).toMatchObject({ code: 'FA304' });
    await admin('post', `/terminals/${terminalId}/revoke`).send({ reason: 'Fim do teste da descida' }).expect(200);
  });
});
