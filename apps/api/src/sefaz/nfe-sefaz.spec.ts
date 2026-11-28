import { nfeAuthorizationUrl, nfeSvcAuthorizationUrl } from './nfe-sefaz.js';

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
});
