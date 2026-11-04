// Gera o catálogo em Dart para o PDV, que precisa das mensagens mesmo offline.
// Com --check, só confere se o arquivo versionado está em dia com o JSON.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { catalog } from '../index.js';

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, '..', '..', '..', 'apps', 'pdv', 'lib', 'core', 'error_catalog.g.dart');

const dartString = (text) => `'${text.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$')}'`;

const entries = Object.entries(catalog)
  .sort(([a], [b]) => a.localeCompare(b))
  .map(
    ([code, entry]) => `  ${dartString(code)}: ErrorCatalogEntry(
    code: ${dartString(code)},
    message: ${dartString(entry.message)},
    action: ${dartString(entry.action)},
    retryable: ${entry.retryable},
  ),`,
  )
  .join('\n');

const content = `// GERADO por packages/error-catalog/scripts/generate-dart.mjs. Não edite à mão.
// ignore_for_file: lines_longer_than_80_chars

class ErrorCatalogEntry {
  const ErrorCatalogEntry({
    required this.code,
    required this.message,
    required this.action,
    required this.retryable,
  });

  final String code;
  final String message;
  final String action;
  final bool retryable;
}

const Map<String, ErrorCatalogEntry> errorCatalog = {
${entries}
};
`;

if (process.argv.includes('--check')) {
  let current = '';
  try {
    current = readFileSync(target, 'utf8');
  } catch {
    // Arquivo ausente conta como desatualizado.
  }
  if (current.replace(/\r\n/g, '\n') !== content) {
    console.error('O catálogo do PDV está desatualizado. Rode: npm run catalog:generate');
    process.exit(1);
  }
  console.log('Catálogo do PDV em dia.');
} else {
  writeFileSync(target, content);
  console.log(`Catálogo do PDV gerado: ${Object.keys(catalog).length} códigos.`);
}
