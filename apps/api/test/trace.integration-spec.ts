// Segue uma requisição real do cabeçalho até o log e a linha no banco.
// Requer o PostgreSQL local com migrations e seed aplicados.
import {
  Body,
  Controller,
  Inject,
  INestApplication,
  Module,
  Post,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { join } from 'node:path';
import { Writable } from 'node:stream';
import request from 'supertest';
import { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { DatabaseService } from './../src/database.service.js';
import {
  AppLogger,
  createPinoLogger,
} from './../src/observability/app-logger.js';

try {
  process.loadEnvFile(join(import.meta.dirname, '..', '..', '..', '.env'));
} catch {
  // Sem arquivo .env, valem as variáveis do ambiente.
}

const ADMIN = '019a0000-0000-7000-8000-000000000008';
const OPERATOR = '019a0000-0000-7000-8000-000000000009';
const COMPANY = '019a0000-0000-7000-8000-000000000002';
const BRANCH_GROUP = '019a0000-0000-7000-8000-000000000003';
const REGION = '019a0000-0000-7000-8000-000000000004';
const TRACE = '019a0000-0000-7000-8000-0000000000c1';

class RollbackSignal extends Error {}

// Rotas só de teste: tudo é desfeito e o seed não muda.
@Controller('__test')
class TestController {
  constructor(
    @Inject(DatabaseService) private readonly database: DatabaseService,
  ) {}

  @Post('touch-region')
  async touchRegion() {
    let captured: unknown;
    await this.database
      .withContext(
        async (client) => {
          const { rows } = await client.query(
            `UPDATE region SET name = name WHERE id = $1 RETURNING trace_id, updated_by`,
            [REGION],
          );
          const { rows: settings } = await client.query(
            `SELECT current_setting('application_name') AS application_name`,
          );
          captured = { ...rows[0], ...settings[0] };
          throw new RollbackSignal();
        },
        { userId: ADMIN },
      )
      .catch((error: unknown) => {
        if (!(error instanceof RollbackSignal)) throw error;
      });
    return captured;
  }

  @Post('sql')
  async sql(
    @Body() body: { sql: string; params?: unknown[]; userId?: string },
  ) {
    return this.database.withContext(
      async (client) => {
        const { rows } = await client.query(body.sql, body.params);
        return rows;
      },
      { userId: body.userId },
    );
  }

  @Post('unexpected')
  unexpected() {
    throw new Error('falha interna com segredo-tecnico');
  }
}

@Module({ imports: [AppModule], controllers: [TestController] })
class TestModule {}

describe('rastreio e erros contra o banco real', () => {
  let app: INestApplication<App>;
  let logs: Record<string, unknown>[];

  const post = (path: string, body?: object) =>
    request(app.getHttpServer())
      .post(`/__test/${path}`)
      .set('X-Trace-Id', TRACE)
      .send(body);

  beforeAll(async () => {
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        logs.push(JSON.parse(chunk.toString()) as Record<string, unknown>);
        callback();
      },
    });
    const moduleFixture = await Test.createTestingModule({
      imports: [TestModule],
    })
      .overrideProvider(AppLogger)
      .useValue(new AppLogger(createPinoLogger(destination)))
      .compile();
    moduleFixture.useLogger(false);
    app = moduleFixture.createNestApplication();
    await app.init();
  });

  beforeEach(() => {
    logs = [];
  });

  afterAll(async () => {
    await app.close();
  });

  it('o mesmo ID chega à resposta, ao log, à linha e ao application_name', async () => {
    const response = await post('touch-region').expect(201);

    expect(response.headers['x-trace-id']).toBe(TRACE);
    expect(response.body).toEqual({
      trace_id: TRACE,
      updated_by: ADMIN,
      application_name: `api:${TRACE}`,
    });
    expect(logs.at(-1)).toMatchObject({ trace_id: TRACE, status: 201 });
  });

  it('o contexto não vaza para a transação seguinte no pool', async () => {
    await post('touch-region').expect(201);

    // Sem cabeçalho: outro ID. Sem usuário: a RLS não libera nada.
    const response = await request(app.getHttpServer())
      .post('/__test/sql')
      .send({
        sql: `SELECT current_setting('app.user_id', true) AS user_id,
                     current_setting('app.trace_id', true) AS trace_id,
                     (SELECT count(*)::int FROM branch) AS branches`,
      })
      .expect(201);

    expect(response.body[0]).toEqual({
      user_id: '',
      trace_id: response.headers['x-trace-id'],
      branches: 0,
    });
    expect(response.headers['x-trace-id']).not.toBe(TRACE);
  });

  it('erro de trigger vira o código do catálogo, e o detalhe fica no log', async () => {
    const response = await post('sql', {
      sql: 'UPDATE region SET deleted_at = now() WHERE id = $1',
      params: [REGION],
      userId: ADMIN,
    }).expect(409);

    expect(response.body).toEqual({
      code: 'FA105',
      message: 'Este registro ainda tem itens ativos vinculados.',
      action: 'Exclua ou mova esses itens primeiro.',
      retryable: false,
      traceId: TRACE,
    });
    expect(JSON.stringify(response.body)).not.toContain('filhos ativos');

    const log = logs.find((entry) => entry.error_code === 'FA105');
    expect(log).toMatchObject({ trace_id: TRACE });
    expect(JSON.stringify(log)).toContain('filhos ativos');
  });

  it('constraint de negócio vira o código próprio', async () => {
    const response = await post('sql', {
      sql: `INSERT INTO branch (company_id, name, cnpj) VALUES ($1, 'Duplicada', '11222333000181')`,
      params: [COMPANY],
      userId: ADMIN,
    }).expect(409);

    expect(response.body).toMatchObject({ code: 'FA212', traceId: TRACE });
    expect(JSON.stringify(response.body)).not.toContain(
      'branch_cnpj_active_key',
    );
  });

  it('o valor duplicado não vai para o log', async () => {
    await post('sql', {
      sql: `INSERT INTO branch (company_id, name, cnpj) VALUES ($1, 'Duplicada', '11222333000181')`,
      params: [COMPANY],
      userId: ADMIN,
    }).expect(409);

    const log = logs.find((entry) => entry.error_code === 'FA212');
    expect(JSON.stringify(log)).toContain('branch_cnpj_active_key');
    expect(JSON.stringify(log)).not.toContain('Key (cnpj)');
  });

  it('negação da RLS vira falta de permissão', async () => {
    const response = await post('sql', {
      sql: `INSERT INTO region (branch_group_id, name) VALUES ($1, 'Sem permissão')`,
      params: [BRANCH_GROUP],
      userId: OPERATOR,
    }).expect(403);

    expect(response.body).toMatchObject({ code: 'FA002', traceId: TRACE });
    expect(JSON.stringify(response.body)).not.toContain('row-level security');
  });

  it('erro desconhecido vira FA000, sem detalhe na resposta', async () => {
    const response = await post('unexpected').expect(500);

    expect(response.body).toMatchObject({ code: 'FA000', traceId: TRACE });
    expect(JSON.stringify(response.body)).not.toContain('segredo-tecnico');

    const log = logs.find((entry) => entry.error_code === 'FA000');
    expect(log).toMatchObject({ level: 'error', trace_id: TRACE });
    expect(JSON.stringify(log)).toContain('segredo-tecnico');
  });

  it('SQL inválido vira FA000', async () => {
    const response = await post('sql', {
      sql: 'SELEC 1',
      userId: ADMIN,
    }).expect(500);
    expect(response.body).toMatchObject({ code: 'FA000' });
    expect(JSON.stringify(response.body)).not.toContain('syntax');
  });

  it('nada foi gravado após erros: a conexão volta limpa para o pool', async () => {
    const response = await post('sql', {
      sql: 'SELECT txid_current_if_assigned() AS assigned',
      userId: ADMIN,
    }).expect(201);
    expect(response.body[0].assigned).toBeNull();
  });
});
