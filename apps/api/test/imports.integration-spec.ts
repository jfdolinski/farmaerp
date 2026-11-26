// Importação das notas do sistema anterior pela API contra o banco real: envio em partes, fila,
// processamento do .zip e relatório. O .zip é montado aqui (entradas sem compressão).
import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { randomInt } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import { crc32 } from 'node:zlib';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { ImportsService } from './../src/imports/imports.service.js';
import { cancelXml, KEY, NFE_KEY, nfceXml, nfeXml } from './import-fixtures.js';
import { AppLogger, createPinoLogger } from './../src/observability/app-logger.js';

const PASSWORD = 'farmaerp-dev-123';
const ADMIN = 'admin@farmaerp.test';
const OPERATOR = 'operador@farmaerp.test';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** .zip mínimo (método "stored"): cabeçalhos locais, diretório central e o fim. */
function zip(files: [string, string][]): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, text] of files) {
    const data = Buffer.from(text, 'utf8');
    const fileName = Buffer.from(name, 'utf8');
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x0800, 6);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(fileName.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(data.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(fileName.length, 28);
    central.writeUInt32LE(offset, 42);
    locals.push(local, fileName, data);
    centrals.push(central, fileName);
    offset += local.length + fileName.length + data.length;
  }
  const centralSize = centrals.reduce((sum, part) => sum + part.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(files.length, 8);
  end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, ...centrals, end]);
}

describe('importação das notas contra o banco real', () => {
  let app: INestApplication<App>;
  let dir: string;
  const sessions = new Map<string, string>();
  const ip = `10.${randomInt(255)}.${randomInt(255)}.${randomInt(255)}`;
  const previous = { ...process.env };
  const call = (method: 'get' | 'post' | 'put', path: string, email = ADMIN) =>
    request(app.getHttpServer())[method](path).set('X-Forwarded-For', ip).set('Authorization', `Bearer ${sessions.get(email)}`);
  const codeOf = (response: request.Response) => (response.body as Json).code as string;

  beforeAll(async () => {
    dir = mkdtempSync(join(tmpdir(), 'farmaerp-imports-'));
    process.env.IMPORTS_DIR = dir;
    process.env.IMPORTS_WORKER = 'off';
    const destination = new Writable({ write(_chunk: Buffer, _encoding, callback) { callback(); } });
    const moduleFixture = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(AppLogger).useValue(new AppLogger(createPinoLogger(destination))).compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
    await app.init();
    for (const email of [ADMIN, OPERATOR]) {
      sessions.set(email, ((await request(app.getHttpServer()).post('/auth/login').set('X-Forwarded-For', ip)
        .send({ email, password: PASSWORD }).expect(200)).body as Json).token as string);
    }
  });

  afterAll(async () => {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
    process.env = previous;
  });

  it('envia em partes, processa o .zip e o relatório mostra o que entrou e o que ficou de fora', async () => {
    // Chave e códigos novos a cada execução (o banco de desenvolvimento não é zerado).
    const key = `${KEY.slice(0, 25)}${String(randomInt(1e9)).padStart(9, '0')}${KEY.slice(34)}`;
    const cancelKey = `${KEY.slice(0, 25)}${String(randomInt(1e9)).padStart(9, '0')}${KEY.slice(34)}`;
    const codeA = `IMP${randomInt(1e9)}`;
    const purchaseKey = `${NFE_KEY.slice(0, 25)}${String(randomInt(1e9)).padStart(9, '0')}${NFE_KEY.slice(34)}`;
    const note = (k: string) => nfceXml().split(KEY).join(k).replace('<cProd>000123</cProd>', `<cProd>${codeA}</cProd>`)
      .replace('<cProd>B-9</cProd>', `<cProd>${codeA}B</cProd>`).replace('<cEAN>7891234567895</cEAN>', '<cEAN>SEM GTIN</cEAN>');
    const content = zip([
      ['2026/06/nota.xml', note(key)],
      ['2026/06/outra.xml', note(cancelKey)],
      ['2026/06/cancelada.xml', cancelXml().split(KEY).join(cancelKey)],
      ['2026/06/nfe55.xml', nfceXml({ model: '55' }).split(KEY).join(key.replace(/65(001)/, '55$1'))],
      // Compra do fornecedor para a filial do seed (vem antes no arquivo, mas é lida na segunda passada).
      ['compras/nfe-compra.xml', nfeXml({ key: purchaseKey })],
      ['leia-me.txt', 'arquivo que não é nota'],
    ]);

    expect(codeOf(await call('post', '/admin/imports', OPERATOR).send({ fileName: 'notas.zip', size: content.length }).expect(403))).toBe('FA002');
    expect(codeOf(await call('post', '/admin/imports').send({ fileName: 'notas.rar', size: content.length }).expect(422))).toBe('FA740');
    const { id } = (await call('post', '/admin/imports').send({ fileName: 'notas.zip', size: content.length }).expect(201)).body as { id: string };
    const half = Math.floor(content.length / 2);
    const put = (part: number, body: Buffer) =>
      call('put', `/admin/imports/${id}/parts/${part}`).set('Content-Type', 'application/octet-stream').send(body);
    expect(codeOf(await put(2, content.subarray(half)).expect(409))).toBe('FA741');
    expect((await put(1, content.subarray(0, half)).expect(200)).body).toEqual({ received: half });
    expect(codeOf(await call('post', `/admin/imports/${id}/complete`).expect(409))).toBe('FA741');
    await put(2, content.subarray(half)).expect(200);
    await call('post', `/admin/imports/${id}/complete`).expect(200);

    // Processa a fila até chegar neste arquivo.
    const service = app.get(ImportsService);
    for (let i = 0; i < 20; i += 1) {
      await service.tick();
      const status = ((await call('get', `/admin/imports/${id}`).expect(200)).body as Json).status as string;
      if (status === 'done' || status === 'failed') break;
    }
    const report = (await call('get', `/admin/imports/${id}`).expect(200)).body as Json;
    expect(report).toMatchObject({
      status: 'done',
      // A NF-e 55 emitida pela loja para CPF é venda; a compra entra no estoque.
      totals: { entries: 6, imported: 4, canceled: 1, ignored: 1, failed: 0, models: { '65': 2, '55': 2 } },
      problems: [],
      last_numbers: expect.arrayContaining([
        expect.objectContaining({ branch_name: 'Loja Centro', model: '65', series: 1 }),
        expect.objectContaining({ branch_name: 'Loja Centro', model: '55', series: 1 }),
      ]),
    });
    expect(((await call('get', '/admin/imports').expect(200)).body as Json[]).map((row) => row.id)).toContain(id);

    // A venda importada aparece na consulta, com o detalhe e o XML.
    const sales = (await call('get', '/admin/imported-sales?from=2026-06-10&to=2026-06-10').expect(200)).body as Json[];
    let found: Json | null = null;
    for (const row of sales) {
      const detail = (await call('get', `/admin/imported-sales/${row.id as string}`).expect(200)).body as Json;
      if (detail.access_key === key) {
        found = detail;
        break;
      }
    }
    expect(found).toMatchObject({ number: 42, model: '65', canceled_at: null, items: [{ legacy_code: codeA }, { legacy_code: `${codeA}B` }] });
    const xml = await call('get', `/admin/imported-sales/${found?.id as string}/xml`).expect(200);
    expect(xml.headers['content-type']).toContain('application/xml');
    expect(xml.headers['content-disposition']).toContain(`NFCe-${key}.xml`);
    expect(xml.text).toContain('<nfeProc');
    expect(codeOf(await call('get', '/admin/imported-sales?from=10-06-2026').expect(422))).toBe('FA005');

    // A compra em NF-e aparece nas notas importadas, com o item ligado ao código do fornecedor.
    const notes = (await call('get', '/admin/imported-notes?from=2026-05-02&to=2026-05-02&kind=purchase').expect(200)).body as Json[];
    let purchase: Json | null = null;
    for (const row of notes) {
      const detail = (await call('get', `/admin/imported-notes/${row.id as string}`).expect(200)).body as Json;
      if (detail.access_key === purchaseKey) {
        purchase = detail;
        break;
      }
    }
    expect(purchase).toMatchObject({ kind: 'purchase', supplier_name: 'DISTRIBUIDORA EXEMPLO SA', items: [{ supplier_code: 'FORN-77', note_quantity: 3 }] });
    const nfeFile = await call('get', `/admin/imported-notes/${purchase?.id as string}/xml`).expect(200);
    expect(nfeFile.headers['content-disposition']).toContain(`NFe-${purchaseKey}.xml`);
    expect(codeOf(await call('get', '/admin/imported-notes?kind=venda').expect(422))).toBe('FA005');
    expect(codeOf(await call('get', '/admin/imported-sales/01900000-0000-7000-8000-000000000000').expect(404))).toBe('FA006');

    // O mesmo arquivo de novo: tudo repetido.
    const again = (await call('post', '/admin/imports').send({ fileName: 'notas.zip', size: content.length }).expect(201)).body as { id: string };
    await call('put', `/admin/imports/${again.id}/parts/1`).set('Content-Type', 'application/octet-stream').send(content).expect(200);
    await call('post', `/admin/imports/${again.id}/complete`).expect(200);
    for (let i = 0; i < 20; i += 1) {
      await service.tick();
      if (((await call('get', `/admin/imports/${again.id}`).expect(200)).body as Json).status === 'done') break;
    }
    expect(((await call('get', `/admin/imports/${again.id}`).expect(200)).body as Json).totals).toMatchObject({ imported: 0, duplicate: 4 });
  });

  it('arquivo que não é .zip termina com falha e o motivo', async () => {
    const content = Buffer.from('não é um zip');
    const { id } = (await call('post', '/admin/imports').send({ fileName: 'quebrado.zip', size: content.length }).expect(201)).body as { id: string };
    await call('put', `/admin/imports/${id}/parts/1`).set('Content-Type', 'application/octet-stream').send(content).expect(200);
    await call('post', `/admin/imports/${id}/complete`).expect(200);
    const service = app.get(ImportsService);
    for (let i = 0; i < 20; i += 1) {
      await service.tick();
      if (((await call('get', `/admin/imports/${id}`).expect(200)).body as Json).status !== 'queued') break;
    }
    expect((await call('get', `/admin/imports/${id}`).expect(200)).body).toMatchObject({ status: 'failed', error: 'Arquivo .zip inválido ou corrompido.' });
  });
});
