/**
 * Serviços da NF-e modelo 55 (emitida pela central ou pelo caixa). Os envelopes e a leitura das
 * respostas são os mesmos da NFC-e (leiaute 4.00, eventos 1.00); mudam os endereços, que são os da
 * NF-e de cada UF ou, na nota em contingência, os da Sefaz Virtual (SVC).
 * CONFERIR os endereços com o portal de cada UF e da SVC antes de produção.
 */
type Pair = [homologation: string, production: string];

/** Serviços da NF-e usados pela central: autorização, consulta pela chave e evento (cancelamento, CC-e). */
export type NfeService = 'authorization' | 'status' | 'event';
type Urls = Record<NfeService, Pair>;

const pairs = (hom: Record<NfeService, string>, prod: Record<NfeService, string>): Urls => ({
  authorization: [hom.authorization, prod.authorization],
  status: [hom.status, prod.status],
  event: [hom.event, prod.event],
});

const svrsHost = (host: string) => ({
  authorization: `https://${host}/ws/NfeAutorizacao/NFeAutorizacao4.asmx`,
  status: `https://${host}/ws/NfeConsulta/NfeConsulta4.asmx`,
  event: `https://${host}/ws/recepcaoevento/recepcaoevento4.asmx`,
});
const servicePath = (base: string) => ({
  authorization: `${base}/NFeAutorizacao4`,
  status: `${base}/NFeConsultaProtocolo4`,
  event: `${base}/NFeRecepcaoEvento4`,
});
const sp = (host: string) => ({
  authorization: `https://${host}/ws/nfeautorizacao4.asmx`,
  status: `https://${host}/ws/nfeconsultaprotocolo4.asmx`,
  event: `https://${host}/ws/nferecepcaoevento4.asmx`,
});

const svrs = pairs(svrsHost('nfe-homologacao.svrs.rs.gov.br'), svrsHost('nfe.svrs.rs.gov.br'));

const BY_UF: Record<string, Urls> = {
  SP: pairs(sp('homologacao.nfe.fazenda.sp.gov.br'), sp('nfe.fazenda.sp.gov.br')),
  PR: pairs(servicePath('https://homologacao.nfe.sefa.pr.gov.br/nfe'), servicePath('https://nfe.sefa.pr.gov.br/nfe')),
  MG: pairs(servicePath('https://hnfe.fazenda.mg.gov.br/nfe2/services'), servicePath('https://nfe.fazenda.mg.gov.br/nfe2/services')),
  RS: pairs(svrsHost('nfe-homologacao.sefazrs.rs.gov.br'), svrsHost('nfe.sefazrs.rs.gov.br')),
  SC: svrs,
};

const svcAn = (host: string) => ({
  authorization: `https://${host}/NFeAutorizacao4/NFeAutorizacao4.asmx`,
  status: `https://${host}/NFeConsultaProtocolo4/NFeConsultaProtocolo4.asmx`,
  event: `https://${host}/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx`,
});

/** Sefaz Virtual de Contingência (tpEmis 6 SVC-AN, 7 SVC-RS). */
const SVC: Record<6 | 7, Urls> = {
  6: pairs(svcAn('hom.svc.fazenda.gov.br'), svcAn('www.svc.fazenda.gov.br')),
  7: svrs,
};

/**
 * Endereço do serviço da NF-e: na SVC quando a nota é de contingência (tpEmis 6 ou 7), senão na UF.
 * Fora da produção, os testes apontam para um servidor falso (SEFAZ_NFE_URL): `/<serviço>` e, na
 * SVC, `/svc-<serviço>`. Null: UF ainda não atendida.
 */
export function nfeUrl(uf: string, environment: 1 | 2, service: NfeService, emissionType = 1, env: NodeJS.ProcessEnv = process.env): string | null {
  const svc = emissionType === 6 || emissionType === 7 ? emissionType : null;
  if (environment === 2 && env.SEFAZ_NFE_URL) return `${env.SEFAZ_NFE_URL.replace(/\/$/, '')}/${svc ? 'svc-' : ''}${service}`;
  const urls = svc ? SVC[svc] : BY_UF[uf];
  return urls ? urls[service][environment === 1 ? 1 : 0] : null;
}

/** Endereço da autorização na SVC. */
export function nfeSvcAuthorizationUrl(emissionType: 6 | 7, environment: 1 | 2, env: NodeJS.ProcessEnv = process.env): string {
  return nfeUrl('', environment, 'authorization', emissionType, env)!;
}

/** Endereço da autorização da NF-e na UF. Null: UF ainda não atendida. */
export function nfeAuthorizationUrl(uf: string, environment: 1 | 2, env: NodeJS.ProcessEnv = process.env): string | null {
  return nfeUrl(uf, environment, 'authorization', 1, env);
}
