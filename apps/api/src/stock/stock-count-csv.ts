/**
 * Planilha da contagem (CSV): código (barras, interno ou do sistema anterior), quantidade e, para os
 * produtos com lote, lote e validade. Aceita ";" ou "," ou tabulação, cabeçalho opcional, número
 * no formato brasileiro (1.234,5) e validade em dd/mm/aaaa, mm/aaaa ou aaaa-mm-dd. O que não dá
 * para entender segue como veio: o banco recusa a linha com o motivo.
 */
export interface CountRow {
  line: number;
  lookup: string;
  quantity: string;
  batch: string | null;
  expires_on: string | null;
}

export const MAX_ROWS = 50_000;

const HEADERS: Record<string, keyof Omit<CountRow, 'line'>> = {
  codigo: 'lookup', 'código': 'lookup', cod: 'lookup', ean: 'lookup', gtin: 'lookup', barras: 'lookup', 'codigo de barras': 'lookup',
  'código de barras': 'lookup', produto: 'lookup',
  quantidade: 'quantity', qtd: 'quantity', qtde: 'quantity', contagem: 'quantity', contado: 'quantity',
  lote: 'batch',
  validade: 'expires_on', vencimento: 'expires_on', 'data de validade': 'expires_on',
};

function splitLine(line: string, separator: string): string[] {
  const cells: string[] = [];
  let current = '';
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (quoted) {
      if (char === '"' && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else if (char === '"') {
        quoted = false;
      } else {
        current += char;
      }
    } else if (char === '"') {
      quoted = true;
    } else if (char === separator) {
      cells.push(current.trim());
      current = '';
    } else {
      current += char;
    }
  }
  cells.push(current.trim());
  return cells;
}

/** 1.234,5 → 1234.5; 1234.5 fica; o resto segue como veio. */
export function normalizeQuantity(value: string): string {
  const text = value.trim().replace(/\s/g, '');
  if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(text) || /^\d+,\d+$/.test(text)) return text.replace(/\./g, '').replace(',', '.');
  return text;
}

/** dd/mm/aaaa, mm/aaaa (último dia do mês) ou aaaa-mm-dd → aaaa-mm-dd. */
export function normalizeDate(value: string): string | null {
  const text = value.trim();
  if (text === '') return null;
  let match = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(text);
  if (match) return `${match[3]}-${match[2].padStart(2, '0')}-${match[1].padStart(2, '0')}`;
  match = /^(\d{1,2})\/(\d{4})$/.exec(text);
  if (match) {
    const month = Number(match[1]);
    if (month < 1 || month > 12) return text;
    const last = new Date(Date.UTC(Number(match[2]), month, 0)).getUTCDate();
    return `${match[2]}-${String(month).padStart(2, '0')}-${String(last).padStart(2, '0')}`;
  }
  return text;
}

export function parseCountCsv(content: string): CountRow[] {
  const lines = content.replace(/^﻿/, '').split(/\r\n|\n|\r/);
  const first = lines.find((line) => line.trim() !== '') ?? '';
  const separator = first.includes(';') ? ';' : first.includes('\t') ? '\t' : ',';
  let columns: (keyof Omit<CountRow, 'line'> | null)[] = ['lookup', 'quantity', 'batch', 'expires_on'];
  let start = 0;
  const firstIndex = lines.indexOf(first);
  const firstCells = splitLine(first, separator).map((cell) => cell.toLowerCase());
  // Cabeçalho: a segunda coluna não é número.
  if (firstCells.length > 1 && !/^[\d.,\s-]+$/.test(firstCells[1])) {
    columns = firstCells.map((cell) => HEADERS[cell] ?? null);
    start = firstIndex + 1;
  }
  const rows: CountRow[] = [];
  for (let index = start; index < lines.length; index += 1) {
    if (lines[index].trim() === '') continue;
    const cells = splitLine(lines[index], separator);
    const value = (field: keyof Omit<CountRow, 'line'>) => {
      const position = columns.indexOf(field);
      return position < 0 ? '' : (cells[position] ?? '');
    };
    rows.push({
      line: index + 1,
      lookup: value('lookup'),
      quantity: normalizeQuantity(value('quantity')),
      batch: value('batch') === '' ? null : value('batch'),
      expires_on: normalizeDate(value('expires_on')),
    });
  }
  return rows;
}
