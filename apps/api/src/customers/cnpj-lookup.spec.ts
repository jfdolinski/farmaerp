import { lookupCnpj } from './cnpj-lookup.js';

type Reply = { status: number; body?: unknown } | Error;

/** Simula os três serviços, na ordem em que são chamados. Nada sai para a internet. */
function fakeFetch(replies: Reply[]) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetcher = (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const reply = replies[calls.length - 1];
    if (reply instanceof Error) return Promise.reject(reply);
    return Promise.resolve(new Response(JSON.stringify(reply.body ?? {}), { status: reply.status }));
  };
  return { fetcher, calls };
}

const BRASILAPI = {
  razao_social: 'EMPRESA TESTE LTDA',
  nome_fantasia: 'TESTE',
  descricao_situacao_cadastral: 'ATIVA',
  cep: '20031170',
  descricao_tipo_de_logradouro: 'AVENIDA',
  logradouro: 'REPUBLICA DO CHILE',
  numero: '65',
  complemento: '',
  bairro: 'CENTRO',
  municipio: 'RIO DE JANEIRO',
  uf: 'RJ',
  codigo_municipio_ibge: 3304557,
  ddd_telefone_1: '2121660000',
  email: null,
  qsa: [{ nome_socio: 'PESSOA SOCIA', cnpj_cpf_do_socio: '***912137**' }],
};

describe('consulta de CNPJ', () => {
  it('usa o primeiro serviço e copia só os dados do cadastro', async () => {
    const { fetcher, calls } = fakeFetch([{ status: 200, body: BRASILAPI }]);
    const data = await lookupCnpj('33000167000101', fetcher);
    expect(calls).toHaveLength(1);
    expect(data).toEqual({
      source: 'brasilapi',
      legalName: 'EMPRESA TESTE LTDA',
      tradeName: 'TESTE',
      active: true,
      statusText: 'ATIVA',
      postalCode: '20031170',
      street: 'AVENIDA REPUBLICA DO CHILE',
      streetNumber: '65',
      complement: null,
      district: 'CENTRO',
      city: 'RIO DE JANEIRO',
      cityCode: '3304557',
      state: 'RJ',
      phone: '2121660000',
      email: null,
    });
    expect(JSON.stringify(data)).not.toContain('PESSOA SOCIA');
  });

  it('manda identificação genérica e prazo em cada chamada', async () => {
    const { fetcher, calls } = fakeFetch([{ status: 200, body: BRASILAPI }]);
    await lookupCnpj('33000167000101', fetcher);
    expect(calls[0].init.headers).toEqual({ 'User-Agent': 'FarmaERP/1.0', Accept: 'application/json' });
    expect(calls[0].init.signal).toBeInstanceOf(AbortSignal);
  });

  it('avisa CNPJ inativo ou baixado', async () => {
    const { fetcher } = fakeFetch([{ status: 200, body: { ...BRASILAPI, descricao_situacao_cadastral: 'BAIXADA' } }]);
    const data = await lookupCnpj('33000167000101', fetcher);
    expect(data).toMatchObject({ active: false, statusText: 'BAIXADA' });
  });

  it('com falha no primeiro, usa o segundo, que não traz o código IBGE', async () => {
    const { fetcher, calls } = fakeFetch([
      { status: 429 },
      {
        status: 200,
        body: {
          status: 'OK', nome: 'EMPRESA TESTE', fantasia: '', situacao: 'ATIVA', cep: '20.031-170',
          logradouro: 'AV REPUBLICA', numero: '65', bairro: 'CENTRO', municipio: 'RIO', uf: 'RJ',
          telefone: '(21) 2166-0000 / (21) 3333-4444', email: 'Contato@Empresa.com', qsa: [{ nome: 'SOCIO' }],
        },
      },
    ]);
    const data = await lookupCnpj('33000167000101', fetcher);
    expect(calls.map((call) => new URL(call.url).host)).toEqual(['brasilapi.com.br', 'receitaws.com.br']);
    expect(data).toMatchObject({
      source: 'receitaws', postalCode: '20031170', cityCode: null, tradeName: null,
      phone: '2121660000', email: 'contato@empresa.com',
    });
    expect(JSON.stringify(data)).not.toContain('SOCIO');
  });

  it('chega ao terceiro, com endereço e telefone no formato dele', async () => {
    const { fetcher } = fakeFetch([
      new Error('sem rede'),
      { status: 200, body: { status: 'ERROR', message: 'Too many requests' } },
      {
        status: 200,
        body: {
          alias: 'Teste', status: { id: 2, text: 'Ativa' }, company: { name: 'EMPRESA', members: [{ person: { name: 'SOCIO' } }] },
          address: { zip: '20031170', street: 'Avenida', number: '65', details: null, district: 'Centro', city: 'Rio', state: 'RJ', municipality: 3304557 },
          phones: [{ area: '21', number: '21660000' }], emails: [{ address: 'A@B.COM' }],
        },
      },
    ]);
    const data = await lookupCnpj('33000167000101', fetcher);
    expect(data).toMatchObject({ source: 'cnpja', active: true, cityCode: '3304557', phone: '2121660000', email: 'a@b.com' });
    expect(JSON.stringify(data)).not.toContain('SOCIO');
  });

  it('todos dizem que não existe: FA907', async () => {
    const { fetcher } = fakeFetch([
      { status: 404 },
      { status: 200, body: { status: 'ERROR', message: 'CNPJ inválido' } },
      { status: 404 },
    ]);
    await expect(lookupCnpj('33000167000101', fetcher)).rejects.toMatchObject({ code: 'FA907' });
  });

  it('algum falhou por rede: FA906, porque a empresa pode existir', async () => {
    const { fetcher } = fakeFetch([{ status: 404 }, new Error('timeout'), { status: 500 }]);
    await expect(lookupCnpj('33000167000101', fetcher)).rejects.toMatchObject({ code: 'FA906' });
  });

  it('resposta sem razão social não vale: tenta o próximo', async () => {
    const { fetcher, calls } = fakeFetch([{ status: 200, body: {} }, { status: 200, body: BRASILAPI }]);
    // O segundo serviço recebe o formato do primeiro e também não acha razão social; o terceiro, sim.
    await expect(lookupCnpj('33000167000101', fetcher)).rejects.toMatchObject({ code: 'FA906' });
    expect(calls).toHaveLength(3);
  });
});
