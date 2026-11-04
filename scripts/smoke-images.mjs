// Constrói as imagens e testa um ambiente publicado de ponta a ponta, em banco vazio.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const API = 'http://127.0.0.1:3101';
const WEB = 'http://127.0.0.1:3100';
const INTERNAL = 'interno_de_teste_com_mais_de_32_caracteres';
const ADMIN_USER = '019a0000-0000-7000-8000-000000000008';

function compose(args, { env = {}, allowFailure = false, quiet = false } = {}) {
  const result = spawnSync('docker', ['compose', '-f', 'docker-compose.images.yml', ...args], {
    cwd: root,
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: quiet ? 'pipe' : ['ignore', 'inherit', 'inherit'],
  });
  if (!allowFailure && result.status !== 0) {
    throw new Error(`Falha em: docker compose ${args.join(' ')}\n${result.stderr ?? ''}`);
  }
  return result;
}

async function waitFor(url, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;
  let last = 'sem resposta';
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(5000) });
      if (response.ok) return response;
      last = `status ${response.status}`;
    } catch (error) {
      last = error.message;
    }
    await sleep(1000);
  }
  throw new Error(`${url} não respondeu: ${last}`);
}

let checks = 0;
function check(label, condition, detail = '') {
  if (!condition) throw new Error(`FALHOU: ${label} ${detail}`);
  checks += 1;
  console.log(`ok: ${label}`);
}

const logsOf = (service) => compose(['logs', '--no-color', service], { quiet: true }).stdout;
const execApi = (command) => compose(['exec', '-T', 'api', 'sh', '-c', command], { quiet: true, allowFailure: true });

let failed = false;
try {
  compose(['down', '-v', '--remove-orphans'], { allowFailure: true, quiet: true });
  compose(['build']);
  compose(['up', '-d', '--wait', 'postgres']);

  // A produção ainda não pode iniciar, e não deve chegar a tocar no banco.
  const production = compose(['run', '--rm', '--no-deps', '-e', 'APP_ENV=production', 'api'], { quiet: true, allowFailure: true });
  check('produção não inicia', production.status !== 0);
  check('produção explica o motivo', /exige o login/.test(production.stderr + production.stdout));

  const invalid = compose(['run', '--rm', '--no-deps', '-e', 'APP_ENV=qualquer', 'api'], { quiet: true, allowFailure: true });
  check('ambiente desconhecido não inicia', invalid.status !== 0);

  const noRoles = compose(['run', '--rm', '--no-deps', '-e', 'POSTGRES_ADMIN_PASSWORD=', 'api'], { quiet: true, allowFailure: true });
  check('sem papéis e sem senha de administrador, não inicia', noRoles.status !== 0);
  check('sem papéis, explica o que fazer', /POSTGRES_ADMIN_PASSWORD/.test(noRoles.stderr + noRoles.stdout));

  // Primeiro deploy: cria papéis, aplica migrations e o seed de demonstração.
  compose(['up', '-d', 'api', 'web']);
  const health = await (await waitFor(`${API}/health`)).json();
  check('API responde com o banco no ar', health.status === 'ok' && health.database === 'up');

  const logs = logsOf('api');
  check('primeiro deploy cria os papéis', /Papéis do banco conferidos/.test(logs));
  check('primeiro deploy aplica as migrations', /Migrations aplicadas: 0001/.test(logs));

  check('API roda sem privilégios', execApi('id -u').stdout.trim() !== '0');
  const environ = execApi(`tr '\\0' '\\n' < /proc/1/environ`).stdout;
  check('o processo da API tem a própria senha', environ.includes('FARMAERP_APP_PASSWORD='));
  check('o processo da API não tem a senha de dono', !environ.includes('FARMAERP_MIGRATOR_PASSWORD'));
  check('o processo da API não tem a senha de administrador', !environ.includes('POSTGRES_ADMIN_PASSWORD'));

  const leaked = execApi('ls -a /app; ls -a /app/apps/api').stdout;
  check('a imagem não leva .env nem .git', !/.env|.git/.test(leaked));

  // Rotas de administração fechadas para quem não é a retaguarda.
  const admin = (headers) => fetch(`${API}/admin/terminals`, { headers });
  check('admin recusa sem o segredo', (await admin({ 'X-Dev-User-Id': ADMIN_USER })).status === 403);
  check('admin recusa segredo errado', (await admin({ 'X-Dev-User-Id': ADMIN_USER, 'X-Internal-Token': 'errado' })).status === 403);
  const allowed = await admin({ 'X-Dev-User-Id': ADMIN_USER, 'X-Internal-Token': INTERNAL });
  check('admin aceita o segredo certo', allowed.status === 200);
  const seeded = await allowed.json();
  check('seed de demonstração aplicado', seeded.length === 1 && seeded[0].number === 1);
  check('consultas com RLS funcionam com o papel da API', seeded[0].branch_name === 'Loja Centro');

  // Rotas do aparelho continuam abertas.
  const device = await fetch(`${API}/terminals/heartbeat`, { method: 'POST' });
  check('rota do terminal exige o token dele, com o catálogo', (await device.json()).code === 'FA306');

  // Retaguarda.
  check('retaguarda responde à verificação de saúde', (await (await waitFor(`${WEB}/api/health`)).json()).status === 'ok');
  check('retaguarda roda sem privilégios', compose(['exec', '-T', 'web', 'id', '-u'], { quiet: true }).stdout.trim() !== '0');
  const page = await (await waitFor(`${WEB}/terminais`)).text();
  check('retaguarda mostra a faixa de homologação', page.includes('HOMOLOGAÇÃO'));
  check('retaguarda alcança a API com o segredo', page.includes('Caixa 1'));
  check('o segredo não vai para o navegador', !page.includes(INTERNAL));

  // Novo deploy: sem a senha de administrador e sem migrations pendentes.
  compose(['up', '-d', '--force-recreate', '--no-deps', 'api'], { env: { SMOKE_ADMIN_PASSWORD: '' } });
  await waitFor(`${API}/health`);
  const secondLogs = logsOf('api');
  check('novo deploy não reaplica migrations', /Nenhuma migration pendente/.test(secondLogs));
  check('novo deploy não usa a senha de administrador', !/Papéis do banco conferidos/.test(secondLogs));
  const after = await (await admin({ 'X-Dev-User-Id': ADMIN_USER, 'X-Internal-Token': INTERNAL })).json();
  check('novo deploy não duplica o seed', after.length === 1);

  // Sem banco, a API não publica uma versão quebrada.
  compose(['stop', 'postgres']);
  const noDatabase = await fetch(`${API}/health`, { signal: AbortSignal.timeout(10000) }).catch(() => null);
  check('sem banco, a API responde 503', noDatabase?.status === 503);

  console.log(`\nImagens aprovadas: ${checks} verificações.`);
} catch (error) {
  failed = true;
  console.error(error.message);
  for (const service of ['api', 'web']) {
    console.error(`--- logs de ${service}`);
    console.error(logsOf(service).slice(-3000));
  }
} finally {
  compose(['down', '-v', '--remove-orphans'], { allowFailure: true, quiet: true });
}

process.exit(failed ? 1 : 0);
