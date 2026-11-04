import { runMigrations } from './lib.mjs';

const applied = await runMigrations();
console.log(
  applied.length > 0
    ? `Migrations aplicadas: ${applied.join(', ')}`
    : 'Nenhuma migration pendente.',
);
