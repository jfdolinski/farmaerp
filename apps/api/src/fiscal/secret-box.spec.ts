import { randomBytes } from 'node:crypto';
import { open, seal } from './secret-box.js';

const code = (call: () => unknown) => {
  try {
    call();
  } catch (error) {
    return (error as { code?: string }).code;
  }
  return null;
};

describe('guarda de segredos', () => {
  const saved = process.env.FISCAL_ENCRYPTION_KEY;
  beforeEach(() => {
    process.env.FISCAL_ENCRYPTION_KEY = randomBytes(32).toString('base64');
  });
  afterAll(() => {
    process.env.FISCAL_ENCRYPTION_KEY = saved;
  });

  it('abre o que fechou, e duas cifras do mesmo conteúdo são diferentes', () => {
    const plain = Buffer.from('conteúdo secreto');
    const first = seal(plain, 'contexto');
    const second = seal(plain, 'contexto');
    expect(first.equals(second)).toBe(false);
    expect(first.includes(plain)).toBe(false);
    expect(open(first, 'contexto').equals(plain)).toBe(true);
  });

  it('não abre em outro contexto', () => {
    expect(code(() => open(seal(Buffer.from('x'), 'empresa-a'), 'empresa-b'))).toBe('FA915');
  });

  it('não abre conteúdo adulterado nem com outra chave', () => {
    const sealed = seal(Buffer.from('conteúdo'), 'c');
    const tampered = Buffer.from(sealed);
    tampered[tampered.length - 1] ^= 1;
    expect(code(() => open(tampered, 'c'))).toBe('FA915');
    process.env.FISCAL_ENCRYPTION_KEY = randomBytes(32).toString('base64');
    expect(code(() => open(sealed, 'c'))).toBe('FA915');
  });

  it.each([[undefined], [''], ['curta']])('chave ausente ou inválida (%j) dá FA915', (value) => {
    if (value === undefined) delete process.env.FISCAL_ENCRYPTION_KEY;
    else process.env.FISCAL_ENCRYPTION_KEY = value;
    expect(code(() => seal(Buffer.from('x'), 'c'))).toBe('FA915');
  });
});
