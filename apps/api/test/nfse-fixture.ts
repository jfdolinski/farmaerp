// Só para testes: NFS-e do padrão nacional e eventos, com dados fictícios, na estrutura do modelo
// publicado pela Receita Federal (NFSe/infNFSe com a DPS dentro).
import { randomInt } from 'node:crypto';

export const testNfseKey = () => Array.from({ length: 50 }, () => randomInt(10)).join('');

export interface TestNfseOptions {
  key?: string;
  number?: string;
  providerCnpj?: string;
  providerName?: string;
  takerCnpj?: string;
  description?: string;
  serviceValue?: string;
  netValue?: string;
  environment?: 1 | 2;
  replaces?: string;
  /** Altera o XML final. */
  after?: (xml: string) => string;
}

export function buildNfse(options: TestNfseOptions = {}) {
  const key = options.key ?? testNfseKey();
  const xml =
    `<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01"><infNFSe Id="NFS${key}">` +
    `<xLocEmi>São Paulo</xLocEmi><xLocPrestacao>São Paulo</xLocPrestacao><nNFSe>${options.number ?? '1234'}</nNFSe>` +
    `<cLocIncid>3550308</cLocIncid><xLocIncid>São Paulo</xLocIncid><xTribNac>Manutenção e reparação</xTribNac>` +
    `<verAplic>SefinNac</verAplic><ambGer>2</ambGer><tpEmis>1</tpEmis><procEmi>1</procEmi><cStat>100</cStat>` +
    `<dhProc>2026-11-10T09:00:05-03:00</dhProc><nDFSe>987654</nDFSe>` +
    `<emit><CNPJ>${options.providerCnpj ?? '11444777000161'}</CNPJ><IM>12345</IM><xNome>${options.providerName ?? 'MANUTENCAO DE AR LTDA'}</xNome>` +
    `<enderNac><xLgr>RUA DO TESTE</xLgr><nro>10</nro><xBairro>CENTRO</xBairro><cMun>3550308</cMun><UF>SP</UF><CEP>01001000</CEP></enderNac></emit>` +
    `<valores><vCalcDR>0.00</vCalcDR><vBC>1000.00</vBC><pAliqAplic>5.00</pAliqAplic><vISSQN>50.00</vISSQN>` +
    `<vTotalRet>111.50</vTotalRet><vLiq>${options.netValue ?? '888.50'}</vLiq></valores>` +
    `<DPS versao="1.01"><infDPS Id="DPS355030821144477700016100001000000000001234"><tpAmb>${options.environment ?? 2}</tpAmb>` +
    `<dhEmi>2026-11-10T09:00:00-03:00</dhEmi><verAplic>1.0</verAplic><serie>1</serie><nDPS>1234</nDPS><dCompet>2026-11-01</dCompet>` +
    `<tpEmit>1</tpEmit><cLocEmi>3550308</cLocEmi>` +
    (options.replaces ? `<subst><chSubstda>${options.replaces}</chSubstda><cMotivo>01</cMotivo><xMotivo>Erro no valor</xMotivo></subst>` : '') +
    `<prest><CNPJ>${options.providerCnpj ?? '11444777000161'}</CNPJ><regTrib><opSimpNac>1</opSimpNac><regEspTrib>0</regEspTrib></regTrib></prest>` +
    `<toma><CNPJ>${options.takerCnpj ?? '11222333000181'}</CNPJ><xNome>FARMACIA TESTE</xNome></toma>` +
    `<serv><locPrest><cLocPrestacao>3550308</cLocPrestacao></locPrest><cServ><cTribNac>140101</cTribNac><cTribMun>1401</cTribMun>` +
    `<xDescServ>${options.description ?? 'Manutenção do ar-condicionado da loja'}</xDescServ><cNBS>120011100</cNBS></cServ></serv>` +
    `<valores><vServPrest><vServ>${options.serviceValue ?? '1000.00'}</vServ></vServPrest>` +
    `<trib><tribMun><tribISSQN>1</tribISSQN><tpRetISSQN>2</tpRetISSQN></tribMun>` +
    `<tribFed><piscofins><CST>01</CST><vBCPisCofins>1000.00</vBCPisCofins><pAliqPis>0.65</pAliqPis><pAliqCofins>3.00</pAliqCofins>` +
    `<vPis>6.50</vPis><vCofins>30.00</vCofins><tpRetPisCofins>3</tpRetPisCofins></piscofins>` +
    `<vRetCP>0.00</vRetCP><vRetIRRF>15.00</vRetIRRF><vRetCSLL>10.00</vRetCSLL></tribFed>` +
    `<totTrib><indTotTrib>0</indTotTrib></totTrib></trib></valores></infDPS></DPS></infNFSe></NFSe>`;
  return { key, xml: options.after ? options.after(xml) : xml };
}

/** Evento de cancelamento (101101) ou de cancelamento por substituição (105102). */
export function buildNfseEvent(key: string, kind: 'cancel' | 'replace', substitute?: string): string {
  const detail =
    kind === 'cancel'
      ? '<e101101><xDesc>Cancelamento de NFS-e</xDesc><cMotivo>1</cMotivo><xMotivo>Erro na emissão</xMotivo></e101101>'
      : `<e105102><xDesc>Cancelamento de NFS-e por Substituicao</xDesc><cMotivo>01</cMotivo><xMotivo>Erro no valor</xMotivo><chSubstituta>${substitute ?? ''}</chSubstituta></e105102>`;
  return (
    `<evento xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.00"><infEvento Id="EVT${key}${kind === 'cancel' ? '101101' : '105102'}001">` +
    `<verAplic>SefinNac</verAplic><ambGer>2</ambGer><nSeqEvento>1</nSeqEvento><dhProc>2026-11-11T10:00:00-03:00</dhProc><nDFe>55</nDFe>` +
    `<pedRegEvento versao="1.00"><infPedReg Id="PRE${key}${kind === 'cancel' ? '101101' : '105102'}001"><tpAmb>2</tpAmb><verAplic>1.0</verAplic>` +
    `<dhEvento>2026-11-11T09:59:00-03:00</dhEvento><CNPJAutor>11444777000161</CNPJAutor><chNFSe>${key}</chNFSe><nPedRegEvento>1</nPedRegEvento>` +
    `${detail}</infPedReg></pedRegEvento></infEvento></evento>`
  );
}
