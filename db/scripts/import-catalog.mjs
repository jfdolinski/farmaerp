import { readFile } from 'node:fs/promises';
import { importCatalog, migratorConfig } from './lib.mjs';

// Uso: npm run catalog:import -- caminho/do/arquivo.json
const file = process.argv[2];
if (!file) {
  console.error('Informe o arquivo: npm run catalog:import -- caminho/do/arquivo.json');
  process.exit(1);
}

try {
  const items = JSON.parse(await readFile(file, 'utf8'));
  const total = await importCatalog(migratorConfig(), items);
  console.log(`Catálogo importado. Itens processados: ${total}.`);
} catch (error) {
  console.error(`Importação cancelada, nada foi gravado. ${error.message}`);
  process.exit(1);
}
