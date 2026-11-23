import { readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { prepareCatalogImages } from './catalog-images.mjs';

// Uso: npm run catalog:prepare-images -- entrada.json saida.json
// Converte as imagens (campo "file" de cada imagem) para WebP de até 800 px e de até 200 px e grava
// um arquivo que a importação aceita em qualquer lugar, inclusive no servidor, sem a sharp.
const [input, output] = process.argv.slice(2);
if (!input || !output) {
  console.error('Informe a entrada e a saída: npm run catalog:prepare-images -- entrada.json saida.json');
  process.exit(1);
}

try {
  const items = JSON.parse(await readFile(input, 'utf8'));
  if (!Array.isArray(items)) throw new Error('O arquivo do Catálogo precisa ter uma lista de itens.');
  const prepared = await prepareCatalogImages(items, dirname(input));
  await writeFile(output, JSON.stringify(prepared));
  const count = prepared.reduce((total, item) => total + (Array.isArray(item.images) ? item.images.length : 0), 0);
  console.log(`Imagens preparadas: ${count}. Arquivo gravado em ${output}.`);
} catch (error) {
  console.error(`Preparo cancelado. ${error.message}`);
  process.exit(1);
}
