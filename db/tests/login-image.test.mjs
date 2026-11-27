import { createHash, randomBytes } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, asUser, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

let a;
let platform;

beforeAll(async () => {
  ({ a } = await createFixtures());
  platform = a.admin;
  await ownerPool.query('INSERT INTO platform_admin (user_id) VALUES ($1)', [platform.id]);
});
afterAll(closePools);

const jpeg = () => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), randomBytes(200)]);
const png = () => Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), randomBytes(200)]);
const webp = () => {
  const body = randomBytes(200);
  return Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBP'), body]);
};
const sha = (buffer) => createHash('sha256').update(buffer).digest('hex');

const set = (client, mime, content) =>
  client.query('SELECT app.set_login_image($1, $2) AS digest', [mime, content]).then((r) => r.rows[0].digest);
const current = (client, withContent = true) =>
  client.query('SELECT * FROM app.current_login_image($1)', [withContent]).then((r) => r.rows);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('imagem da tela de entrada', () => {
  it('o administrador da plataforma troca a imagem; só uma fica em uso e o resumo é o do arquivo', async () => {
    await asUser(platform.id, async (client) => {
      const first = jpeg();
      expect(await set(client, 'image/jpeg', first)).toBe(sha(first));
      const second = png();
      expect(await set(client, 'image/png', second)).toBe(sha(second));
      const rows = await current(client);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ sha256: sha(second), mime: 'image/png', size: second.length });
      expect(Buffer.compare(rows[0].content, second)).toBe(0);
      const old = await ownerPool.query('SELECT count(*)::int AS n FROM login_image WHERE sha256 = $1 AND deleted_at IS NOT NULL', [sha(first)]);
      expect(old.rows[0].n).toBe(0); // a transação do teste não foi confirmada
      const kept = await client.query('SELECT count(*)::int AS n FROM app.current_login_image()');
      expect(kept.rows[0].n).toBe(1);
      const webpImage = webp();
      await set(client, 'image/webp', webpImage);
      expect((await current(client))[0]).toMatchObject({ mime: 'image/webp', sha256: sha(webpImage) });
    });
  });

  it('sem o conteúdo, a consulta traz só o resumo; voltar ao padrão tira a imagem', async () => {
    await asUser(platform.id, async (client) => {
      const image = jpeg();
      await set(client, 'image/jpeg', image);
      const [light] = await current(client, false);
      expect(light).toMatchObject({ sha256: sha(image), mime: 'image/jpeg', size: image.length, content: null });
      await client.query('SELECT app.clear_login_image()');
      expect(await current(client)).toEqual([]);
    });
  });

  it('a imagem aparece sem sessão (tela de entrada) e para qualquer cliente', async () => {
    const client = await appPool.connect();
    try {
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.user_id', $1, true)", [platform.id]);
      const image = jpeg();
      await set(client, 'image/jpeg', image);
      await client.query("SELECT set_config('app.user_id', '', true)");
      expect((await current(client))[0].sha256).toBe(sha(image));
      // A tabela em si continua fechada para a aplicação.
      expect((await client.query('SELECT count(*)::int AS n FROM login_image')).rows[0].n).toBe(0);
    } finally {
      await client.query('ROLLBACK');
      client.release();
    }
  });

  it('só o administrador da plataforma troca ou tira a imagem', async () => {
    await asUser(a.secondAdmin.id, async (client) => {
      await expectCode(client, () => set(client, 'image/jpeg', jpeg()), 'FA002');
      await expectCode(client, () => client.query('SELECT app.clear_login_image()'), 'FA002');
    });
    await asUser(a.admin.id, async (client) => {
      await client.query("SELECT set_config('app.user_id', '', true)");
      await expectCode(client, () => set(client, 'image/jpeg', jpeg()), 'FA002');
    });
  });

  it('tipo, assinatura e tamanho do arquivo são conferidos', async () => {
    await asUser(platform.id, async (client) => {
      await expectCode(client, () => set(client, 'image/gif', Buffer.concat([Buffer.from('GIF89a'), randomBytes(100)])), 'FA225');
      await expectCode(client, () => set(client, 'image/png', jpeg()), 'FA225');
      await expectCode(client, () => set(client, 'image/jpeg', png()), 'FA225');
      await expectCode(client, () => set(client, 'image/webp', Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WAVE'), randomBytes(100)])), 'FA225');
      await expectCode(client, () => set(client, 'image/jpeg', Buffer.from([0xff, 0xd8, 0xff])), 'FA225');
      await expectCode(client, () => set(client, 'image/jpeg', Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(3 * 1024 * 1024)])), 'FA225');
      await expectCode(client, () => set(client, null, jpeg()), 'FA225');
      await expectCode(client, () => set(client, 'image/jpeg', null), 'FA225');
      // Exatamente 3 MB passa.
      await set(client, 'image/jpeg', Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(3 * 1024 * 1024 - 3)]));
      expect(await current(client, false)).toHaveLength(1);
    });
  });

  it('a imagem gravada não muda: trocar é outra linha', async () => {
    await asUser(platform.id, async (client) => {
      await set(client, 'image/jpeg', jpeg());
    });
    const owner = await ownerPool.connect();
    try {
      await owner.query('BEGIN');
      await owner.query("SELECT set_config('app.user_id', $1, true)", [platform.id]);
      await owner.query('SELECT app.set_login_image($1, $2)', ['image/jpeg', jpeg()]);
      await owner.query('SAVEPOINT s');
      await expect(owner.query("UPDATE login_image SET mime = 'image/png' WHERE deleted_at IS NULL")).rejects.toSatisfy(hasCode('FA104'));
      await owner.query('ROLLBACK TO s');
      await expect(owner.query('INSERT INTO login_image (mime, sha256, content) VALUES ($1, $2, $3)', ['image/jpeg', sha(jpeg()), jpeg()]))
        .rejects.toMatchObject({ constraint: 'login_image_current_key' });
    } finally {
      await owner.query('ROLLBACK');
      owner.release();
    }
  });
});
