import { isValidCnpj } from './customers.controller.js';

describe('validação de CNPJ na API', () => {
  it.each([
    ['11222333000181', true],
    ['33000167000101', true],
    // Exemplo oficial do CNPJ alfanumérico.
    ['12ABC34501DE35', true],
    ['11222333000182', false],
    ['11111111111111', false],
    ['1122233300018', false],
    ['12abc34501de35', false],
  ])('%s: %s', (cnpj, expected) => {
    expect(isValidCnpj(cnpj)).toBe(expected);
  });
});
