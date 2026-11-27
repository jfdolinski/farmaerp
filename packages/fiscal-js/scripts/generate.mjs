// Compila o motor fiscal do PDV (Dart) para JavaScript, para a central emitir com o mesmo código.
// Uso: node scripts/generate.mjs        -> grava dist/fiscal.js
//      node scripts/generate.mjs --check -> compila num arquivo temporário e falha se dist/fiscal.js
//                                           estiver diferente (o JS no repositório precisa estar em dia).
// Precisa do Dart (o do Flutter serve). Sem mapa de fontes: a saída é sempre a mesma.
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, existsSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const pdv = resolve(root, '../../apps/pdv');
const target = join(root, 'dist', 'fiscal.js');
const check = process.argv.includes('--check');

function compile(output) {
  // Linha de comando fixa (só o caminho de saída varia, sempre entre aspas).
  const result = spawnSync(`dart compile js -O2 --no-source-maps -o "${output}" tool/fiscal_js.dart`, {
    cwd: pdv,
    encoding: 'utf8',
    shell: true,
  });
  if (result.status !== 0) {
    console.error(result.stdout, result.stderr);
    process.exit(1);
  }
}

if (check) {
  const temp = mkdtempSync(join(tmpdir(), 'fiscal-js-'));
  try {
    const fresh = join(temp, 'fiscal.js');
    compile(fresh);
    const plain = (file) => readFileSync(file, 'utf8').replaceAll('\r\n', '\n');
    const same = existsSync(target) && plain(fresh) === plain(target);
    if (!same) {
      console.error('packages/fiscal-js/dist/fiscal.js está desatualizado: rode npm run -s generate em packages/fiscal-js.');
      process.exit(1);
    }
    console.log('Motor fiscal em JavaScript em dia.');
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
} else {
  mkdirSync(dirname(target), { recursive: true });
  compile(target);
  console.log('Motor fiscal compilado em packages/fiscal-js/dist/fiscal.js.');
}
