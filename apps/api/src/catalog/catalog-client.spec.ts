import { CATALOG_KEY, CatalogClient, CatalogUnavailable, catalogUrl, mapItem } from './catalog-client.js';

const BASE = 'https://catalogo.test';

describe('configuração do Catálogo', () => {
  it('precisa do endereço; tira a barra do fim; recusa o que não é endereço', () => {
    expect(catalogUrl({ CATALOG_URL: 'https://catalogo.test/' })).toBe(BASE);
    expect(catalogUrl({})).toBeNull();
    expect(catalogUrl({ CATALOG_URL: 'catalogo.test' })).toBeNull();
    expect(catalogUrl({ CATALOG_URL: 'https://catalogo.test/api' })).toBeNull();
  });

  it('a chave começa com cat_ e tem ao menos 8 caracteres depois', () => {
    expect(CATALOG_KEY.test('cat_abcdefgh')).toBe(true);
    expect(CATALOG_KEY.test('cat_a1b2-c3_d4e5')).toBe(true);
    expect(CATALOG_KEY.test('cat_abc')).toBe(false);
    expect(CATALOG_KEY.test('xyz_abcdefgh')).toBe(false);
    expect(CATALOG_KEY.test('cat_abc defgh')).toBe(false);
  });
});

describe('item do Catálogo', () => {
  const item = {
    id: 4622, name: ' Dorflex C/10 Comp ', brand: 'Sanofi', manufacturer: '', anvisa_registry: '1.0300.0085', med_controlled: 'Antimicrobiano',
    ncm: '30049099', cest: '', actives: [{ name: 'dipirona', concentration: '300 mg' }, { name: 'orfenadrina', concentration: '' }, {}],
    barcodes: [{ code: '7891058002916' }, { code: '7891058002916' }, '7891058002923', { code: '' }],
    images: [
      { url: `${BASE}/files/a.webp` }, { url: `${BASE}/padrao/10.png`, placeholder: true }, { url: 'https://outro.test/files/b.webp' },
      `${BASE}/files/c.webp`, { url: `${BASE}/files/d.webp` }, { url: `${BASE}/files/e.webp` }, { url: `${BASE}/files/f.webp` }, { url: `${BASE}/files/g.webp` },
    ],
    pending: false,
    tax_origin: 0,
  };

  it('vira o item daqui: chave, marca como fabricante, princípios ativos juntos, códigos sem repetir, até 5 imagens do próprio Catálogo', () => {
    const mapped = mapItem(item, BASE);
    expect(mapped).toMatchObject({
      sourceKey: 'catalogo:4622', name: 'Dorflex C/10 Comp', manufacturer: 'Sanofi', activeIngredient: 'dipirona 300 mg + orfenadrina',
      msRegistration: '1.0300.0085', controlledClass: 'Antimicrobiano', ncm: '30049099', cest: null, origin: '0',
      barcodes: ['7891058002916', '7891058002923'], pending: false,
      images: [`${BASE}/files/a.webp`, `${BASE}/files/c.webp`, `${BASE}/files/d.webp`, `${BASE}/files/e.webp`, `${BASE}/files/f.webp`],
    });
    expect(mapped?.hash).toMatch(/^[0-9a-f]{64}$/);
  });

  it('a impressão digital muda quando o item muda, e não muda quando é igual', () => {
    const hash = mapItem(item, BASE)?.hash;
    expect(mapItem({ ...item }, BASE)?.hash).toBe(hash);
    expect(mapItem({ ...item, name: 'Dorflex C/30' }, BASE)?.hash).not.toBe(hash);
    expect(mapItem({ ...item, pending: true }, BASE)?.hash).not.toBe(hash);
    expect(mapItem({ ...item, images: [] }, BASE)?.hash).not.toBe(hash);
  });

  it('fabricante vence a marca; princípio ativo como texto; sem id ou nome é ignorado', () => {
    expect(mapItem({ id: '7', name: 'X', manufacturer: 'EMS', brand: 'Marca', actives: ['clonazepam 2'] }, BASE))
      .toMatchObject({ sourceKey: 'catalogo:7', manufacturer: 'EMS', activeIngredient: 'clonazepam 2', barcodes: [], images: [], pending: false });
    expect(mapItem({ name: 'Sem id' }, BASE)).toBeNull();
    expect(mapItem({ id: 'abc', name: 'Id ruim' }, BASE)).toBeNull();
    expect(mapItem({ id: 1, name: '  ' }, BASE)).toBeNull();
    expect(mapItem({ id: 1, name: 'Pendente', pending: true }, BASE)?.pending).toBe(true);
  });
});

describe('cliente HTTP do Catálogo', () => {
  const calls: { url: string; headers: Record<string, string> }[] = [];
  const client = (respond: (url: string) => Response) =>
    new CatalogClient({ url: BASE, key: 'cat_segredo' }, async (url, init) => {
      calls.push({ url, headers: init.headers as Record<string, string> });
      return respond(url);
    });
  beforeEach(() => {
    calls.length = 0;
  });

  it('a cópia leva a chave no cabeçalho (nunca na URL), a origem e a ETag; 304 é catálogo igual', async () => {
    const result = await client(() => new Response(null, { status: 304 })).catalog('W/"1"');
    expect(result).toEqual({ unchanged: true });
    expect(calls[0].url).toBe(`${BASE}/api/v1/catalog.json`);
    expect(calls[0].headers).toMatchObject({ 'X-Api-Key': 'cat_segredo', 'X-Origem': 'FarmaERP', 'If-None-Match': 'W/"1"' });
    expect(calls[0].url).not.toContain('cat_segredo');

    const full = await client(() => Response.json({ items: [{ id: 1 }] }, { headers: { ETag: 'W/"2"' } })).catalog(null);
    expect(full).toEqual({ unchanged: false, etag: 'W/"2"', items: [{ id: 1 }] });
    expect(calls[1].headers['If-None-Match']).toBeUndefined();
  });

  it('resposta errada ou sem rede vira CatalogUnavailable com mensagem clara, sem a chave', async () => {
    expect((await client(() => new Response('x', { status: 401 })).catalog(null).catch((e: Error) => e.message)))
      .toBe('O Catálogo recusou a chave de acesso. Confira a CATALOG_API_KEY da API.');
    expect((await client(() => new Response('x', { status: 403 })).barcode('1').catch((e: Error) => e.message)))
      .toBe('A empresa do FarmaERP está suspensa ou cancelada no Catálogo.');
    expect((await client(() => new Response('x', { status: 503 })).catalog(null).catch((e: Error) => e.message)))
      .toBe('O Catálogo respondeu com erro (503).');
    await expect(client(() => new Response('x', { status: 401 })).catalog(null)).rejects.toBeInstanceOf(CatalogUnavailable);
    await expect(client(() => Response.json({ nada: true })).catalog(null)).rejects.toBeInstanceOf(CatalogUnavailable);
    const offline = new CatalogClient({ url: BASE, key: 'cat_segredo' }, async () => {
      throw new TypeError('fetch failed');
    });
    const error = await offline.barcode('7891058002916').catch((e: Error) => e);
    expect(error).toBeInstanceOf(CatalogUnavailable);
    expect((error as Error).message).not.toContain('cat_segredo');
  });

  it('conferência da chave: 401 recusada, 403 suspensa, sem rede lança', async () => {
    expect(await client(() => Response.json([])).verify()).toBe('ok');
    expect(calls[0]).toMatchObject({ url: `${BASE}/api/v1/categories`, headers: { 'X-Api-Key': 'cat_segredo' } });
    expect(await client(() => new Response('x', { status: 401 })).verify()).toBe('refused');
    expect(await client(() => new Response('x', { status: 403 })).verify()).toBe('suspended');
    await expect(client(() => new Response('x', { status: 500 })).verify()).rejects.toBeInstanceOf(CatalogUnavailable);
  });

  it('tributação do item no estado: os valores como vêm; 404 é null', async () => {
    const values = await client(() => Response.json({ product_id: 7, uf: 'SP', values: { cfop: '5405', cst_icms: '60' } })).tax('7', 'SP');
    expect(values).toEqual({ cfop: '5405', cst_icms: '60' });
    expect(calls[0]).toMatchObject({ url: `${BASE}/api/v1/products/7/tax?uf=SP`, headers: { 'X-Api-Key': 'cat_segredo' } });
    expect(await client(() => new Response('{}', { status: 404 })).tax('7', 'SP')).toBeNull();
    expect(await client(() => Response.json({ uf: 'SP' })).tax('7', 'SP')).toEqual({});
    await expect(client(() => new Response('x', { status: 401 })).tax('7', 'SP')).rejects.toBeInstanceOf(CatalogUnavailable);
  });

  it('código de barras: 404 é null; o código vai codificado', async () => {
    expect(await client(() => new Response('{}', { status: 404 })).barcode('7891058002916')).toBeNull();
    expect(await client(() => Response.json({ id: 3, name: 'X' })).barcode('7891058002916')).toEqual({ id: 3, name: 'X' });
    expect(calls[1].url).toBe(`${BASE}/api/v1/barcodes/7891058002916`);
    await expect(client(() => new Response('x', { status: 500 })).barcode('1')).rejects.toBeInstanceOf(CatalogUnavailable);
  });

  it('imagem só do próprio Catálogo e de até 5 MB, sem a chave', async () => {
    const small = client(() => new Response(Buffer.from('abc')));
    expect((await small.image(`${BASE}/files/a.webp`)).toString()).toBe('abc');
    expect(calls[0].headers['X-Api-Key']).toBeUndefined();
    await expect(small.image('https://outro.test/files/a.webp')).rejects.toBeInstanceOf(CatalogUnavailable);
    await expect(small.image(`${BASE}/api/v1/catalog.json`)).rejects.toBeInstanceOf(CatalogUnavailable);
    const big = client(() => new Response(Buffer.alloc(10), { headers: { 'Content-Length': String(6 * 1024 * 1024) } }));
    await expect(big.image(`${BASE}/files/b.webp`)).rejects.toBeInstanceOf(CatalogUnavailable);
    const sneaky = client(() => new Response(Buffer.alloc(5 * 1024 * 1024 + 1)));
    await expect(sneaky.image(`${BASE}/files/c.webp`)).rejects.toBeInstanceOf(CatalogUnavailable);
  });
});
