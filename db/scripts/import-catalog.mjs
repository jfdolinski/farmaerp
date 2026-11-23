import { readFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { prepareCatalogImages } from './catalog-images.mjs';
import { importCatalog, migratorConfig } from './lib.mjs';

// Uso: npm run catalog:import -- caminho/do/arquivo.json
// As imagens podem vir como arquivos (convertidos aqui, se a sharp estiver instalada) ou já
// preparadas por npm run catalog:prepare-images.
const file = process.argv[2];
if (!file) {
  console.error('Informe o arquivo: npm run catalog:import -- caminho/do/arquivo.json');
  process.exit(1);
}

try {
  const items = JSON.parse(await readFile(file, 'utf8'));
  if (!Array.isArray(items)) throw new Error('O arquivo do Catálogo precisa ter uma lista de itens.');
  const prepared = await prepareCatalogImages(items, dirname(file));
  const total = await importCatalog(migratorConfig(), prepared);
  console.log(`Catálogo importado. Itens processados: ${total}.`);
} catch (error) {
  console.error(`Importação cancelada, nada foi gravado. ${error.message}`);
  process.exit(1);
}
