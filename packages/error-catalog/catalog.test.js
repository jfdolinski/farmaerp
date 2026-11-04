import { describe, expect, it } from 'vitest';
import { catalog, codeFromDbError, getError } from './index.js';

describe('catálogo', () => {
  it.each(Object.entries(catalog))('%s está completo', (code, entry) => {
    expect(code).toMatch(/^FA[0-9]{3}$/);
    expect(entry.message.trim()).not.toBe('');
    expect(entry.action.trim()).not.toBe('');
    expect(entry.httpStatus).toBeGreaterThanOrEqual(400);
    expect(entry.httpStatus).toBeLessThan(600);
    expect(['warning', 'error']).toContain(entry.severity);
    expect(typeof entry.retryable).toBe('boolean');
    expect(Array.isArray(entry.dbConstraints)).toBe(true);
  });

  it('cada constraint pertence a um único código', () => {
    const constraints = Object.values(catalog).flatMap((entry) => entry.dbConstraints);
    expect(new Set(constraints).size).toBe(constraints.length);
  });

  it('nenhuma mensagem expõe termos técnicos', () => {
    for (const [code, entry] of Object.entries(catalog)) {
      expect(`${entry.message} ${entry.action}`, code).not.toMatch(
        /SQL|constraint|trigger|uuid|null|exception|stack/i,
      );
    }
  });
});

describe('getError', () => {
  it('retorna a entrada com o código', () => {
    expect(getError('FA203')).toMatchObject({ code: 'FA203', httpStatus: 422 });
  });

  it.each(['FA999', 'constructor', '__proto__', ''])('código desconhecido %j vira FA000', (code) => {
    expect(getError(code).code).toBe('FA000');
  });
});

describe('codeFromDbError', () => {
  it.each([
    ['código do catálogo', { code: 'FA203' }, 'FA203'],
    ['constraint de negócio', { code: '23505', constraint: 'branch_cnpj_active_key' }, 'FA212'],
    ['único sem regra própria', { code: '23505', constraint: 'outra' }, 'FA003'],
    ['chave estrangeira', { code: '23503' }, 'FA004'],
    ['RLS', { code: '42501' }, 'FA002'],
    ['UUID malformado', { code: '22P02' }, 'FA005'],
    ['espera de trava', { code: '55P03' }, 'FA008'],
    ['conexão recusada', { code: 'ECONNREFUSED' }, 'FA001'],
    ['classe de conexão', { code: '08006' }, 'FA001'],
    ['tempo de conexão', { message: 'timeout exceeded when trying to connect' }, 'FA001'],
    ['conexão encerrada', { message: 'Connection terminated unexpectedly' }, 'FA001'],
    ['erro desconhecido', { code: 'XX000' }, null],
    ['código herdado', { code: 'constructor' }, null],
    ['sem dados', {}, null],
    ['nulo', null, null],
  ])('%s', (_label, error, expected) => {
    expect(codeFromDbError(error)).toBe(expected);
  });
});
