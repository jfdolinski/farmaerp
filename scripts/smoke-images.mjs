// Constrói as imagens e testa ambientes publicados de ponta a ponta, em banco vazio.
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const API = 'http://127.0.0.1:3101';
const WEB = 'http://127.0.0.1:3100';
const OWNER = { email: 'dono@exemplo.com.br', password: 'senha-inicial-de-teste' };
const NEW_PASSWORD = 'senha-definitiva-de-teste';

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
      const response = await fetch(url, { signal: AbortSignal.timeout(5000), redirect: 'manual' });
      if (response.ok || response.status === 307) return response;
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
const api = (path, { token, ...options } = {}) =>
  fetch(`${API}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });
const post = (path, body, token) => api(path, { method: 'POST', body: JSON.stringify(body), token });

async function ownerSession(password) {
  const response = await post('/auth/login', { email: OWNER.email, password });
  return { status: response.status, ...(await response.json()) };
}

async function homologation() {
  console.log('\n--- Homologação');
  compose(['up', '-d', '--wait', 'postgres']);

  const invalid = compose(['run', '--rm', '--no-deps', '-e', 'APP_ENV=qualquer', 'api'], { quiet: true, allowFailure: true });
  check('ambiente desconhecido não inicia', invalid.status !== 0);

  const noRoles = compose(['run', '--rm', '--no-deps', '-e', 'POSTGRES_ADMIN_PASSWORD=', 'api'], { quiet: true, allowFailure: true });
  check('sem papéis e sem senha de administrador, não inicia', noRoles.status !== 0);
  check('sem papéis, explica o que fazer', /POSTGRES_ADMIN_PASSWORD/.test(noRoles.stderr + noRoles.stdout));

  compose(['up', '-d', 'api', 'web']);
  const health = await (await waitFor(`${API}/health`)).json();
  check('API responde com o banco no ar', health.status === 'ok' && health.database === 'up');

  const logs = logsOf('api');
  check('primeiro deploy cria os papéis', /Papéis do banco conferidos/.test(logs));
  check('primeiro deploy aplica as migrations', /Migrations aplicadas: 0001/.test(logs));
  check('primeiro deploy cria o administrador', /Primeiro administrador criado/.test(logs));
  check('o log não mostra a senha inicial', !logs.includes(OWNER.password));

  check('API roda sem privilégios', execApi('id -u').stdout.trim() !== '0');
  const environ = execApi(`tr '\\0' '\\n' < /proc/1/environ`).stdout;
  check('o processo da API tem a própria senha', environ.includes('FARMAERP_APP_PASSWORD='));
  for (const name of ['FARMAERP_MIGRATOR_PASSWORD', 'POSTGRES_ADMIN_PASSWORD', 'BOOTSTRAP_ADMIN_PASSWORD']) {
    check(`o processo da API não tem ${name}`, !environ.includes(name));
  }
  const leaked = execApi('ls -a /app; ls -a /app/apps/api').stdout;
  check('a imagem não leva .env nem .git', !/\.env|\.git\b/.test(leaked));

  // Sem sessão, nada abre.
  check('rotas de administração exigem sessão', (await (await api('/admin/terminals')).json()).code === 'FA402');
  const legacy = await fetch(`${API}/admin/terminals`, {
    headers: { 'X-Dev-User-Id': '019a0000-0000-7000-8000-000000000008', 'X-Internal-Token': 'qualquer' },
  });
  check('a identidade provisória não funciona mais', legacy.status === 401);
  const device = await fetch(`${API}/terminals/heartbeat`, { method: 'POST' });
  check('rota do terminal exige o token dele', (await device.json()).code === 'FA306');

  // Primeiro acesso.
  check('senha errada é recusada', (await ownerSession('senha-errada-de-teste')).code === 'FA401');
  const first = await ownerSession(OWNER.password);
  check('primeiro acesso exige trocar a senha', first.status === 200 && first.mustChangePassword === true);
  check('antes de trocar, nada abre', (await (await api('/admin/terminals', { token: first.token })).json()).code === 'FA403');
  const changed = await post('/auth/change-password', { currentPassword: OWNER.password, newPassword: NEW_PASSWORD }, first.token);
  check('troca a senha', changed.status === 200);

  const terminals = await (await api('/admin/terminals', { token: first.token })).json();
  check('seed de demonstração aplicado', terminals.length === 1 && terminals[0].number === 1);
  check('consultas com RLS funcionam com o papel da API', terminals[0].branch_name === 'Loja Centro');

  const seedLogin = await post('/auth/login', { email: 'admin@farmaerp.test', password: 'farmaerp-dev-123' });
  check('a senha de exemplo do seed não vale em homologação', seedLogin.status === 401);

  // Retaguarda.
  check('retaguarda responde à verificação de saúde', (await (await waitFor(`${WEB}/api/health`)).json()).status === 'ok');
  check('retaguarda roda sem privilégios', compose(['exec', '-T', 'web', 'id', '-u'], { quiet: true }).stdout.trim() !== '0');
  const anonymous = await fetch(`${WEB}/terminais`, { redirect: 'manual' });
  check('sem sessão, a retaguarda leva ao login', anonymous.status === 307 && anonymous.headers.get('location').includes('/login'));
  const loginPage = await (await fetch(`${WEB}/login`)).text();
  check('a tela de login abre, com a faixa de homologação', loginPage.includes('HOMOLOGAÇÃO') && loginPage.includes('Entre com seu e-mail'));

  const cookie = `farmaerp_session=${first.token}`;
  const page = await (await fetch(`${WEB}/terminais`, { headers: { Cookie: cookie } })).text();
  check('com sessão, a retaguarda mostra os terminais', page.includes('Caixa 1'));
  const users = await (await fetch(`${WEB}/usuarios`, { headers: { Cookie: cookie } })).text();
  check('com sessão, a retaguarda mostra os usuários', users.includes(OWNER.email));

  // Novo deploy, sem as variáveis do primeiro.
  compose(['up', '-d', '--force-recreate', '--no-deps', 'api'], {
    env: { SMOKE_ADMIN_PASSWORD: '', SMOKE_BOOTSTRAP_EMAIL: '' },
  });
  await waitFor(`${API}/health`);
  const secondLogs = logsOf('api');
  check('novo deploy não reaplica migrations', /Nenhuma migration pendente/.test(secondLogs));
  check('novo deploy não mexe no administrador', !/administrador/i.test(secondLogs));
  check('a senha definitiva continua valendo', (await ownerSession(NEW_PASSWORD)).status === 200);

  // Sem banco, a API avisa em vez de cair.
  compose(['stop', 'postgres']);
  const noDatabase = await fetch(`${API}/health`, { signal: AbortSignal.timeout(10000) }).catch(() => null);
  check('sem banco, a API responde 503', noDatabase?.status === 503);
}

async function production() {
  console.log('\n--- Produção');
  compose(['down', '-v', '--remove-orphans'], { quiet: true });
  const env = { SMOKE_APP_ENV: 'production' };
  compose(['up', '-d', '--wait', 'postgres'], { env });
  compose(['up', '-d', '--no-deps', 'api'], { env });
  await waitFor(`${API}/health`);
  check('a API inicia em produção', true);

  const logs = logsOf('api');
  check('produção não roda o seed', !/demonstração/.test(logs));
  check('produção cria o administrador', /Primeiro administrador criado/.test(logs));

  check('produção exige sessão', (await api('/admin/terminals')).status === 401);
  const seedLogin = await post('/auth/login', { email: 'admin@farmaerp.test', password: 'farmaerp-dev-123' });
  check('a senha de exemplo do seed não existe em produção', seedLogin.status === 401);

  const first = await ownerSession(OWNER.password);
  check('o administrador entra, com troca obrigatória', first.status === 200 && first.mustChangePassword === true);
  await post('/auth/change-password', { currentPassword: OWNER.password, newPassword: NEW_PASSWORD }, first.token);
  const terminals = await (await api('/admin/terminals', { token: first.token })).json();
  check('produção começa sem dados de demonstração', Array.isArray(terminals) && terminals.length === 0);

  const empty = await (await api('/admin/structure', { token: first.token })).json();
  check('produção começa sem empresa, e o administrador pode cadastrar', empty.canManage === true && empty.companies.length === 0);
  // Só para o banco descartável deste teste; nada sai daqui.
  const created = await post('/admin/structure/companies', {
    cnpj: '12345678000195',
    legalName: 'Empresa de Teste Ltda',
    tradeName: 'Empresa de Teste',
    branch: { name: 'Matriz', state: 'SP' },
  }, first.token);
  const structure = await (await api('/admin/structure', { token: first.token })).json();
  check('a primeira empresa e a primeira filial são criadas pela API', created.status === 201 && structure.companies.length === 1 && structure.branches.length === 1);
}

let failed = false;
try {
  compose(['down', '-v', '--remove-orphans'], { allowFailure: true, quiet: true });
  compose(['build']);
  await homologation();
  await production();
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
