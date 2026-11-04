// Prepara o banco ao iniciar a API nos ambientes publicados.
import {
  bootstrapRoles,
  migratorConfig,
  requireEnv,
  runMigrations,
  runSeed,
  waitForDatabase,
} from './lib.mjs';

const INVALID_LOGIN = new Set(['28P01', '28000']);

const adminPassword = process.env.POSTGRES_ADMIN_PASSWORD;
const database = requireEnv('DB_NAME');

try {
  // Só no primeiro deploy: depois, a senha de administrador sai das variáveis.
  if (adminPassword) {
    const adminConfig = {
      host: requireEnv('DB_HOST'),
      port: Number(process.env.DB_PORT ?? 5432),
      user: process.env.POSTGRES_ADMIN_USER ?? 'postgres',
      password: adminPassword,
      database,
    };
    await waitForDatabase(adminConfig);
    await bootstrapRoles(adminConfig, {
      migratorPassword: requireEnv('FARMAERP_MIGRATOR_PASSWORD'),
      appPassword: requireEnv('FARMAERP_APP_PASSWORD'),
    });
    console.log('Papéis do banco conferidos. Remova POSTGRES_ADMIN_PASSWORD das variáveis.');
  }

  const config = migratorConfig();
  await waitForDatabase(config);

  const applied = await runMigrations(config);
  console.log(
    applied.length > 0
      ? `Migrations aplicadas: ${applied.join(', ')}`
      : 'Nenhuma migration pendente.',
  );

  if (process.env.APP_ENV === 'homologation') {
    await runSeed(config);
    console.log('Dados de demonstração conferidos.');
  }
} catch (error) {
  if (INVALID_LOGIN.has(error.code)) {
    console.error(
      'O banco recusou o acesso. No primeiro deploy, defina POSTGRES_ADMIN_PASSWORD; depois, confira FARMAERP_MIGRATOR_PASSWORD.',
    );
  } else {
    console.error(`Falha ao preparar o banco: ${error.message}`);
  }
  process.exit(1);
}
