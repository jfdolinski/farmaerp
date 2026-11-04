import { sanitize, serializeError } from './sanitize.js';

describe('sanitize', () => {
  it.each([
    'cpf',
    'CPF',
    'senha',
    'password',
    'pin',
    'token',
    'accessToken',
    'access_token',
    'authorization',
    'cookie',
    'certificado',
    'face_code',
    'biometria',
    'body',
  ])('mascara o campo %s em qualquer nível', (key) => {
    const result = sanitize({ a: { b: [{ [key]: 'segredo' }] } });
    expect(JSON.stringify(result)).not.toContain('segredo');
    expect(JSON.stringify(result)).toContain('[protegido]');
  });

  it.each(['123.456.789-09', '12345678909'])(
    'mascara o CPF %s dentro de textos',
    (cpf) => {
      expect(sanitize(`cliente ${cpf} encontrado`)).toBe(
        'cliente [protegido] encontrado',
      );
    },
  );

  it('não mascara um CNPJ de 14 dígitos', () => {
    expect(sanitize('filial 11222333000181')).toBe('filial 11222333000181');
  });

  it('preserva campos comuns', () => {
    expect(sanitize({ status: 200, route: '/health', ok: true })).toEqual({
      status: 200,
      route: '/health',
      ok: true,
    });
  });

  it('não entra em recursão infinita', () => {
    const circular: Record<string, unknown> = {};
    circular.self = circular;
    expect(() => sanitize(circular)).not.toThrow();
  });
});

describe('serializeError', () => {
  it('mantém o detalhe de erros do catálogo', () => {
    const error = Object.assign(new Error('Erro'), {
      code: 'FA105',
      detail: 'branch possui filhos ativos em terminal.',
    });
    expect(serializeError(error)).toMatchObject({
      code: 'FA105',
      detail: 'branch possui filhos ativos em terminal.',
    });
  });

  it('descarta o detalhe do Postgres, que pode trazer valores de colunas', () => {
    const error = Object.assign(new Error('duplicate key'), {
      code: '23505',
      constraint: 'customer_cpf_key',
      detail: 'Key (cpf)=(12345678909) already exists.',
    });
    const serialized = serializeError(error);
    expect(JSON.stringify(serialized)).not.toContain('12345678909');
    expect(serialized).toMatchObject({ constraint: 'customer_cpf_key' });
  });

  it('omite o valor repetido pelos erros de dado inválido', () => {
    const error = Object.assign(
      new Error('invalid input syntax for type uuid: "Maria Silva"'),
      { code: '22P02' },
    );
    const serialized = serializeError(error);
    expect(JSON.stringify(serialized)).not.toContain('Maria');
    expect(serialized).toMatchObject({ code: '22P02' });
  });

  it('inclui a causa', () => {
    const error = new Error('fora', { cause: new Error('conexão recusada') });
    expect(serializeError(error)).toMatchObject({
      cause: { message: 'conexão recusada' },
    });
  });
});
