import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, closePools, createFixtures, hasCode, ownerPool, setTerminal, setUser } from './helpers.mjs';

// Versões do PDV: envio pelo CI, liberação gradual pelo administrador da plataforma, anel de cada
// terminal e o que o terminal fez com a versão.

let a;
let b;
let platform;
const signature = () => `${randomBytes(64).toString('base64').slice(0, 86)}==`;
const sha = () => randomBytes(32).toString('hex');
// Versões únicas por execução (o banco de teste não é zerado entre execuções).
const major = randomInt(100, 9000);
const v = (patch) => `${major}.0.${patch}`;

async function run(setup, sql, params = []) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setup(client);
    const { rows } = await client.query(sql, params);
    await client.query('COMMIT');
    return rows;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
const asUser = (user, sql, params) => run((c) => setUser(c, user.id), sql, params);
const asWorker = (sql, params) => run((c) => c.query("SELECT set_config('app.user_id', '', true), set_config('app.worker', 'release', true)"), sql, params);
const asTerminal = (terminal, sql, params) => run((c) => setTerminal(c, terminal.id), sql, params);
const publish = (version, extra = {}) => asWorker('SELECT app.register_release($1::jsonb) AS id', [JSON.stringify({
  app: 'pdv', platform: 'windows', version, fileName: `FarmaERP-PDV-Setup-${version}.exe`, size: 1234, sha256: sha(), signature: signature(),
  notes: 'Teste', ...extra,
})]).then((r) => r[0].id);
const check = (terminal, current = v(0)) => asTerminal(terminal, 'SELECT app.terminal_update_check($1, $2) AS r', ['windows', current]).then((r) => r[0].r);

beforeAll(async () => {
  ({ a, b } = await createFixtures());
  platform = (await ownerPool.query('INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *', [a.group.id, `Plataforma ${randomBytes(3).toString('hex')}`])).rows[0];
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [platform.id]);
});
afterAll(closePools);

describe('versões do PDV', () => {
  it('só o envio do CI registra; versão repetida ou fora do formato é recusada', async () => {
    await expect(asUser(a.admin, 'SELECT app.register_release($1::jsonb)', [JSON.stringify({ app: 'pdv' })])).rejects.toSatisfy(hasCode('FA002'));
    await expect(run(async () => {}, 'SELECT app.register_release($1::jsonb)', [JSON.stringify({ app: 'pdv' })])).rejects.toSatisfy(hasCode('FA002'));
    await publish(v(1));
    await expect(publish(v(1))).rejects.toSatisfy(hasCode('FA874'));
    await expect(publish(v(2), { sha256: 'abc' })).rejects.toSatisfy(hasCode('FA869'));
    await expect(publish('1.2', {})).rejects.toSatisfy(hasCode('FA869'));
    expect((await ownerPool.query("SELECT app.version_rank('1.2.10') > app.version_rank('1.2.9') AND app.version_rank('2.0.0') > app.version_rank('1.10.0') AND app.version_rank('1.0.0') > app.version_rank('0.99.99') AS ok")).rows[0].ok).toBe(true);
  });

  it('teste primeiro, depois a rede; retirada some; o terminal não recebe de novo a que desfez', async () => {
    const id = await publish(v(5));
    // Terminal da rede não vê a versão de teste.
    expect(await check(a.terminal1)).toBeNull();
    await expect(asUser(a.oneBranchUser, 'SELECT app.set_terminal_update_ring($1, $2)', [a.terminal1.id, 'test'])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(b.admin, 'SELECT app.set_terminal_update_ring($1, $2)', [a.terminal1.id, 'test'])).rejects.toSatisfy(hasCode('FA002'));
    await expect(asUser(a.admin, 'SELECT app.set_terminal_update_ring($1, $2)', [a.terminal1.id, 'beta'])).rejects.toSatisfy(hasCode('FA878'));
    await asUser(a.admin, 'SELECT app.set_terminal_update_ring($1, $2)', [a.terminal1.id, 'test']);
    const offered = await check(a.terminal1);
    expect(offered).toMatchObject({ id, version: v(5), fileName: `FarmaERP-PDV-Setup-${v(5)}.exe`, size: 1234 });
    expect(await check(a.terminal1, v(5))).toBeNull();
    expect(await check(a.terminal1, v(6))).toBeNull();
    await expect(asTerminal(a.terminal2, 'SELECT app.terminal_release_file($1)', [id])).rejects.toSatisfy(hasCode('FA875'));
    expect((await asTerminal(a.terminal1, 'SELECT app.terminal_release_file($1) AS r', [id]))[0].r).toMatchObject({ version: v(5), size: 1234 });

    // Liberação: só o administrador da plataforma, e só para a frente.
    await expect(asUser(a.admin, 'SELECT app.set_release_status($1, $2)', [id, 'general'])).rejects.toSatisfy(hasCode('FA002'));
    await asUser(platform, 'SELECT app.set_release_status($1, $2)', [id, 'general']);
    await expect(asUser(platform, 'SELECT app.set_release_status($1, $2)', [id, 'test'])).rejects.toSatisfy(hasCode('FA877'));
    expect(await check(a.terminal2)).toMatchObject({ id });

    // O terminal 2 aplicou e precisou voltar: não recebe mais esta versão.
    await asTerminal(a.terminal2, 'SELECT app.record_terminal_update($1, $2, $3)', [id, 'downloaded', null]);
    await asTerminal(a.terminal2, 'SELECT app.record_terminal_update($1, $2, $3)', [id, 'rolled_back', 'Migração do banco local falhou']);
    expect(await check(a.terminal2)).toBeNull();
    await expect(asTerminal(a.terminal2, 'SELECT app.record_terminal_update($1, $2, $3)', [id, 'whatever', null])).rejects.toSatisfy(hasCode('FA869'));
    const monitor = await asUser(a.admin, 'SELECT * FROM v_terminal_monitor WHERE id = $1', [a.terminal2.id]);
    expect(monitor[0]).toMatchObject({ update_ring: 'general', last_update_status: 'rolled_back', last_update_version: v(5), last_update_detail: 'Migração do banco local falhou' });
    expect(await asUser(b.admin, 'SELECT * FROM v_terminal_update_event WHERE terminal_id = $1', [a.terminal2.id])).toEqual([]);

    const list = await asUser(platform, 'SELECT * FROM app.list_releases()');
    expect(list.find((r) => r.id === id)).toMatchObject({ status: 'general', rolled_back: 1, applied: 0 });
    await expect(asUser(a.admin, 'SELECT * FROM app.list_releases()')).rejects.toSatisfy(hasCode('FA002'));

    // A versão mais nova de teste aparece para o terminal de teste; retirada some.
    const newer = await publish(v(7));
    expect(await check(a.terminal1)).toMatchObject({ id: newer });
    expect(await check(a.terminal2)).toBeNull();
    await asUser(platform, 'SELECT app.set_release_status($1, $2)', [newer, 'withdrawn']);
    await expect(asUser(platform, 'SELECT app.set_release_status($1, $2)', [newer, 'general'])).rejects.toSatisfy(hasCode('FA877'));
    expect(await check(a.terminal1)).toMatchObject({ id });
    await expect(asTerminal(a.terminal1, 'SELECT app.terminal_release_file($1)', [newer])).rejects.toSatisfy(hasCode('FA875'));
    await expect(ownerPool.query('UPDATE app_release SET sha256 = $1 WHERE id = $2', [sha(), id])).rejects.toSatisfy(hasCode('FA104'));
  });

  it('terminal bloqueado não consulta', async () => {
    await ownerPool.query("UPDATE terminal SET status = 'blocked' WHERE id = $1", [b.terminal1.id]);
    await expect(check(b.terminal1)).rejects.toThrow();
  });
});
