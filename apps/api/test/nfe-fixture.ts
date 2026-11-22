// Só para testes: monta e assina uma NF-e autorizada, com certificado autoassinado e dados fictícios.
import { generateKeyPairSync, randomInt } from 'node:crypto';
import forge from 'node-forge';
import { SignedXml } from 'xml-crypto';

const DAY = 24 * 60 * 60 * 1000;
const { privateKey, publicKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding: { type: 'spki', format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

function certificatePem(): string {
  const certificate = forge.pki.createCertificate();
  certificate.publicKey = forge.pki.publicKeyFromPem(publicKey);
  certificate.serialNumber = '02';
  certificate.validity.notBefore = new Date(Date.now() - 30 * DAY);
  certificate.validity.notAfter = new Date(Date.now() + 300 * DAY);
  const attributes = [{ name: 'commonName', value: 'FORNECEDOR TESTE' }];
  certificate.setSubject(attributes);
  certificate.setIssuer(attributes);
  certificate.sign(forge.pki.privateKeyFromPem(privateKey), forge.md.sha256.create());
  return forge.pki.certificateToPem(certificate);
}
const CERTIFICATE = certificatePem();

/** CNPJ válido e aleatório. */
export function testCnpj(): string {
  const base = `${randomInt(10_000_000, 100_000_000)}0001`;
  const digit = (value: string) => {
    const weights = value.length === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    const rest = value.split('').reduce((sum, c, i) => sum + (c.charCodeAt(0) - 48) * weights[i], 0) % 11;
    return rest < 2 ? 0 : 11 - rest;
  };
  const first = digit(base);
  return `${base}${first}${digit(`${base}${first}`)}`;
}

/** GTIN-13 válido e aleatório. */
export function testGtin(): string {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}

export function accessKey(parts: { uf: string; yymm: string; cnpj: string; series: number; number: number; code: string }): string {
  const base = `${parts.uf}${parts.yymm}${parts.cnpj}55${String(parts.series).padStart(3, '0')}${String(parts.number).padStart(9, '0')}1${parts.code}`;
  let total = 0;
  let weight = 2;
  for (let i = base.length - 1; i >= 0; i -= 1) {
    total += (base.charCodeAt(i) - 48) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const remainder = total % 11;
  return `${base}${remainder < 2 ? 0 : 11 - remainder}`;
}

export interface TestItem {
  code?: string;
  ean?: string;
  description?: string;
  quantity?: string;
  unitPrice?: string;
  value?: string;
  cfop?: string;
  batches?: { number: string; quantity: string; manufacturedOn?: string; expiresOn: string }[];
  anvisa?: string;
  pmc?: string;
  st?: string;
}

export interface TestNfeOptions {
  emitterCnpj?: string;
  emitterName?: string;
  destCnpj?: string;
  number?: number;
  series?: number;
  environment?: 1 | 2;
  purpose?: 1 | 2 | 3 | 4;
  operationType?: 0 | 1;
  status?: string;
  items?: TestItem[];
  /** Altera o XML da nota antes da assinatura. */
  beforeSign?: (xml: string) => string;
  /** Altera o XML final, já assinado e com protocolo. */
  afterSign?: (xml: string) => string;
  /** Protocolo com outro resumo, como se fosse de outro conteúdo. */
  protocolDigest?: string;
  protocolKey?: string;
}

const escape = (value: string) => value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function itemXml(item: TestItem, index: number): string {
  const batches = (item.batches ?? [])
    .map((batch) => `<rastro><nLote>${batch.number}</nLote><qLote>${batch.quantity}</qLote>${batch.manufacturedOn ? `<dFab>${batch.manufacturedOn}</dFab>` : ''}<dVal>${batch.expiresOn}</dVal></rastro>`)
    .join('');
  const med = item.anvisa || item.pmc ? `<med><cProdANVISA>${item.anvisa ?? 'ISENTO'}</cProdANVISA>${item.pmc ? `<vPMC>${item.pmc}</vPMC>` : ''}</med>` : '';
  const icms = item.st
    ? `<ICMS10><orig>0</orig><CST>10</CST><vICMSST>${item.st}</vICMSST></ICMS10>`
    : '<ICMS00><orig>0</orig><CST>00</CST></ICMS00>';
  return `<det nItem="${index + 1}"><prod><cProd>${escape(item.code ?? `COD-${index + 1}`)}</cProd><cEAN>${item.ean ?? 'SEM GTIN'}</cEAN><xProd>${escape(item.description ?? `ITEM TESTE ${index + 1}`)}</xProd><NCM>30049099</NCM><CFOP>${item.cfop ?? '6102'}</CFOP><uCom>CX</uCom><qCom>${item.quantity ?? '2.0000'}</qCom><vUnCom>${item.unitPrice ?? '10.5000000000'}</vUnCom><vProd>${item.value ?? '21.00'}</vProd><cEANTrib>${item.ean ?? 'SEM GTIN'}</cEANTrib><uTrib>CX</uTrib><qTrib>${item.quantity ?? '2.0000'}</qTrib><vUnTrib>${item.unitPrice ?? '10.5000000000'}</vUnTrib><indTot>1</indTot>${batches}${med}</prod><imposto><ICMS>${icms}</ICMS></imposto></det>`;
}

export function buildNfe(options: TestNfeOptions = {}) {
  const emitterCnpj = options.emitterCnpj ?? testCnpj();
  const destCnpj = options.destCnpj ?? testCnpj();
  const number = options.number ?? randomInt(1, 999_999_999);
  const series = options.series ?? 1;
  const environment = options.environment ?? 2;
  const items = options.items ?? [{}];
  const key = accessKey({ uf: '35', yymm: '2611', cnpj: emitterCnpj, series, number, code: String(randomInt(10_000_000, 99_999_999)) });
  const total = items.reduce((sum, item) => sum + Number(item.value ?? '21.00'), 0).toFixed(2);
  let infNfe = `<infNFe Id="NFe${key}" versao="4.00"><ide><cUF>35</cUF><cNF>${key.slice(35, 43)}</cNF><natOp>VENDA</natOp><mod>55</mod><serie>${series}</serie><nNF>${number}</nNF><dhEmi>2026-11-20T10:00:00-03:00</dhEmi><tpNF>${options.operationType ?? 1}</tpNF><idDest>2</idDest><cMunFG>3550308</cMunFG><tpImp>1</tpImp><tpEmis>1</tpEmis><cDV>${key[43]}</cDV><tpAmb>${environment}</tpAmb><finNFe>${options.purpose ?? 1}</finNFe></ide><emit><CNPJ>${emitterCnpj}</CNPJ><xNome>${escape(options.emitterName ?? 'DISTRIBUIDORA TESTE LTDA')}</xNome><xFant>DISTRIBUIDORA TESTE</xFant><enderEmit><xLgr>RUA DE TESTE</xLgr><nro>100</nro><xBairro>CENTRO</xBairro><cMun>3550308</cMun><xMun>SAO PAULO</xMun><UF>SP</UF><CEP>01001000</CEP><fone>1133334444</fone></enderEmit><IE>110042490114</IE><CRT>3</CRT></emit><dest><CNPJ>${destCnpj}</CNPJ><xNome>FARMACIA TESTE</xNome></dest>${items.map(itemXml).join('')}<total><ICMSTot><vProd>${total}</vProd><vFrete>0.00</vFrete><vSeg>0.00</vSeg><vDesc>0.00</vDesc><vIPI>0.00</vIPI><vST>0.00</vST><vOutro>0.00</vOutro><vNF>${total}</vNF></ICMSTot></total></infNFe>`;
  if (options.beforeSign) infNfe = options.beforeSign(infNfe);
  const unsigned = `<NFe xmlns="http://www.portalfiscal.inf.br/nfe">${infNfe}</NFe>`;

  const signer = new SignedXml({
    privateKey,
    publicCert: CERTIFICATE,
    signatureAlgorithm: 'http://www.w3.org/2000/09/xmldsig#rsa-sha1',
    canonicalizationAlgorithm: 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315',
  });
  signer.addReference({
    xpath: "//*[local-name(.)='infNFe']",
    digestAlgorithm: 'http://www.w3.org/2000/09/xmldsig#sha1',
    transforms: [
      'http://www.w3.org/2000/09/xmldsig#enveloped-signature',
      'http://www.w3.org/TR/2001/REC-xml-c14n-20010315',
    ],
  });
  signer.computeSignature(unsigned, { location: { reference: "//*[local-name(.)='infNFe']", action: 'after' } });
  const signed = signer.getSignedXml();
  const digest = /<DigestValue>([^<]+)<\/DigestValue>/.exec(signed)?.[1] ?? '';
  const protocol = `<protNFe versao="4.00"><infProt><tpAmb>${environment}</tpAmb><verAplic>TESTE</verAplic><chNFe>${options.protocolKey ?? key}</chNFe><dhRecbto>2026-11-20T10:00:05-03:00</dhRecbto><nProt>135260000000001</nProt><digVal>${options.protocolDigest ?? digest}</digVal><cStat>${options.status ?? '100'}</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe>`;
  let xml = `<?xml version="1.0" encoding="UTF-8"?><nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">${signed}${protocol}</nfeProc>`;
  if (options.afterSign) xml = options.afterSign(xml);
  return { xml, key, emitterCnpj, destCnpj, number };
}
