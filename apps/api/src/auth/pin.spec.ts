import { pbkdf2Sync } from 'node:crypto';
import { hashPin, isAcceptablePin, PIN_ITERATIONS } from './pin.js';

describe('PIN do PDV', () => {
  it('aceita de 4 a 6 números que não sejam repetidos nem sequência', () => {
    for (const pin of ['1357', '2468', '90210', '135790', '1243']) expect(isAcceptablePin(pin)).toBe(true);
    for (const pin of ['', '123', '1234567', '12a4', ' 1357', '1111', '000000', '1234', '3456', '123456', '9876', '654321', 1357, null]) {
      expect(isAcceptablePin(pin)).toBe(false);
    }
  });

  it('gera o hash no formato que o PDV confere, com sal próprio', async () => {
    const salt = Buffer.alloc(16, 7);
    const hash = await hashPin('1357', salt);
    const [scheme, iterations, saltText, digest] = hash.split('$');
    expect([scheme, Number(iterations)]).toEqual(['pbkdf2-sha256', PIN_ITERATIONS]);
    expect(Buffer.from(saltText, 'base64')).toEqual(salt);
    expect(digest).toBe(pbkdf2Sync('1357', salt, PIN_ITERATIONS, 32, 'sha256').toString('base64'));
    expect(hash).toMatch(/^pbkdf2-sha256\$[0-9]{6,7}\$[A-Za-z0-9+/]{22}==\$[A-Za-z0-9+/]{43}=$/);
    expect(await hashPin('1357')).not.toBe(await hashPin('1357'));
  });
});
