import { afterAll, describe, expect, it } from 'vitest';
import { closePools, ownerPool } from './helpers.mjs';

afterAll(closePools);

const valid = (value, state) =>
  ownerPool.query('SELECT app.is_valid_state_registration(app.clean_state_registration($1), $2) AS ok', [value, state])
    .then((r) => r.rows[0].ok);

// Exemplos válidos dos roteiros de cada estado no SINTEGRA (www.sintegra.gov.br/insc_est.html).
const OFFICIAL = [
  ['AC', '01.004.823/001-12'],
  ['AL', '240000048'],
  ['AP', '030123459'],
  ['BA', '123456-63'],
  ['BA', '612345-57'],
  ['BA', '1000003-06'],
  ['CE', '06000001-5'],
  ['DF', '073.00001.001-09'],
  ['ES', '999999990'],
  ['GO', '10.987.654-7'],
  ['MA', '120000385'],
  ['MG', '062.307.904/0081'],
  ['MT', '0013000001-9'],
  ['PA', '15999999-5'],
  ['PA', '75000002-3'],
  ['PB', '06000001-5'],
  ['PE', '0321418-40'],
  ['PE', '18.1.001.0000004-9'],
  ['PI', '012345679'],
  ['PR', '123.45678-50'],
  ['RJ', '99.999.99-3'],
  ['RN', '20.040.040-1'],
  ['RN', '20.0.040.040-0'],
  ['RO', '101.62521-3'],
  ['RO', '0000000062521-3'],
  ['RR', '24006628-1'],
  ['RR', '24001755-6'],
  ['RR', '24003429-0'],
  ['RR', '24001360-3'],
  ['RR', '24008266-8'],
  ['RR', '24006153-6'],
  ['RR', '24007356-2'],
  ['RR', '24005467-4'],
  ['RR', '24004145-5'],
  ['RR', '24001340-7'],
  ['RS', '224/3658792'],
  ['SC', '251.040.852'],
  ['SE', '27123456-3'],
  ['SP', '110.042.490.114'],
  ['SP', 'P-01100424.3/002'],
  ['TO', '29 01 022783 6'],
];

/** Troca o último dígito: a inscrição deixa de valer. */
const breakLast = (value) => {
  const digits = value.replace(/[^0-9P]/gi, '');
  const last = Number(digits.at(-1));
  return `${digits.slice(0, -1)}${(last + 1) % 10}`;
};

describe('inscrição estadual: exemplos oficiais', () => {
  it.each(OFFICIAL)('%s %s é válida', async (state, value) => {
    expect(await valid(value, state)).toBe(true);
  });

  it.each(OFFICIAL.filter(([state, value]) => !(state === 'SP' && value.startsWith('P'))))(
    '%s %s com o último dígito trocado é recusada',
    async (state, value) => {
      expect(await valid(breakLast(value), state)).toBe(false);
    },
  );

  it('SP produtor rural: o dígito do meio é que vale, não o final', async () => {
    expect(await valid('P-01100424.4/002', 'SP')).toBe(false);
    expect(await valid('P-01100424.3/009', 'SP')).toBe(true);
  });

  it('inscrição de um estado não vale em outro', async () => {
    expect(await valid('110.042.490.114', 'RJ')).toBe(false);
    expect(await valid('99.999.99-3', 'SP')).toBe(false);
  });
});

describe('inscrição estadual: regras de formato', () => {
  it.each([
    ['AC sem o prefixo 01', 'AC', '0200482300112'],
    ['AP sem o prefixo 03', 'AP', '040123459'],
    ['AL com tipo de empresa inexistente', 'AL', '241000048'],
    ['MA sem o prefixo 12', 'MA', '130000385'],
    ['MS sem o prefixo 28 ou 50', 'MS', '290000005'],
    ['PA com prefixo inexistente', 'PA', '16999999-5'],
    ['RN sem o prefixo 20', 'RN', '210400401'],
    ['RR sem o prefixo 24', 'RR', '250066281'],
    ['TO com tipo de empresa inexistente', 'TO', '29050227836'],
    ['GO com prefixo inexistente', 'GO', '309876547'],
    ['letra fora de SP', 'RJ', 'P9999993'],
    ['tamanho errado', 'SP', '11004249011'],
    ['estado inexistente', 'XX', '110042490114'],
  ])('recusa %s', async (_label, state, value) => {
    expect(await valid(value, state)).toBe(false);
  });

  it('ISENTO em qualquer grafia vale em qualquer estado', async () => {
    expect(await valid(' isento ', 'AM')).toBe(true);
  });
});

/** Gera inscrições válidas pela regra, para os estados sem exemplo oficial na página. */
async function generated(state, length, prefix) {
  for (let i = 0; i < 2000; i += 1) {
    const body = `${prefix}${String(i).padStart(length - prefix.length - 1, '0')}`;
    for (let d = 0; d <= 9; d += 1) {
      if (await valid(`${body}${d}`, state)) return `${body}${d}`;
    }
  }
  return null;
}

describe('inscrição estadual: estados sem exemplo oficial', () => {
  it('AM: há exatamente um dígito válido para cada número', async () => {
    let count = 0;
    for (let d = 0; d <= 9; d += 1) if (await valid(`04112345${d}`, 'AM')) count += 1;
    expect(count).toBe(1);
  });

  it('MS: há exatamente um dígito válido para cada número', async () => {
    let count = 0;
    for (let d = 0; d <= 9; d += 1) if (await valid(`28123456${d}`, 'MS')) count += 1;
    expect(count).toBe(1);
  });

  it('MS: acha um número válido com o prefixo 50', async () => {
    expect(await generated('MS', 9, '50')).not.toBeNull();
  });
});
