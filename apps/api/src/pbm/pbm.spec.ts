import { describe, expect, it } from 'vitest';
import { AppError } from '../observability/app-error.js';
import { PbmCall, TestPbmConnector } from './pbm-connector.js';
import { beneficiaryOf, itemsOf } from './pbm.controller.js';

const A = '019a0000-0000-7000-8000-0000000000a1';
const B = '019a0000-0000-7000-8000-0000000000b2';
const call: PbmCall = { credentials: null, testRules: async (ids) => new Map(ids.filter((id) => id === A).map((id) => [id, 40])) };
const codeOf = async (promise: Promise<unknown>) => promise.then(() => 'ok', (error: unknown) => (error as AppError).code);

describe('programa de teste', () => {
  const connector = new TestPbmConnector();

  it('aplica o percentual só nos produtos com regra, arredondando em centavos', async () => {
    const quote = await connector.authorize(call, '52998224725', [
      { productId: A, quantity: 2, unitPrice: 25.99 },
      { productId: B, quantity: 1, unitPrice: 10 },
    ]);
    expect(quote.externalId).toMatch(/^TESTE-[0-9A-F-]{13}$/);
    expect(quote.items).toEqual([{ productId: A, quantity: 2, listPrice: 25.99, pbmPrice: 15.59 }]);
  });

  it('documento terminado em 0 não tem direito; FORA simula o programa fora do ar; sem produto do programa, FA796', async () => {
    expect(await codeOf(connector.authorize(call, '11144477730', [{ productId: A, quantity: 1, unitPrice: 10 }]))).toBe('FA794');
    expect(await codeOf(connector.authorize(call, 'FORA1234', [{ productId: A, quantity: 1, unitPrice: 10 }]))).toBe('FA797');
    expect(await codeOf(connector.authorize(call, '52998224725', [{ productId: B, quantity: 1, unitPrice: 10 }]))).toBe('FA796');
  });
});

describe('dados do caixa', () => {
  const failsWith = (fn: () => unknown) => {
    try {
      fn();
    } catch (error) {
      return (error as AppError).code;
    }
    return 'ok';
  };

  it('beneficiário: só letras e números, maiúsculo, de 4 a 30', () => {
    expect(beneficiaryOf('529.982.247-25')).toBe('52998224725');
    expect(beneficiaryOf('cartao-12ab')).toBe('CARTAO12AB');
    expect(failsWith(() => beneficiaryOf('1-2'))).toBe('FA005');
    expect(failsWith(() => beneficiaryOf('1'.repeat(31)))).toBe('FA005');
    expect(failsWith(() => beneficiaryOf(123))).toBe('FA005');
  });

  it('itens: produto uma vez só, quantidade até 3 casas, preço positivo com 2 casas', () => {
    expect(itemsOf([{ productId: A, quantity: 1.5, unitPrice: 10.9 }])).toEqual([{ productId: A, quantity: 1.5, unitPrice: 10.9 }]);
    expect(failsWith(() => itemsOf([]))).toBe('FA005');
    expect(failsWith(() => itemsOf([{ productId: A, quantity: 1, unitPrice: 1 }, { productId: A, quantity: 1, unitPrice: 1 }]))).toBe('FA005');
    expect(failsWith(() => itemsOf([{ productId: A, quantity: 0, unitPrice: 1 }]))).toBe('FA005');
    expect(failsWith(() => itemsOf([{ productId: A, quantity: 1.0001, unitPrice: 1 }]))).toBe('FA005');
    expect(failsWith(() => itemsOf([{ productId: A, quantity: 1, unitPrice: 1.001 }]))).toBe('FA005');
    expect(failsWith(() => itemsOf([{ productId: A, quantity: 1, unitPrice: 0 }]))).toBe('FA005');
    expect(failsWith(() => itemsOf([{ productId: 'x', quantity: 1, unitPrice: 1 }]))).toBe('FA005');
  });
});
