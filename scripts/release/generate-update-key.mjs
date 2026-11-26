// Gera o par de chaves que assina as versões do PDV. Rode uma vez, na sua máquina:
//   node scripts/release/generate-update-key.mjs C:\caminho\fora\do\repositorio\farmaerp-update-key.txt
// - O arquivo informado recebe a chave PRIVADA. Cadastre o conteúdo no segredo UPDATE_SIGNING_KEY
//   do GitHub (gh secret set UPDATE_SIGNING_KEY < arquivo) e guarde uma cópia em local seguro.
//   Nunca coloque esse arquivo no repositório nem mande por chat.
// - A chave PÚBLICA é mostrada na tela: ela vai em scripts/release/update-keys.json.
import { generateKeyPairSync } from 'node:crypto';
import { existsSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const target = process.argv[2];
if (!target) {
  console.error('Informe o arquivo que vai receber a chave privada (fora do repositório).');
  process.exit(1);
}
const path = resolve(target);
if (path.startsWith(resolve(import.meta.dirname, '..', '..'))) {
  console.error('O arquivo da chave privada não pode ficar dentro do repositório.');
  process.exit(1);
}
if (existsSync(path)) {
  console.error('O arquivo já existe; não vou sobrescrever uma chave.');
  process.exit(1);
}
const { privateKey, publicKey } = generateKeyPairSync('ed25519');
writeFileSync(path, privateKey.export({ format: 'der', type: 'pkcs8' }).toString('base64'), { mode: 0o600 });
const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
console.log(`Chave privada gravada em ${path}.`);
console.log(`Chave pública (para scripts/release/update-keys.json): ${raw}`);
