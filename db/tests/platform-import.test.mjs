import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setUser } from './helpers.mjs';

// Importação de notas pela Plataforma: o administrador da plataforma escolhe o cliente e o arquivo
// entra no grupo dele, pelas mesmas funções da importação feita pelo próprio cliente.

let a;
let b;
let platform;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  // O administrador da plataforma fica no grupo b (onde também administra).
  platform = b.admin;
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [platform.id]);
});
afterAll(closePools);

/** Uma transação confirmada como o usuário, com a escolha de cliente opcional antes de cada chamada. */
async function as(user, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, user.id);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const one = async (client, sql, params = []) => (await client.query(sql, params)).rows[0];
const groupOf = async (id) => (await ownerPool.query('SELECT economic_group_id, created_by FROM document_import WHERE id = $1', [id])).rows[0];

describe('importação de notas pela Plataforma', () => {
  it('o administrador da plataforma escolhe o cliente: o arquivo entra no grupo dele, do envio ao relatório', async () => {
    const id = await as(platform, async (client) => {
      await client.query('SELECT app.use_import_group($1)', [a.group.id]);
      return (await one(client, 'SELECT app.create_document_import($1, $2) AS id', ['cliente.zip', 20])).id;
    });
    expect(await groupOf(id)).toEqual({ economic_group_id: a.group.id, created_by: platform.id });

    // Partes, conclusão e relatório pela importação (o grupo vem dela).
    await as(platform, async (client) => {
      expect((await one(client, 'SELECT app.use_import_of($1) AS g', [id])).g).toBe(a.group.id);
      expect(Number((await one(client, 'SELECT app.document_import_part($1, 1, 20) AS n', [id])).n)).toBe(20);
      await client.query('SELECT app.complete_document_import($1)', [id]);
      expect((await one(client, 'SELECT app.document_import_report($1) AS r', [id])).r).toMatchObject({ id, status: 'queued' });
    });

    // A lista do cliente escolhido traz o arquivo; a do próprio grupo do administrador, não.
    const chosen = await as(platform, async (client) => {
      await client.query('SELECT app.use_import_group($1)', [a.group.id]);
      return (await client.query('SELECT id FROM app.list_document_imports()')).rows.map((r) => r.id);
    });
    expect(chosen).toContain(id);
    const own = await as(platform, async (client) => (await client.query('SELECT id FROM app.list_document_imports()')).rows.map((r) => r.id));
    expect(own).not.toContain(id);

    // O administrador do cliente vê a importação feita pela Plataforma.
    const client = await as(a.admin, async (c) => (await c.query('SELECT id FROM app.list_document_imports()')).rows.map((r) => r.id));
    expect(client).toContain(id);
  });

  it('sem escolher o cliente, tudo continua no grupo de quem está logado', async () => {
    const mine = await as(platform, (client) => one(client, 'SELECT app.create_document_import($1, $2) AS id', ['meu.zip', 10]));
    expect((await groupOf(mine.id)).economic_group_id).toBe(b.group.id);
    const theirs = await as(a.admin, (client) => one(client, 'SELECT app.create_document_import($1, $2) AS id', ['deles.zip', 10]));
    expect((await groupOf(theirs.id)).economic_group_id).toBe(a.group.id);
    // A escolha vale só para a transação.
    await as(platform, (client) => client.query('SELECT app.use_import_group($1)', [a.group.id]));
    const next = await as(platform, (client) => one(client, 'SELECT app.create_document_import($1, $2) AS id', ['depois.zip', 10]));
    expect((await groupOf(next.id)).economic_group_id).toBe(b.group.id);
  });

  it('só o administrador da plataforma escolhe o cliente, nem pela configuração da sessão', async () => {
    await expect(as(a.admin, (client) => client.query('SELECT app.use_import_group($1)', [b.group.id]))).rejects.toSatisfy(hasCode('FA002'));
    const theirs = await as(b.secondAdmin, (client) => one(client, 'SELECT app.create_document_import($1, $2) AS id', ['b.zip', 10]));
    await expect(as(a.admin, (client) => client.query('SELECT app.use_import_of($1)', [theirs.id]))).rejects.toSatisfy(hasCode('FA002'));
    // Quem tenta marcar o grupo direto na sessão também é barrado.
    await expect(as(a.admin, async (client) => {
      await client.query("SELECT set_config('app.import_group', $1, true)", [b.group.id]);
      return client.query('SELECT app.create_document_import($1, $2)', ['x.zip', 10]);
    })).rejects.toSatisfy(hasCode('FA002'));
    await expect(as(a.admin, async (client) => {
      await client.query("SELECT set_config('app.import_group', $1, true)", [b.group.id]);
      return client.query('SELECT app.document_import_report($1)', [theirs.id]);
    })).rejects.toSatisfy(hasCode('FA002'));
  });

  it('cliente ou importação que não existe é recusado com FA006', async () => {
    await expect(as(platform, (client) => client.query('SELECT app.use_import_group($1)', [randomUUID()]))).rejects.toSatisfy(hasCode('FA006'));
    await expect(as(platform, (client) => client.query('SELECT app.use_import_of($1)', [randomUUID()]))).rejects.toSatisfy(hasCode('FA006'));
  });

  it('a importação de um cliente não serve para outro escolhido', async () => {
    const theirs = await as(a.admin, (client) => one(client, 'SELECT app.create_document_import($1, $2) AS id', ['a.zip', 10]));
    await expect(as(platform, async (client) => {
      await client.query('SELECT app.use_import_group($1)', [b.group.id]);
      return client.query('SELECT app.document_import_report($1)', [theirs.id]);
    })).rejects.toSatisfy(hasCode('FA006'));
  });
});
