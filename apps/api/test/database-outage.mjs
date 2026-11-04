// Sobe a API de verdade e derruba o PostgreSQL: a API precisa responder 503,
// continuar viva e voltar a responder 200 quando o banco retorna.
// Usa o Compose local. Requer o build da API e o banco no ar.
import { spawn, spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const apiDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const rootDir = join(apiDir, '..', '..');
const port = process.env.OUTAGE_TEST_PORT ?? '3199';
const healthUrl = `http://127.0.0.1:${port}/health`;

function compose(...args) {
  const result = spawnSync('docker', ['compose', ...args], {
    cwd: rootDir,
    stdio: 'inherit',
  });
  if (result.status !== 0) {
    throw new Error(`Falha em: docker compose ${args.join(' ')}`);
  }
}

async function healthStatus() {
  try {
    const response = await fetch(healthUrl, {
      signal: AbortSignal.timeout(5000),
    });
    return response.status;
  } catch {
    return null;
  }
}

async function waitForStatus(expected, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await healthStatus();
    if (last === expected) {
      console.log(`GET /health respondeu ${expected}`);
      return;
    }
    await sleep(500);
  }
  throw new Error(`Esperava ${expected} em /health; última resposta: ${last}`);
}

const api = spawn(process.execPath, ['dist/main.js'], {
  cwd: apiDir,
  env: { ...process.env, PORT: port },
  stdio: 'inherit',
});

let apiExit = null;
api.on('exit', (code, signal) => {
  apiExit = { code, signal };
});

let databaseStopped = false;
let failed = false;
try {
  await waitForStatus(200);

  compose('stop', 'postgres');
  databaseStopped = true;
  await waitForStatus(503);
  if (apiExit) {
    throw new Error(`A API encerrou com o banco fora: ${JSON.stringify(apiExit)}`);
  }

  compose('up', '-d', '--wait');
  databaseStopped = false;
  await waitForStatus(200);

  if (apiExit) {
    throw new Error(`A API encerrou durante o teste: ${JSON.stringify(apiExit)}`);
  }
  console.log('A API sobreviveu à queda do banco.');
} catch (error) {
  failed = true;
  console.error(error instanceof Error ? error.message : error);
} finally {
  api.kill();
  if (databaseStopped) {
    compose('up', '-d', '--wait');
  }
}

process.exit(failed ? 1 : 0);
