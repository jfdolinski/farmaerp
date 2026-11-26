import { describe, expect, it } from 'vitest';
import { parseEntry } from './nfe-parse.js';

import { cancelXml, KEY, NFE_KEY, nfceXml, nfeXml } from '../../test/import-fixtures.js';

describe('leitura das notas para a importação', () => {
  it('NFC-e autorizada: emitente, destinatário, itens com a tributação, pagamentos e totais', () => {
    const entry = parseEntry(nfceXml());
    expect(entry.kind).toBe('note');
    if (entry.kind !== 'note') return;
    const { note } = entry;
    expect(note).toMatchObject({
      access_key: KEY, model: '65', series: 1, number: 42, emitted_at: '2026-06-10T10:00:00-03:00', environment: '1',
      status_code: '100', protocol: '135260000000001', subtotal: 33, discount: 1, total: 32, change: 8,
      customer: { document: '11144477735', name: null },
    });
    expect(note.issuer).toMatchObject({ cnpj: '11222333000181', crt: '1', state_registration: 'ISENTO', uf: 'SP', postal_code: '01001000', city_code: '3550308' });
    expect(note.items[0]).toMatchObject({
      line: 1, code: '000123', gtin: '7891234567895', quantity: 2, unit_price: 12.5, discount: 1, total: 24, cfop: '5405',
      anvisa_code: '1234567890123', pmc: 15.9, info: 'Uso adulto',
      tax: { origin: 0, icms_csosn: '500', icms_cst: null, pis_cst: '04', cofins_cst: '04' },
    });
    expect(note.items[1]).toMatchObject({
      code: 'B-9', gtin: null, total: 8,
      tax: { icms_cst: '00', icms_rate: 18, pis_cst: '01', pis_rate: 0.65, cofins_rate: 3, benefit_code: 'SP000001' },
    });
    expect(note.payments).toEqual([
      { type: '01', description: null, amount: 40, card_brand: null, authorization: null },
      { type: '03', description: null, amount: 0, card_brand: '01', authorization: 'ABC123' },
    ]);
    expect(note.xml).toContain('<nfeProc');
  });

  it('sem destinatário, sem cliente; sem protocolo, entra como não autorizada', () => {
    const anonymous = parseEntry(nfceXml({ dest: '' }));
    expect(anonymous.kind === 'note' && anonymous.note.customer).toBeNull();
    const loose = parseEntry(nfceXml({ protocol: false }));
    expect(loose.kind === 'note' && [loose.note.status_code, loose.note.access_key]).toEqual(['', KEY]);
  });

  it('cancelamento homologado vira cancelamento; outros eventos e modelos ficam para depois; lixo é recusado', () => {
    expect(parseEntry(cancelXml())).toEqual({ kind: 'cancel', accessKey: KEY, canceledAt: '2026-06-10T10:20:00-03:00' });
    expect(parseEntry(cancelXml('573'))).toMatchObject({ kind: 'other', accessKey: KEY });
    expect(parseEntry(nfceXml({ model: '57' }))).toMatchObject({ kind: 'other', model: '57', accessKey: KEY });
    expect(parseEntry('isto não é xml <')).toMatchObject({ kind: 'invalid' });
    expect(parseEntry('<qualquer><coisa/></qualquer>')).toMatchObject({ kind: 'invalid' });
  });

  it('NF-e de compra: tipo da operação, destinatário completo, frete, IPI, ST, GTIN tributável e lotes', () => {
    const entry = parseEntry(nfeXml());
    expect(entry.kind).toBe('note');
    if (entry.kind !== 'note') return;
    const { note } = entry;
    expect(note).toMatchObject({ access_key: NFE_KEY, model: '55', operation: '1', number: 1234, total: 67.2, status_code: '100' });
    expect(note.issuer).toMatchObject({ cnpj: '11444777000161', name: 'DISTRIBUIDORA EXEMPLO SA', uf: 'SP', city_code: '3509502' });
    expect(note.issuer).not.toHaveProperty('cpf');
    expect(note.dest).toMatchObject({ cnpj: '11222333000181', cpf: null, name: 'DROGARIA ANTIGA LTDA', postal_code: '01001000' });
    expect(note.items[0]).toMatchObject({
      code: 'FORN-77', gtin: null, tax_gtin: '7896004713656', unit: 'CX', quantity: 3, products_value: 60, discount: 1.5,
      freight: 3, insurance: 0, other: 0, ipi: 1.2, st: 4.2, fcp_st: 0.3, total: 58.5, cfop: '5102',
      batches: [
        { number: 'LT01', quantity: 2, manufactured_on: '2026-01-10', expires_on: '2027-12-31' },
        { number: 'LT02', quantity: 1, manufactured_on: '2026-02-10', expires_on: '2028-01-31' },
      ],
    });
    expect(parseEntry(nfeXml({ operation: '0' })).kind === 'note' && (parseEntry(nfeXml({ operation: '0' })) as { note: { operation: string } }).note.operation).toBe('0');
  });

  it('NFC-e não traz o destinatário completo nem lotes vazios quebram', () => {
    const entry = parseEntry(nfceXml());
    expect(entry.kind === 'note' && entry.note.dest).toBeNull();
    expect(entry.kind === 'note' && entry.note.items[0].batches).toEqual([]);
  });
});
