// Só para testes: notas da importação montadas à mão.
// Notas no leiaute 4.00 (sem dados de ninguém: CNPJ e CPF de exemplo).
const KEY = '35260611222333000181650010000000421000000019';

export function nfceXml({ model = '65', protocol = true, dest = '<dest><CPF>11144477735</CPF></dest>' } = {}) {
  const nfe = `<NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe Id="NFe${KEY}" versao="4.00">`
    + `<ide><cUF>35</cUF><mod>${model}</mod><serie>1</serie><nNF>42</nNF><dhEmi>2026-06-10T10:00:00-03:00</dhEmi><tpAmb>1</tpAmb></ide>`
    + '<emit><CNPJ>11222333000181</CNPJ><xNome>DROGARIA ANTIGA LTDA</xNome><xFant>Drogaria Antiga</xFant>'
    + '<enderEmit><xLgr>Rua Velha</xLgr><nro>10</nro><xBairro>Centro</xBairro><cMun>3550308</cMun><xMun>São Paulo</xMun><UF>SP</UF><CEP>01001000</CEP><fone>1133334444</fone></enderEmit>'
    + '<IE>ISENTO</IE><CRT>1</CRT></emit>'
    + dest
    + '<det nItem="1"><prod><cProd>000123</cProd><cEAN>7891234567895</cEAN><xProd>Dipirona 500 mg</xProd><NCM>30049099</NCM><CEST>1300100</CEST>'
    + '<CFOP>5405</CFOP><uCom>UN</uCom><qCom>2.0000</qCom><vUnCom>12.5000000000</vUnCom><vProd>25.00</vProd><vDesc>1.00</vDesc>'
    + '<med><cProdANVISA>1234567890123</cProdANVISA><vPMC>15.90</vPMC></med></prod>'
    + '<imposto><ICMS><ICMSSN500><orig>0</orig><CSOSN>500</CSOSN></ICMSSN500></ICMS><PIS><PISNT><CST>04</CST></PISNT></PIS>'
    + '<COFINS><COFINSNT><CST>04</CST></COFINSNT></COFINS></imposto><infAdProd>Uso adulto</infAdProd></det>'
    + '<det nItem="2"><prod><cProd>B-9</cProd><cEAN>SEM GTIN</cEAN><xProd>Algodão</xProd><NCM>52010000</NCM><CFOP>5102</CFOP>'
    + '<uCom>UN</uCom><qCom>1.0000</qCom><vUnCom>8.00</vUnCom><vProd>8.00</vProd><cBenef>SP000001</cBenef></prod>'
    + '<imposto><ICMS><ICMS00><orig>0</orig><CST>00</CST><pICMS>18.00</pICMS></ICMS00></ICMS><PIS><PISAliq><CST>01</CST><pPIS>0.65</pPIS></PISAliq></PIS>'
    + '<COFINS><COFINSAliq><CST>01</CST><pCOFINS>3.00</pCOFINS></COFINSAliq></COFINS></imposto></det>'
    + '<total><ICMSTot><vProd>33.00</vProd><vDesc>1.00</vDesc><vNF>32.00</vNF></ICMSTot></total>'
    + '<pag><detPag><tPag>01</tPag><vPag>40.00</vPag></detPag><detPag><tPag>03</tPag><vPag>0.00</vPag><card><tBand>01</tBand><cAut>ABC123</cAut></card></detPag><vTroco>8.00</vTroco></pag>'
    + '</infNFe></NFe>';
  if (!protocol) return nfe;
  return `<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">${nfe}`
    + `<protNFe versao="4.00"><infProt><chNFe>${KEY}</chNFe><dhRecbto>2026-06-10T10:00:01-03:00</dhRecbto><nProt>135260000000001</nProt><cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe></nfeProc>`;
}

export const cancelXml = (status = '135') => '<procEventoNFe versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfe">'
  + `<evento versao="1.00"><infEvento Id="ID110111${KEY}01"><chNFe>${KEY}</chNFe><dhEvento>2026-06-10T10:20:00-03:00</dhEvento><tpEvento>110111</tpEvento></infEvento></evento>`
  + `<retEvento versao="1.00"><infEvento><cStat>${status}</cStat><chNFe>${KEY}</chNFe></infEvento></retEvento></procEventoNFe>`;

export { KEY };

/** NF-e (modelo 55) de compra: fornecedor de exemplo vendendo para a filial do seed. */
export const NFE_KEY = '35260611444777000161550010000012341000012347';
export function nfeXml({ key = NFE_KEY, operation = '1', emitCnpj = '11444777000161', destCnpj = '11222333000181', cfop = '5102' } = {}) {
  const nfe = `<NFe xmlns="http://www.portalfiscal.inf.br/nfe"><infNFe Id="NFe${key}" versao="4.00">`
    + `<ide><cUF>35</cUF><mod>55</mod><serie>1</serie><nNF>1234</nNF><dhEmi>2026-05-02T09:00:00-03:00</dhEmi><tpNF>${operation}</tpNF><tpAmb>1</tpAmb></ide>`
    + `<emit><CNPJ>${emitCnpj}</CNPJ><xNome>DISTRIBUIDORA EXEMPLO SA</xNome>`
    + '<enderEmit><xLgr>Av. Industrial</xLgr><nro>500</nro><xBairro>Distrito</xBairro><cMun>3509502</cMun><xMun>Campinas</xMun><UF>SP</UF><CEP>13000000</CEP></enderEmit>'
    + '<IE>ISENTO</IE><CRT>3</CRT></emit>'
    + `<dest><CNPJ>${destCnpj}</CNPJ><xNome>DROGARIA ANTIGA LTDA</xNome>`
    + '<enderDest><xLgr>Rua Velha</xLgr><nro>10</nro><xBairro>Centro</xBairro><cMun>3550308</cMun><xMun>São Paulo</xMun><UF>SP</UF><CEP>01001000</CEP></enderDest></dest>'
    + '<det nItem="1"><prod><cProd>FORN-77</cProd><cEAN>SEM GTIN</cEAN><xProd>Amoxicilina 500 mg cx 21</xProd><NCM>30042099</NCM>'
    + `<CFOP>${cfop}</CFOP><uCom>CX</uCom><qCom>3.0000</qCom><vUnCom>20.0000000000</vUnCom><vProd>60.00</vProd><cEANTrib>7896004713656</cEANTrib>`
    + '<vFrete>3.00</vFrete><vDesc>1.50</vDesc>'
    + '<rastro><nLote>LT01</nLote><qLote>2.000</qLote><dFab>2026-01-10</dFab><dVal>2027-12-31</dVal></rastro>'
    + '<rastro><nLote>LT02</nLote><qLote>1.000</qLote><dFab>2026-02-10</dFab><dVal>2028-01-31</dVal></rastro>'
    + '<med><cProdANVISA>1004300450011</cProdANVISA><vPMC>39.90</vPMC></med></prod>'
    + '<imposto><ICMS><ICMS10><orig>0</orig><CST>10</CST><vICMSST>4.20</vICMSST><vFCPST>0.30</vFCPST></ICMS10></ICMS>'
    + '<IPI><cEnq>999</cEnq><IPITrib><CST>50</CST><vIPI>1.20</vIPI></IPITrib></IPI></imposto></det>'
    + '<total><ICMSTot><vProd>60.00</vProd><vDesc>1.50</vDesc><vNF>67.20</vNF></ICMSTot></total>'
    + '<pag><detPag><tPag>15</tPag><vPag>67.20</vPag></detPag></pag>'
    + '</infNFe></NFe>';
  return `<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">${nfe}`
    + `<protNFe versao="4.00"><infProt><chNFe>${key}</chNFe><nProt>135260000000555</nProt><cStat>100</cStat></infProt></protNFe></nfeProc>`;
}
