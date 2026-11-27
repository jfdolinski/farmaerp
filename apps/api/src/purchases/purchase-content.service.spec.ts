import { Writable } from 'node:stream';
import { buildNfe } from '../../test/nfe-fixture.js';
import { DatabaseService } from '../database.service.js';
import { AppLogger, createPinoLogger } from '../observability/app-logger.js';
import { PurchaseContentService } from './purchase-content.service.js';

type Query = { sql: string; params: unknown[] };

/** Banco falso: a fila devolve as notas informadas uma vez; a gravação pode falhar com o erro dado. */
function fakeDatabase(pending: { id: string; xml: string }[], storeError?: unknown) {
  const queries: Query[] = [];
  let served = false;
  const client = {
    query: async (sql: string, params: unknown[] = []) => {
      queries.push({ sql, params });
      if (sql.includes('purchase_content_pending')) {
        const q = served ? [] : pending;
        served = true;
        return { rows: [{ q }] };
      }
      if (sql.includes('store_purchase_content') && storeError) throw storeError;
      return { rows: [] };
    },
  };
  const database = { withContext: async (fn: (c: typeof client) => unknown) => fn(client) } as unknown as DatabaseService;
  return { database, queries };
}
const silent = new AppLogger(createPinoLogger(new Writable({ write: (_c, _e, cb) => cb() })));
const failures = (queries: Query[]) => queries.filter((q) => q.sql.includes('purchase_content_failed')).map((q) => q.params);
const stores = (queries: Query[]) => queries.filter((q) => q.sql.includes('store_purchase_content'));

describe('rotina que lê as notas de compra guardadas', () => {
  it('grava o conteúdo e as duplicatas das notas da fila', async () => {
    const nfe = buildNfe({ beforeSign: (x) => x.replace('</total>', '</total><cobr><dup><nDup>1</nDup><dVenc>2026-12-01</dVenc><vDup>21.00</vDup></dup></cobr>') });
    const { database, queries } = fakeDatabase([{ id: 'a', xml: nfe.xml }]);
    expect(await new PurchaseContentService(database, silent).tick()).toEqual({ read: 1, failed: 0 });
    const [store] = stores(queries);
    expect(store.params[0]).toBe('a');
    expect(JSON.parse(store.params[1] as string)).toMatchObject({ ide: { mod: '55' } });
    expect(JSON.parse(store.params[2] as string)).toEqual([{ number: '1', dueDate: '2026-12-01', amount: '21.00' }]);
    expect(failures(queries)).toEqual([]);
  });

  it('XML que não se lê marca a falha com o motivo técnico e segue para a próxima', async () => {
    const good = buildNfe();
    const { database, queries } = fakeDatabase([{ id: 'ruim', xml: '<nfeProc/>' }, { id: 'boa', xml: good.xml }]);
    expect(await new PurchaseContentService(database, silent).tick()).toEqual({ read: 1, failed: 1 });
    expect(failures(queries)).toEqual([['ruim', 'XML não lido: a raiz não é nfeProc']]);
  });

  it('conteúdo recusado pelo banco marca a falha com o código', async () => {
    const { database, queries } = fakeDatabase([{ id: 'a', xml: buildNfe().xml }], Object.assign(new Error('x'), { code: 'FA005' }));
    expect(await new PurchaseContentService(database, silent).tick()).toEqual({ read: 0, failed: 1 });
    expect(failures(queries)).toEqual([['a', 'Conteúdo recusado pelo banco (FA005).']]);
  });

  it.each([
    ['conexão', Object.assign(new Error('x'), { code: 'ECONNREFUSED' })],
    ['tempo esgotado', Object.assign(new Error('x'), { code: '57014' })],
    ['sem código', new Error('inesperado')],
  ])('falha passageira (%s) não marca a nota e interrompe a rodada', async (_name, error) => {
    const { database, queries } = fakeDatabase([{ id: 'a', xml: buildNfe().xml }, { id: 'b', xml: buildNfe().xml }], error);
    expect(await new PurchaseContentService(database, silent).tick()).toBeNull();
    expect(failures(queries)).toEqual([]);
    expect(stores(queries)).toHaveLength(1);
  });

  it('a fila cheia busca de novo dentro do tempo; a vazia para', async () => {
    const xml = buildNfe().xml;
    const full = Array.from({ length: 20 }, (_, i) => ({ id: String(i), xml }));
    const { database, queries } = fakeDatabase(full);
    expect(await new PurchaseContentService(database, silent).tick()).toEqual({ read: 20, failed: 0 });
    expect(queries.filter((q) => q.sql.includes('purchase_content_pending'))).toHaveLength(2);
    expect(queries[0].params).toEqual([20]);
  });

  it('sem tempo, não busca de novo', async () => {
    const xml = buildNfe().xml;
    const full = Array.from({ length: 20 }, (_, i) => ({ id: String(i), xml }));
    const { database, queries } = fakeDatabase(full);
    await new PurchaseContentService(database, silent).tick(0);
    expect(queries.filter((q) => q.sql.includes('purchase_content_pending'))).toHaveLength(1);
  });

  it('uma rodada por vez', async () => {
    const { database } = fakeDatabase([{ id: 'a', xml: buildNfe().xml }]);
    const service = new PurchaseContentService(database, silent);
    const [first, second] = await Promise.all([service.tick(), service.tick()]);
    expect(first).toEqual({ read: 1, failed: 0 });
    expect(second).toBeNull();
  });

  it('desliga com PURCHASE_CONTENT_WORKER=off', () => {
    const previous = process.env.PURCHASE_CONTENT_WORKER;
    process.env.PURCHASE_CONTENT_WORKER = 'off';
    const spy = vi.spyOn(global, 'setInterval');
    try {
      new PurchaseContentService(fakeDatabase([]).database, silent).onApplicationBootstrap();
      expect(spy).not.toHaveBeenCalled();
    } finally {
      spy.mockRestore();
      process.env.PURCHASE_CONTENT_WORKER = previous;
    }
  });
});
