import { describe, expect, it } from 'vitest';
import { normalizeDate, normalizeQuantity, parseCountCsv } from './stock-count-csv.js';

describe('planilha da contagem', () => {
  it('com cabeçalho em qualquer ordem, ponto e vírgula, aspas e número brasileiro', () => {
    const csv = '﻿Lote;Código;Quantidade;Validade\r\n"L-1";7891234567895;"1.234,5";31/12/2027\r\n\r\n;123;2;\r\n';
    expect(parseCountCsv(csv)).toEqual([
      { line: 2, lookup: '7891234567895', quantity: '1234.5', batch: 'L-1', expires_on: '2027-12-31' },
      { line: 4, lookup: '123', quantity: '2', batch: null, expires_on: null },
    ]);
  });

  it('sem cabeçalho: código, quantidade, lote e validade, separados por vírgula ou tabulação', () => {
    expect(parseCountCsv('ANT-9,3\n789,1,AB12,06/2028\n')).toEqual([
      { line: 1, lookup: 'ANT-9', quantity: '3', batch: null, expires_on: null },
      { line: 2, lookup: '789', quantity: '1', batch: 'AB12', expires_on: '2028-06-30' },
    ]);
    expect(parseCountCsv('789\t2,5\n')).toEqual([{ line: 1, lookup: '789', quantity: '2.5', batch: null, expires_on: null }]);
  });

  it('o que não dá para entender segue como veio (o banco recusa a linha)', () => {
    expect(normalizeQuantity('abc')).toBe('abc');
    expect(normalizeQuantity('1.5')).toBe('1.5');
    expect(normalizeQuantity('10')).toBe('10');
    expect(normalizeDate('13/2028')).toBe('13/2028');
    expect(normalizeDate('2028-01-31')).toBe('2028-01-31');
    expect(normalizeDate('02/2028')).toBe('2028-02-29');
    expect(parseCountCsv('codigo;qtd;cor\n1;2;azul')).toEqual([{ line: 2, lookup: '1', quantity: '2', batch: null, expires_on: null }]);
  });
});
