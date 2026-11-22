import { appEnvironment } from '../config/environment.js';

/** Ambiente da Sefaz: a produção da API fala com a produção da Sefaz; o resto, com a homologação. */
export function sefazEnvironment(): 1 | 2 {
  return appEnvironment() === 'production' ? 1 : 2;
}

const ENDPOINTS = {
  1: {
    distribution: 'https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx',
    event: 'https://www.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx',
  },
  2: {
    distribution: 'https://hom1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx',
    event: 'https://hom1.nfe.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx',
  },
} as const;

export interface SefazEndpoints {
  distribution: string;
  event: string;
  /** Certificadora extra, só para o servidor falso dos testes. */
  ca?: string;
}

/**
 * Endereços do Ambiente Nacional. Fora da produção, os testes podem apontar para um servidor falso
 * (SEFAZ_DIST_URL, SEFAZ_EVENT_URL e SEFAZ_TEST_CA); em produção essas variáveis são ignoradas.
 */
export function sefazEndpoints(env: NodeJS.ProcessEnv = process.env): SefazEndpoints {
  const environment = sefazEnvironment();
  const official = ENDPOINTS[environment];
  if (environment === 1) return { ...official };
  return {
    distribution: env.SEFAZ_DIST_URL || official.distribution,
    event: env.SEFAZ_EVENT_URL || official.event,
    ca: env.SEFAZ_TEST_CA || undefined,
  };
}

/** Código IBGE da UF, pedido pela distribuição (cUFAutor). */
export const UF_CODES: Record<string, string> = {
  RO: '11', AC: '12', AM: '13', RR: '14', PA: '15', AP: '16', TO: '17', MA: '21', PI: '22', CE: '23', RN: '24',
  PB: '25', PE: '26', AL: '27', SE: '28', BA: '29', MG: '31', ES: '32', RJ: '33', SP: '35', PR: '41', SC: '42',
  RS: '43', MS: '50', MT: '51', GO: '52', DF: '53',
};
