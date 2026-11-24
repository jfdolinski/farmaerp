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

  it('caixa: sangria liberada pelo gerente, fechamento cego e conferência na retaguarda', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const managerId = '019a0000-0000-7000-8000-00000000000d';
    const sessionId = uuidV7();
    const at = () => new Date().toISOString();
    await push([{ kind: 'cash_session_open', payload: { id: sessionId, operator_id: operatorId, opened_at: at(), opening_float: 100 } }]).expect(200);
    const withdrawal = { id: uuidV7(), cash_session_id: sessionId, kind: 'withdrawal', amount: 80, reason: 'Envelope do cofre', operator_id: operatorId, released_by: managerId, moved_at: at() };
    const results = (await push([
      { kind: 'cash_movement', payload: { id: uuidV7(), cash_session_id: sessionId, kind: 'supply', amount: 20, reason: 'Troco', operator_id: operatorId, released_by: null, moved_at: at() } },
      { kind: 'cash_movement', payload: withdrawal },
      { kind: 'cash_session_close', payload: { cash_session_id: sessionId, closed_by: operatorId, closed_at: at(), counts: { cash: 35, credit_card: 0, debit_card: 0, pix: 0 }, note: null } },
      { kind: 'cash_movement', payload: { ...withdrawal, id: uuidV7() } },
    ]).expect(200)).body.results as Json[];
    expect(results.map((r) => [r.status, r.code])).toEqual([['applied', null], ['applied', null], ['applied', null], ['conflict', 'FA996']]);

    const asManager = (path: string) => request(server()).get(`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`);
    const listed = ((await asManager('/cash-sessions?status=closed').expect(200)).body as Json[]).find((row) => row.id === sessionId);
    expect(listed).toMatchObject({ status: 'closed', alert_count: 1 });
    expect(Number(listed!.difference_total)).toBe(-5);
    const detail = (await asManager(`/cash-sessions/${sessionId}`).expect(200)).body as Json;
    expect(detail.counts[0]).toMatchObject({ method: 'cash', counted: 35, expected: 40, difference: -5 });
    expect(detail.movements.map((m: Json) => [m.kind, m.released_by_name]).sort()).toEqual([['supply', null], ['withdrawal', 'Gerente Centro']]);
    const releases = (await asManager('/supervisor-releases?action=cash.withdrawal').expect(200)).body as Json[];
    expect(releases.some((row) => row.reason === 'Envelope do cofre')).toBe(true);
    for (const query of ['?status=nada', '?from=ontem', '?branch=x']) {
      expect((await asManager(`/cash-sessions${query}`).expect(422)).body).toMatchObject({ code: 'FA005' });
    }
    expect((await asManager(`/cash-sessions/${uuidV7()}`).expect(404)).body).toMatchObject({ code: 'FA006' });
    const asOperator = request(server()).get(`/admin/cash-sessions/${sessionId}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(OPERATOR_EMAIL)}`);
    expect((await asOperator.expect(404)).body).toMatchObject({ code: 'FA006' });
  });

  it('autenticação: forma de entrar no PDV, entradas e liberações na retaguarda', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const managerId = '019a0000-0000-7000-8000-00000000000d';
    const asManager = (method: 'get' | 'post', path: string) =>
      request(server())[method](`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`);
    try {
      await admin('post', `/users/${operatorId}/auth-mode`).send({ mode: 'face' }).expect(200);
      const users = (await admin('get', '/users').expect(200)).body as Json[];
      expect(users.find((u) => u.id === operatorId)).toMatchObject({ pdv_auth_mode: 'face' });
      expect((await admin('post', `/users/${operatorId}/auth-mode`).send({ mode: 'senha' }).expect(422)).body).toMatchObject({ code: 'FA819' });
      expect((await admin('post', `/users/${operatorId}/auth-mode`).send({}).expect(422)).body).toMatchObject({ code: 'FA819' });
      const asOperator = request(server()).post(`/admin/users/${managerId}/auth-mode`).set('X-Forwarded-For', ip)
        .set('Authorization', `Bearer ${sessions.get(OPERATOR_EMAIL)}`).send({ mode: 'face' });
      expect((await asOperator).body).toMatchObject({ code: 'FA002' });

      const at = new Date().toISOString();
      const outside = { id: uuidV7(), user_id: operatorId, event: 'success', purpose: 'login', method: 'pin', authorized_by: null, occurred_at: at };
      const released = { ...outside, id: uuidV7(), method: 'manager_release', authorized_by: managerId };
      const results = (await push([{ kind: 'auth_event', payload: outside }, { kind: 'auth_event', payload: released }]).expect(200)).body.results as Json[];
      expect(results.map((r) => [r.status, r.code])).toEqual([['applied', null], ['applied', null]]);
      const marked = (await asManager('get', `/pdv-auth-events?alerts=1&branch=${BRANCH_CENTRO}`).expect(200)).body as Json[];
      expect(marked.find((row) => row.id === outside.id)).toMatchObject({ alert: 'outside_mode', user_name: 'Operador Centro', method: 'pin' });
      expect(marked.some((row) => row.id === released.id)).toBe(false);
      const all = (await asManager('get', '/pdv-auth-events').expect(200)).body as Json[];
      expect(all.find((row) => row.id === released.id)).toMatchObject({ alert: null, authorized_by_name: 'Gerente Centro' });
      for (const query of ['?alerts=sim', '?from=ontem', '?branch=x']) {
        expect((await asManager('get', `/pdv-auth-events${query}`).expect(422)).body).toMatchObject({ code: 'FA005' });
      }
    } finally {
      await admin('post', `/users/${operatorId}/auth-mode`).send({ mode: 'pin' }).expect(200);
    }
  });

  it('rosto: cadastro vindo do PDV, situação em Usuários e apagar', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const managerId = '019a0000-0000-7000-8000-00000000000d';
    // Código de rosto de teste (512 bytes), não é rosto de ninguém.
    const template = Buffer.alloc(512, 7).toString('base64');
    const at = new Date().toISOString();
    const enrollment = {
      id: uuidV7(), user_id: operatorId, enrolled_by: managerId, enrolled_at: at, model: 'sface-2021dec-int8', template,
      consent: { id: uuidV7(), term_version: 'biometria-v1', consented_at: at },
    };
    const results = (await push([{ kind: 'face_enrollment', payload: enrollment }]).expect(200)).body.results as Json[];
    expect(results.map((r) => [r.status, r.code])).toEqual([['applied', null]]);
    const users = (await admin('get', '/users').expect(200)).body as Json[];
    const row = users.find((u) => u.id === operatorId)!;
    expect(row).toMatchObject({ face_enrolled_by_name: 'Gerente Centro' });
    expect(row.face_enrolled_at).toBeTruthy();
    expect(JSON.stringify(users)).not.toContain(template.slice(0, 40));
    const asOperator = request(server()).post(`/admin/users/${managerId}/revoke-face`).set('X-Forwarded-For', ip)
      .set('Authorization', `Bearer ${sessions.get(OPERATOR_EMAIL)}`).send({});
    expect((await asOperator).body).toMatchObject({ code: 'FA002' });
    await admin('post', `/users/${operatorId}/revoke-face`).send({}).expect(200);
    expect((await admin('post', `/users/${operatorId}/revoke-face`).send({}).expect(404)).body).toMatchObject({ code: 'FA823' });
    const after = ((await admin('get', '/users').expect(200)).body as Json[]).find((u) => u.id === operatorId)!;
    expect(after.face_enrolled_at).toBeNull();
  });

  it('orçamento: sobe pela outbox, plaquinha, parâmetros da filial e vendedor na venda', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const number = Math.floor(Date.now() / 1000) % 900000 + 1;
    const quote = (n: number, card: number | null) => ({
      id: uuidV7(), number: n, seller_id: operatorId, customer_id: DEMO_CUSTOMER, card_number: card, quoted_at: new Date().toISOString(),
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 3, unit_price: 12.9, discount: 0.7, total: 38 }],
      subtotal: 38.7, discount_total: 0.7, total: 38,
    });
    const first = quote(number, 15);
    const second = quote(number + 1, 15);
    const results = (await push([{ kind: 'quote', payload: first }, { kind: 'quote', payload: second }, { kind: 'quote', payload: { ...quote(number + 2, null), total: 1 } }]).expect(200)).body.results as Json[];
    expect(results.map((r) => [r.status, r.code])).toEqual([['applied', null], ['applied', null], ['conflict', 'FA883']]);

    const asManager = (path: string) => request(server()).get(`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`);
    const listed = (await asManager('/quotes?status=all').expect(200)).body as Json[];
    expect(listed.find((row) => row.id === first.id)).toMatchObject({ status: 'replaced', card_number: 15 });
    expect(listed.find((row) => row.id === second.id)).toMatchObject({ status: 'open', customer_name: 'Cliente Demonstração', item_count: 1 });
    expect(((await asManager('/quotes?status=open').expect(200)).body as Json[]).map((row) => row.id)).toContain(second.id);
    const detail = (await asManager(`/quotes/${first.id}`).expect(200)).body as Json;
    expect(detail).toMatchObject({ status: 'replaced', replaced_by_code: listed.find((row) => row.id === second.id)!.code, items: [{ quantity: 3, total: 38 }] });
    for (const query of ['?status=nada', '?from=ontem', '?branch=x']) {
      expect((await asManager(`/quotes${query}`).expect(422)).body).toMatchObject({ code: 'FA005' });
    }
    expect((await asManager(`/quotes/${uuidV7()}`).expect(404)).body).toMatchObject({ code: 'FA006' });

    // No caixa: lista dos pendentes, busca pela plaquinha e pelo código; a venda fecha o orçamento.
    const asTerminal = (path: string) => request(server()).get(`/terminals/quotes${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
    const pending = (await asTerminal('').expect(200)).body as Json[];
    expect(pending.map((row) => row.id)).toContain(second.id);
    expect(pending.map((row) => row.id)).not.toContain(first.id);
    const byCard = (await asTerminal('/15').expect(200)).body as Json;
    expect(byCard).toMatchObject({ id: second.id, seller_id: operatorId, customer_id: DEMO_CUSTOMER, items: [{ product_id: DIPIRONA, quantity: 3 }] });
    const secondCode = listed.find((row) => row.id === second.id)!.code as string;
    expect((await asTerminal(`/${secondCode.toLowerCase()}`).expect(200)).body).toMatchObject({ id: second.id });
    expect((await asTerminal(`/${listed.find((row) => row.id === first.id)!.code}`).expect(422)).body).toMatchObject({ code: 'FA888' });
    expect((await asTerminal('/9999').expect(404)).body).toMatchObject({ code: 'FA885' });
    const shift = uuidV7();
    await push([{ kind: 'cash_session_open', payload: { id: shift, operator_id: operatorId, opened_at: new Date().toISOString(), opening_float: 0 } }]).expect(200);
    const saleNumber = Math.floor(Date.now() / 1000) % 900000 + 300001;
    const fromQuote = {
      id: uuidV7(), number: saleNumber, cash_session_id: shift, operator_id: operatorId, customer_id: DEMO_CUSTOMER, seller_id: operatorId,
      quote_id: second.id, sold_at: new Date().toISOString(), fiscal_model: '65',
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 3, unit_price: 12.9, discount: 0.7, total: 38 }],
      payments: [{ id: uuidV7(), method: 'pix', amount: 38 }], subtotal: 38.7, discount_total: 0.7, total: 38,
    };
    expect((await push([{ kind: 'sale', payload: fromQuote }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    expect((await asTerminal('/15').expect(404)).body).toMatchObject({ code: 'FA885' });
    expect((await asTerminal(`/${secondCode}`).expect(422)).body).toMatchObject({ code: 'FA886' });
    expect((await asManager(`/quotes/${second.id}`).expect(200)).body).toMatchObject({ status: 'converted', sale_id: fromQuote.id });
    expect((await asManager(`/sales/${fromQuote.id}`).expect(200)).body).toMatchObject({ quote_code: secondCode, seller_name: 'Operador Centro' });

    // Parâmetros da filial: quem mexe na estrutura; descem nos dados fiscais.
    const post = (body: Json, email = ADMIN_EMAIL) =>
      request(server()).post(`/admin/branches/${BRANCH_CENTRO}/sale-settings`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`).send(body);
    await post({ quoteValidityDays: 2, sellerPinRequired: true }).expect(200);
    const branches = (await request(server()).get('/admin/branches').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${session}`).expect(200)).body as Json[];
    expect(branches.find((row) => row.id === BRANCH_CENTRO)).toMatchObject({ quote_validity_days: 2, seller_pin_required: true });
    expect((await pullAll(null)).find('fiscal', BRANCH_CENTRO)?.data).toMatchObject({
      quote_validity_days: 2, seller_pin_required: true, terminal_profile: 'cashier', last_quote_number: number + 1,
    });
    for (const body of [{ quoteValidityDays: 91, sellerPinRequired: false }, { quoteValidityDays: '2', sellerPinRequired: false }, { quoteValidityDays: 1, sellerPinRequired: 'sim' }]) {
      expect((await post(body).expect(422)).body).toMatchObject({ code: 'FA884' });
    }
    expect((await post({ quoteValidityDays: 1, sellerPinRequired: false }, OPERATOR_EMAIL).expect(403)).body).toMatchObject({ code: 'FA002' });
    await post({ quoteValidityDays: 0, sellerPinRequired: false }).expect(200);

    // Perfil do terminal: vira orçamento e desce para o PDV; volta para caixa.
    const profile = (body: Json, email = ADMIN_EMAIL) =>
      request(server()).post(`/admin/terminals/${terminalId}/profile`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`).send(body);
    await profile({ profile: 'quote' }).expect(200);
    expect((await pullAll(null)).find('fiscal', BRANCH_CENTRO)?.data).toMatchObject({ terminal_profile: 'quote' });
    for (const body of [{ profile: 'balcao' }, { profile: 1 }, {}]) {
      expect((await profile(body).expect(422)).body).toMatchObject({ code: 'FA218' });
    }
    expect((await profile({ profile: 'cashier' }, OPERATOR_EMAIL).expect(403)).body).toMatchObject({ code: 'FA002' });
    await profile({ profile: 'cashier' }).expect(200);
  });

  it('devolução: venda pelo código, documento em dinheiro pago pela sangria e retaguarda', async () => {
    const push = (items: Json[]) =>
      request(server()).post('/terminals/sync/push').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`)
        .send({ items: items.map((item) => { sequence += 1; return { id: uuidV7(), sequence, ...item }; }) });
    const asTerminal = (path: string) => request(server()).get(`/terminals${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${token}`);
    const operatorId = '019a0000-0000-7000-8000-000000000009';
    const managerId = '019a0000-0000-7000-8000-00000000000d';
    const shift = uuidV7();
    await push([{ kind: 'cash_session_open', payload: { id: shift, operator_id: operatorId, opened_at: new Date().toISOString(), opening_float: 100 } }]).expect(200);
    const saleNumber = Math.floor(Date.now() / 1000) % 900000 + 500001;
    const sold = {
      id: uuidV7(), number: saleNumber, cash_session_id: shift, operator_id: operatorId, customer_id: null, seller_id: operatorId,
      sold_at: new Date().toISOString(), fiscal_model: '65',
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 2, unit_price: 12.9, discount: 0, total: 25.8 }],
      payments: [{ id: uuidV7(), method: 'cash', amount: 25.8 }], subtotal: 25.8, discount_total: 0, total: 25.8,
    };
    await push([{ kind: 'sale', payload: sold }]).expect(200);
    const saleCode = ((await asManagerGet(`/sales/${sold.id}`)).body as Json).code as string;
    const found = (await asTerminal(`/sales/${saleCode}`).expect(200)).body as Json;
    expect(found).toMatchObject({ id: sold.id, late: false, items: [{ quantity: 2, returned_quantity: 0, controlled: false }] });
    expect((await asTerminal('/sales/9-999999').expect(404)).body).toMatchObject({ code: 'FA891' });

    const refund = {
      id: uuidV7(), number: saleNumber, cash_session_id: shift, sale_id: sold.id, operator_id: operatorId, authorized_by: managerId,
      reason: 'Produto com defeito', destination: 'cash', returned_at: new Date().toISOString(),
      items: [{ id: uuidV7(), sale_item_id: sold.items[0].id, quantity: 1, amount: 12.9 }], total: 12.9,
    };
    expect((await push([{ kind: 'sale_return', payload: refund }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied', code: null });
    const listed = ((await asManagerGet('/returns')).body as Json[]).find((row) => row.id === refund.id)!;
    expect(listed).toMatchObject({ destination: 'cash', paid: false, alert: false, sale_code: saleCode });
    const document = (await asTerminal(`/returns/${listed.code}`).expect(200)).body as Json;
    expect(document).toMatchObject({ id: refund.id, total: 12.9, sale_code: saleCode });
    const payout = {
      id: uuidV7(), cash_session_id: shift, kind: 'withdrawal', amount: 12.9, reason: `Devolução ${listed.code}`, operator_id: operatorId,
      released_by: managerId, moved_at: new Date().toISOString(), return_id: refund.id,
    };
    expect((await push([{ kind: 'cash_movement', payload: payout }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    expect((await asTerminal(`/returns/${listed.code}`).expect(404)).body).toMatchObject({ code: 'FA896' });
    const detail = (await asManagerGet(`/returns/${refund.id}`)).body as Json;
    expect(detail).toMatchObject({ code: listed.code, paid_by_name: 'Operador Centro', items: [{ quantity: 1, amount: 12.9 }] });
    expect(((await asManagerGet(`/sales/${sold.id}`)).body as Json).returns).toEqual([expect.objectContaining({ code: listed.code, paid: true })]);
    expect((await request(server()).get('/admin/returns?from=ontem').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`).expect(422)).body)
      .toMatchObject({ code: 'FA005' });

    // Crédito para nova compra: o caixa acha o saldo e a venda paga com ele.
    const creditReturn = {
      ...refund, id: uuidV7(), number: saleNumber + 1, authorized_by: managerId, destination: 'credit', reason: 'Troca',
      items: [{ id: uuidV7(), sale_item_id: sold.items[0].id, quantity: 1, amount: 12.9 }],
    };
    expect((await push([{ kind: 'sale_return', payload: creditReturn }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied' });
    const creditCode = ((await asManagerGet('/returns?destination=credit')).body as Json[]).find((row) => row.id === creditReturn.id)!.code as string;
    expect((await asTerminal(`/return-credits/${creditCode}`).expect(200)).body).toMatchObject({ id: creditReturn.id, balance: 12.9 });
    const exchange = {
      ...sold, id: uuidV7(), number: saleNumber + 2,
      items: [{ id: uuidV7(), line: 1, product_id: DIPIRONA, quantity: 1, unit_price: 12.9, discount: 0, total: 12.9 }],
      payments: [{ id: uuidV7(), method: 'return_credit', amount: 12.9, return_id: creditReturn.id }],
      subtotal: 12.9, total: 12.9,
    };
    expect((await push([{ kind: 'sale', payload: exchange }]).expect(200)).body.results[0]).toMatchObject({ status: 'applied', code: null });
    expect((await asTerminal(`/return-credits/${creditCode}`).expect(404)).body).toMatchObject({ code: 'FA872' });
    const credits = (await asManagerGet('/returns?destination=credit')).body as Json[];
    expect(credits.every((row) => row.destination === 'credit')).toBe(true);
    expect(Number(credits.find((row) => row.id === creditReturn.id)!.credit_used)).toBe(12.9);
    expect(((await asManagerGet(`/sales/${exchange.id}`)).body as Json).payments[0]).toMatchObject({ method: 'return_credit', return_code: creditCode });
    expect((await request(server()).get('/admin/returns?destination=vale').set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`).expect(422)).body)
      .toMatchObject({ code: 'FA005' });

    // Prazo da filial.
    const post = (body: Json, email = ADMIN_EMAIL) =>
      request(server()).post(`/admin/branches/${BRANCH_CENTRO}/return-days`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`).send(body);
    await post({ days: 10 }).expect(200);
    expect((await pullAll(null)).find('fiscal', BRANCH_CENTRO)?.data).toMatchObject({ return_days: 10 });
    for (const body of [{ days: 400 }, { days: '10' }, {}]) {
      expect((await post(body).expect(422)).body).toMatchObject({ code: 'FA899' });
    }
    expect((await post({ days: 5 }, OPERATOR_EMAIL).expect(403)).body).toMatchObject({ code: 'FA002' });
    await post({ days: 7 }).expect(200);
  });

  const asManagerGet = (path: string) =>
    request(server()).get(`/admin${path}`).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(MANAGER_EMAIL)}`).expect(200);

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
