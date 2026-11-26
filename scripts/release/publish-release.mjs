// Assina e publica uma versão do PDV na central. Roda no CI (workflow "Versão do PDV").
//   node scripts/release/publish-release.mjs <instalador> <versão> [plataforma]
// Variáveis:
//   UPDATE_SIGNING_KEY    chave privada (base64 PKCS#8), segredo do GitHub
//   RELEASE_UPLOAD_TOKEN  token de envio, o mesmo da API (segredo do GitHub)
//   RELEASE_API_URL       endereço da API (ex.: https://farmaerp-hom-api.b6nhiy.easypanel.host)
//   RELEASE_NOTES         opcional, até 2000 caracteres
// Nada disso aparece no log: só a versão, o tamanho e o resultado.
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { fileDigest, signRelease, verifyRelease } from './release-format.mjs';

const [file, version, platform = 'windows'] = process.argv.slice(2);
const { UPDATE_SIGNING_KEY: key, RELEASE_UPLOAD_TOKEN: token, RELEASE_API_URL: api, RELEASE_NOTES: notes = '' } = process.env;
if (!file || !/^\d{1,4}\.\d{1,4}\.\d{1,4}$/.test(version ?? '')) {
  console.error('Uso: publish-release.mjs <instalador> <versão 1.2.3> [windows|linux]');
  process.exit(1);
}
if (!key || !token || !api) {
  console.error('Faltam UPDATE_SIGNING_KEY, RELEASE_UPLOAD_TOKEN ou RELEASE_API_URL.');
  process.exit(1);
}

const { sha256, size } = await fileDigest(file);
const manifest = { app: 'pdv', platform, version, sha256, size };
const signature = signRelease(manifest, key);
// A chave do segredo precisa ser uma das publicadas no código, senão o PDV recusaria a versão.
const published = JSON.parse(readFileSync(new URL('./update-keys.json', import.meta.url), 'utf8')).keys;
// Só nos testes locais (a API de produção ignora a chave de teste).
if (process.env.UPDATE_TEST_PUBLIC_KEY) published.push(process.env.UPDATE_TEST_PUBLIC_KEY);
if (!verifyRelease(manifest, signature, published)) {
  console.error('A chave de assinatura do segredo não está em scripts/release/update-keys.json.');
  process.exit(1);
}

const query = new URLSearchParams({ ...manifest, size: String(size), signature, fileName: basename(file), notes: notes.slice(0, 2000) });
const response = await fetch(`${api.replace(/\/$/, '')}/releases?${query}`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream', 'Content-Length': String(size) },
  body: readFileSync(file),
});
const body = await response.json().catch(() => ({}));
if (!response.ok) {
  console.error(`A central recusou a versão ${version}: ${response.status} ${body.code ?? ''} ${body.message ?? ''}`);
  process.exit(1);
}
console.log(`Versão ${version} publicada (${(size / 1024 / 1024).toFixed(1)} MB, SHA-256 ${sha256.slice(0, 12)}…), só para os terminais de teste.`);
