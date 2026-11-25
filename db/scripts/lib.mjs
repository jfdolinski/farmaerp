import { readFile } from 'node:fs/promises';
import { checkPreparedImage } from './catalog-images.mjs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import argon2 from 'argon2';
import { runner } from 'node-pg-migrate';
import pg from 'pg';

const here = dirname(fileURLToPath(import.meta.url));

export const migrationsDir = join(here, '..', 'migrations');
export const seedFile = join(here, '..', 'seeds', 'dev.sql');
export const rolesFile = join(here, '..', 'bootstrap', 'sql', 'roles.sql');
export const devCredentialsFile = join(here, '..', 'seeds', 'dev-credentials.sql');

/** Lê uma variável obrigatória, com mensagem clara quando ela não existe. */
export function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`A variável ${name} não está definida. Copie .env.example para .env.`);
  }
  return value;
}

/** Configuração de conexão com o papel de dono das tabelas. */
export function migratorConfig(database = process.env.DB_NAME ?? 'farmaerp') {
  return {
    host: process.env.DB_HOST ?? '127.0.0.1',
    port: Number(process.env.DB_PORT ?? 5432),
    user: 'farmaerp_migrator',
    password: requireEnv('FARMAERP_MIGRATOR_PASSWORD'),
    database,
  };
}

/** Aplica as migrations pendentes e retorna os nomes das que foram aplicadas. */
export async function runMigrations(config = migratorConfig()) {
  const applied = await runner({
    databaseUrl: config,
    dir: migrationsDir,
    direction: 'up',
    migrationsSchema: 'db_migrations',
    createMigrationsSchema: true,
    migrationsTable: 'applied_migrations',
    checkOrder: true,
    log: () => {},
  });
  return applied.map((migration) => migration.name);
}

export async function withClient(config, fn) {
  const client = new pg.Client(config);
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

/**
 * Cria os papéis do banco e o prefixo de log com o ID de rastreio.
 * Roda com a senha de administrador e pode ser repetido sem efeito colateral.
 */
export async function bootstrapRoles(adminConfig, { migratorPassword, appPassword }) {
  await withClient(adminConfig, async (client) => {
    await client.query(`SELECT set_config('farmaerp.migrator_password', $1, false)`, [migratorPassword]);
    await client.query(`SELECT set_config('farmaerp.app_password', $1, false)`, [appPassword]);
    await client.query(await readFile(rolesFile, 'utf8'));
    await client.query(`ALTER SYSTEM SET log_line_prefix = '%m [%p] app=%a '`);
    await client.query('SELECT pg_reload_conf()');
  });
}

/** Seed de demonstração, só em desenvolvimento e homologação. */
export async function runSeed(config = migratorConfig(), environment = process.env.APP_ENV) {
  if (environment !== 'development' && environment !== 'homologation') {
    throw new Error(
      `O seed só roda em desenvolvimento ou homologação (APP_ENV: ${environment ?? 'não definido'}).`,
    );
  }
  await withClient(config, async (client) => {
    await client.query(await readFile(seedFile, 'utf8'));
    // A senha de exemplo é pública no repositório: nunca em ambiente publicado.
    if (environment === 'development') {
      await client.query(await readFile(devCredentialsFile, 'utf8'));
    }
  });
}

/**
 * Carrega os itens do Catálogo. Ou entra o arquivo inteiro, ou nada: um item recusado desfaz
 * a importação, e o erro diz qual foi. Roda como dono das tabelas, porque a API não escreve aqui.
 */
export async function importCatalog(config, items) {
  if (!Array.isArray(items)) {
    throw new Error('O arquivo do Catálogo precisa ter uma lista de itens.');
  }
  return withClient(config, async (client) => {
    await client.query('BEGIN');
    try {
      for (const [index, item] of items.entries()) {
        try {
          const { images, ...data } = item ?? {};
          await client.query('SELECT app.upsert_catalog_product($1::jsonb)', [JSON.stringify(data)]);
          // Sem o campo, as imagens ficam como estão; com ele, a lista passa a ser exatamente esta.
          if (images !== undefined) {
            if (!Array.isArray(images)) throw new Error('"images" precisa ser uma lista.');
            for (const image of images) checkPreparedImage(image);
            await client.query('SELECT app.set_catalog_product_images($1, $2::jsonb)', [data.sourceKey, JSON.stringify(images)]);
          }
        } catch (error) {
          throw new Error(
            `Item ${index + 1} (${item?.sourceKey ?? 'sem sourceKey'}) recusado: ${error.message}`,
            { cause: error },
          );
        }
      }
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    }
    return items.length;
  });
}

/**
 * Cria o primeiro administrador, com troca obrigatória de senha.
 * Se o e-mail já tiver acesso, não faz nada: a senha nunca é sobrescrita.
 */
export async function bootstrapAdmin(config, { email, password, groupName }) {
  if ((password?.length ?? 0) < 10) {
    throw new Error('BOOTSTRAP_ADMIN_PASSWORD precisa ter ao menos 10 caracteres.');
  }
  const normalized = email.trim().toLowerCase();

  return withClient(config, async (client) => {
    const existing = await client.query(
      `SELECT 1 FROM user_account u JOIN user_credential c ON c.user_id = u.id AND c.deleted_at IS NULL
        WHERE u.email = $1 AND u.deleted_at IS NULL`,
      [normalized],
    );
    if (existing.rowCount > 0) {
      // Já tinha acesso: a senha fica como está, mas ele continua administrando a plataforma.
      await ensurePlatformAdmin(client, normalized);
      return 'skipped';
    }

    const hash = await argon2.hash(password, { type: argon2.argon2id });
    await client.query('BEGIN');
    try {
      let group = (await client.query('SELECT id FROM economic_group WHERE deleted_at IS NULL ORDER BY created_at LIMIT 1')).rows[0];
      if (!group) {
        if (!groupName) {
          throw new Error('Defina BOOTSTRAP_GROUP_NAME: ainda não existe nenhum grupo econômico.');
        }
        group = (await client.query('INSERT INTO economic_group (name) VALUES ($1) RETURNING id', [groupName])).rows[0];
      }
      const user = (await client.query(
        `INSERT INTO user_account (economic_group_id, name, email)
         VALUES ($1, 'Administrador', $2)
         ON CONFLICT (email) WHERE deleted_at IS NULL AND email IS NOT NULL DO UPDATE SET email = EXCLUDED.email
         RETURNING id`,
        [group.id, normalized],
      )).rows[0];
      await client.query(
        `INSERT INTO user_role (user_id, role_id)
         SELECT $1, r.id FROM role r
          WHERE r.economic_group_id = $2 AND r.system_key = 'administrator' AND r.deleted_at IS NULL
         ON CONFLICT DO NOTHING`,
        [user.id, group.id],
      );
      await client.query(
        'INSERT INTO user_credential (user_id, password_hash, must_change_password) VALUES ($1, $2, true)',
        [user.id, hash],
      );
      // O administrador do deploy também administra a plataforma: é quem cadastra as empresas
      // (cada uma como cliente separado).
      await ensurePlatformAdmin(client, normalized);
      await client.query('COMMIT');
      return 'created';
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    }
  });
}

/** Marca a pessoa do e-mail como administradora da plataforma (se ainda não for). */
async function ensurePlatformAdmin(client, email) {
  await client.query(
    `INSERT INTO platform_admin (user_id)
     SELECT u.id FROM user_account u
      WHERE u.email = $1 AND u.deleted_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM platform_admin p WHERE p.user_id = u.id AND p.deleted_at IS NULL)`,
    [email],
  );
}

/** Espera o banco aceitar conexões: no deploy, ele pode subir depois da API. */
export async function waitForDatabase(config, { timeoutMs = 60_000, intervalMs = 2_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      await withClient(config, (client) => client.query('SELECT 1'));
      return;
    } catch (error) {
      const stillStarting = ['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'ECONNRESET', 'ETIMEDOUT', '57P03']
        .includes(error.code);
      if (!stillStarting || Date.now() >= deadline) {
        throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
  }
}
