import { nfeAuthorizationUrl, nfeSvcAuthorizationUrl, nfeUrl } from './nfe-sefaz.js';

describe('endereços da NF-e 55', () => {
  it('SVC-AN (6) e SVC-RS (7) por ambiente; nos testes, o servidor falso', () => {
    expect(nfeSvcAuthorizationUrl(6, 2, {})).toBe('https://hom.svc.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx');
    expect(nfeSvcAuthorizationUrl(6, 1, {})).toBe('https://www.svc.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx');
    expect(nfeSvcAuthorizationUrl(7, 2, {})).toBe('https://nfe-homologacao.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx');
    expect(nfeSvcAuthorizationUrl(7, 1, {})).toBe('https://nfe.svrs.rs.gov.br/ws/NfeAutorizacao/NFeAutorizacao4.asmx');
    expect(nfeSvcAuthorizationUrl(6, 2, { SEFAZ_NFE_URL: 'https://localhost:9/' })).toBe('https://localhost:9/svc-authorization');
    // Em produção, o servidor falso nunca vale.
    expect(nfeSvcAuthorizationUrl(6, 1, { SEFAZ_NFE_URL: 'https://localhost:9' })).toBe('https://www.svc.fazenda.gov.br/NFeAutorizacao4/NFeAutorizacao4.asmx');
    expect(nfeAuthorizationUrl('SP', 2, {})).toBe('https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeautorizacao4.asmx');
  });

  it('consulta e evento: os da NF-e na UF (não os da NFC-e) e os da SVC na nota em contingência', () => {
    expect(nfeUrl('SP', 2, 'status', 1, {})).toBe('https://homologacao.nfe.fazenda.sp.gov.br/ws/nfeconsultaprotocolo4.asmx');
    expect(nfeUrl('SP', 1, 'event', 1, {})).toBe('https://nfe.fazenda.sp.gov.br/ws/nferecepcaoevento4.asmx');
    expect(nfeUrl('PR', 1, 'event', 1, {})).toBe('https://nfe.sefa.pr.gov.br/nfe/NFeRecepcaoEvento4');
    expect(nfeUrl('RS', 2, 'status', 1, {})).toBe('https://nfe-homologacao.sefazrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx');
    expect(nfeUrl('SC', 1, 'event', 1, {})).toBe('https://nfe.svrs.rs.gov.br/ws/recepcaoevento/recepcaoevento4.asmx');
    expect(nfeUrl('SP', 2, 'event', 6, {})).toBe('https://hom.svc.fazenda.gov.br/NFeRecepcaoEvento4/NFeRecepcaoEvento4.asmx');
    expect(nfeUrl('PR', 1, 'status', 7, {})).toBe('https://nfe.svrs.rs.gov.br/ws/NfeConsulta/NfeConsulta4.asmx');
    expect(nfeUrl('XX', 2, 'event', 1, {})).toBeNull();
    expect(nfeUrl('SP', 2, 'event', 1, { SEFAZ_NFE_URL: 'https://localhost:9' })).toBe('https://localhost:9/event');
    expect(nfeUrl('SP', 2, 'status', 7, { SEFAZ_NFE_URL: 'https://localhost:9' })).toBe('https://localhost:9/svc-status');
  });
});
