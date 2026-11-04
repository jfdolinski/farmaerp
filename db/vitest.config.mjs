import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['tests/**/*.test.mjs'],
    globalSetup: ['tests/global-setup.mjs'],
    // Todos os testes usam o mesmo banco.
    fileParallelism: false,
    testTimeout: 20000,
    hookTimeout: 60000,
  },
});
