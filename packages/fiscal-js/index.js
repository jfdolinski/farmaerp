// Motor fiscal do PDV (Dart) compilado para JavaScript, rodando num contexto isolado do Node: não
// mexe nos globais da API. Carregado uma vez, na primeira chamada.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

let engine;

function load() {
  if (engine) return engine;
  const code = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'dist', 'fiscal.js'), 'utf8');
  // Só o que o código compilado do Dart usa do ambiente.
  const context = vm.createContext({
    console,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    queueMicrotask,
    crypto: globalThis.crypto,
    performance: globalThis.performance,
    TextEncoder,
    TextDecoder,
    atob,
    btoa,
  });
  context.self = context;
  vm.runInContext(code, context, { filename: 'fiscal.js' });
  engine = context.farmaerpFiscal;
  if (!engine) throw new Error('Motor fiscal não carregou.');
  return engine;
}

/**
 * Monta e assina a NF-e modelo 55. Devolve { accessKey, xml, totalCents } ou { error: { code, detail } }
 * (código do catálogo de erros; o detalhe é só para o log).
 */
export function buildNfe(input, keyPem, certPem) {
  return JSON.parse(load().buildNfe(JSON.stringify(input), keyPem, certPem));
}

/** DANFE A4 da NF-e (XML assinado ou nfeProc), em PDF. */
export async function buildDanfe(xml) {
  return Buffer.from(await load().buildDanfe(xml), 'base64');
}

/** Sefaz Virtual de Contingência da UF: 6 SVC-AN, 7 SVC-RS; null se a UF não estiver na tabela. */
export function svcEmissionType(uf) {
  return load().svcEmissionType(uf) ?? null;
}
