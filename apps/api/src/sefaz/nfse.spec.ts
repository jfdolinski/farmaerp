import { gzipSync } from 'node:zlib';
import { buildNfse, buildNfseEvent, testNfseKey } from '../../test/nfse-fixture.js';
import { AppError } from '../observability/app-error.js';
import { decodeNfseXml, nfseDistributionUrl, parseNfseDistribution, readServiceEvent, readServiceInvoice } from './nfse.js';

const b64gzip = (xml: string) => gzipSync(Buffer.from(xml, 'utf8')).toString('base64');
const expectCode = (fn: () => unknown, code: string) => {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe(code);
    return;
  }
  throw new Error('deveria ter falhado');
};

describe('pedido ao ADN', () => {
  it('NSU sem zeros à esquerda, CNPJ da filial e lote', () => {
    expect(nfseDistributionUrl('https://adn.nfse.gov.br/contribuintes/', '000000000000042', '11222333000181'))
      .toBe('https://adn.nfse.gov.br/contribuintes/DFe/42?cnpjConsulta=11222333000181&lote=true');
    expect(nfseDistributionUrl('https://x/contribuintes', '000000000000000', '11222333000181')).toContain('/DFe/0?');
  });
});

describe('resposta do ADN', () => {
  it('abre os documentos, com ou sem gzip, e devolve o maior NSU', () => {
    const nota = buildNfse();
    const body = JSON.stringify({
      StatusProcessamento: 'DOCUMENTOS_LOCALIZADOS',
      LoteDFe: [
        { NSU: 7, ChaveAcesso: nota.key, TipoDocumento: 'NFSE', ArquivoXml: b64gzip(nota.xml) },
        { NSU: '9', ChaveAcesso: nota.key, TipoDocumento: 'EVENTO', ArquivoXml: Buffer.from('<evento/>').toString('base64') },
        { NSU: 8, ChaveAcesso: 'x', TipoDocumento: 'OUTRO', ArquivoXml: 'eA==' },
        { NSU: 10, ChaveAcesso: nota.key, TipoDocumento: 'NFSE', ArquivoXml: gzipSync(Buffer.alloc(6 * 1024 * 1024, 32)).toString('base64') },
        { NSU: 'abc', TipoDocumento: 'NFSE', ArquivoXml: 'eA==' },
      ],
    });
    const parsed = parseNfseDistribution(200, body);
    expect(parsed).toMatchObject({ status: 'DOCUMENTOS_LOCALIZADOS', rejected: false, lastNsu: '000000000000010' });
    expect(parsed.documents).toEqual([
      { nsu: '000000000000007', type: 'NFSE', accessKey: nota.key, xml: nota.xml },
      { nsu: '000000000000009', type: 'EVENTO', accessKey: nota.key, xml: '<evento/>' },
    ]);
    expect(parsed.skipped.map((s) => s.nsu)).toEqual(['000000000000008', '000000000000010', 'abc']);
  });

  it('nada encontrado vem em 404, com ou sem corpo', () => {
    expect(parseNfseDistribution(404, JSON.stringify({ StatusProcessamento: 'NENHUM_DOCUMENTO_LOCALIZADO', LoteDFe: [] })))
      .toMatchObject({ status: 'NENHUM_DOCUMENTO_LOCALIZADO', documents: [], lastNsu: null, rejected: false });
    expect(parseNfseDistribution(404, '')).toMatchObject({ status: 'NENHUM_DOCUMENTO_LOCALIZADO', documents: [] });
  });

  it('recusa traz o motivo; certificado recusado e falha do servidor viram erro', () => {
    const refused = parseNfseDistribution(400, JSON.stringify({
      StatusProcessamento: 'REJEICAO', Erros: [{ Codigo: 'E2245', Descricao: 'Não há procuração', Complemento: null }],
    }));
    expect(refused).toMatchObject({ rejected: true, status: 'REJEICAO', message: 'E2245 Não há procuração' });
    expectCode(() => parseNfseDistribution(403, ''), 'FA948');
    expectCode(() => parseNfseDistribution(429, ''), 'FA944');
    expectCode(() => parseNfseDistribution(503, '{}'), 'FA944');
    expectCode(() => parseNfseDistribution(200, 'não é json'), 'FA944');
  });

  it('base64 de URL também abre', () => {
    const xml = '<NFSe>ação?</NFSe>';
    const urlSafe = Buffer.from(xml, 'utf8').toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
    expect(decodeNfseXml(urlSafe)).toBe(xml);
  });
});

describe('NFS-e', () => {
  it('lê os campos do modelo oficial', () => {
    const replaced = testNfseKey();
    const nota = buildNfse({ replaces: replaced });
    expect(readServiceInvoice(nota.xml)).toEqual({
      accessKey: nota.key, number: '1234', environment: 2, issuedAt: '2026-11-10T09:00:00-03:00', competence: '2026-11-01',
      processedAt: '2026-11-10T09:00:05-03:00', providerDocument: '11444777000161', providerName: 'MANUTENCAO DE AR LTDA',
      providerLocation: 'São Paulo', takerDocument: '11222333000181', serviceCode: '140101', municipalCode: '1401',
      nbsCode: '120011100', description: 'Manutenção do ar-condicionado da loja', incidenceLocation: 'São Paulo',
      serviceValue: '1000.00', unconditionalDiscount: null, deductions: '0.00', issBase: '1000.00', issRate: '5.00',
      issValue: '50.00', issWithholding: 2, irrf: '15.00', csll: '10.00', socialSecurity: '0.00', pis: '6.50',
      cofins: '30.00', pisCofinsWithholding: 3, totalWithheld: '111.50', netValue: '888.50', replacesKey: replaced,
    });
  });

  it('campo opcional fora do formato fica vazio; obrigatório recusa', () => {
    const odd = buildNfse({ after: (xml) => xml.replace('<cTribNac>140101</cTribNac>', '<cTribNac>14.01</cTribNac>').replace('<tpRetISSQN>2</tpRetISSQN>', '<tpRetISSQN>9</tpRetISSQN>') });
    expect(readServiceInvoice(odd.xml)).toMatchObject({ serviceCode: null, issWithholding: null });
    expectCode(() => readServiceInvoice(buildNfse({ netValue: '1,5' }).xml), 'FA931');
    expectCode(() => readServiceInvoice(buildNfse({ after: (xml) => xml.replace(/Id="NFS\d+"/, 'Id="NFS123"') }).xml), 'FA931');
    expectCode(() => readServiceInvoice(buildNfse({ after: (xml) => xml.replace('<dCompet>2026-11-01</dCompet>', '') }).xml), 'FA931');
    expectCode(() => readServiceInvoice('<!DOCTYPE x [<!ENTITY a "b">]><NFSe>&a;</NFSe>'), 'FA931');
    expectCode(() => readServiceInvoice('<NFe/>'), 'FA931');
  });

  it('lê cancelamento e substituição', () => {
    const key = testNfseKey();
    const substitute = testNfseKey();
    expect(readServiceEvent(buildNfseEvent(key, 'cancel'), null)).toEqual({ accessKey: key, kind: 'cancel', substituteKey: null });
    expect(readServiceEvent(buildNfseEvent(key, 'replace', substitute), null)).toEqual({ accessKey: key, kind: 'replace', substituteKey: substitute });
    expect(readServiceEvent('<evento><e999999/></evento>', key)).toEqual({ accessKey: key, kind: 'other', substituteKey: null });
    expect(readServiceEvent('<evento/>', null)).toBeNull();
  });
});
