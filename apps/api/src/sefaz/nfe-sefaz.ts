/**
 * Autorização da NF-e modelo 55 emitida pela central. O envelope e a leitura da resposta são os mesmos
 * da NFC-e (leiaute 4.00, envio síncrono); mudam os endereços, que são os da NF-e de cada UF.
 * CONFERIR os endereços com o portal de cada UF antes de produção.
 */
type Pair = [homologation: string, production: string];

const svrs: Pair = [
  'https://nfe-homologacao.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
  'https://nfe.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx',
];

const AUTHORIZATION: Record<string, Pair> = {
  SP: ['https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx', 'https://nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx'],
  PR: ['https://homologacao.nfe.sefa.pr.gov.br/nfe/NFeAutorizacao4', 'https://nfe.sefa.pr.gov.br/nfe/NFeAutorizacao4'],
  MG: ['https://hnfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4', 'https://nfe.fazenda.mg.gov.br/nfe2/services/NFeAutorizacao4'],
  RS: ['https://nfe-homologacao.sefazrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx', 'https://nfe.sefazrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx'],
  SC: svrs,
};

/** Sefaz Virtual de Contingência (tpEmis 6 SVC-AN, 7 SVC-RS). CONFERIR antes de produção. */
const SVC: Record<6 | 7, Pair> = {
  6: ['https://hom.svc.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx', 'https://www.svc.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx'],
  7: svrs,
};

/** Endereço da autorização na SVC. Fora da produção, os testes apontam para o servidor falso (SEFAZ_NFE_URL). */
export function nfeSvcAuthorizationUrl(emissionType: 6 | 7, environment: 1 | 2, env: NodeJS.ProcessEnv = process.env): string {
  if (environment === 2 && env.SEFAZ_NFE_URL) return `${env.SEFAZ_NFE_URL.replace(/\/$/, '')}/svc-authorization`;
  return SVC[emissionType][environment === 1 ? 1 : 0];
}

/**
 * Endereço da autorização da NF-e na UF. Fora da produção, os testes apontam para um servidor falso
 * (SEFAZ_NFE_URL). Null: UF ainda não atendida.
 */
export function nfeAuthorizationUrl(uf: string, environment: 1 | 2, env: NodeJS.ProcessEnv = process.env): string | null {
  if (environment === 2 && env.SEFAZ_NFE_URL) return `${env.SEFAZ_NFE_URL.replace(/\/$/, '')}/authorization`;
  const pair = AUTHORIZATION[uf];
  return pair ? pair[environment === 1 ? 1 : 0] : null;
}
