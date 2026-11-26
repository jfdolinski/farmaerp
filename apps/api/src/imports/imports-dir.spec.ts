import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { importsDir } from './imports.service.js';

describe('pasta da importação', () => {
  const previous = process.env.IMPORTS_DIR;
  afterEach(() => {
    if (previous === undefined) delete process.env.IMPORTS_DIR;
    else process.env.IMPORTS_DIR = previous;
  });

  it('IMPORTS_DIR tem prioridade; sem ela, usa o volume padrão só se ele existir', () => {
    const volume = mkdtempSync(join(tmpdir(), 'farmaerp-volume-'));
    try {
      process.env.IMPORTS_DIR = '/outra/pasta';
      expect(importsDir(volume)).toBe('/outra/pasta');
      process.env.IMPORTS_DIR = '  ';
      expect(importsDir(volume)).toBe(volume);
      delete process.env.IMPORTS_DIR;
      expect(importsDir(volume)).toBe(volume);
      expect(importsDir(join(volume, 'nao-existe'))).toBeNull();
    } finally {
      rmSync(volume, { recursive: true, force: true });
    }
  });
});
