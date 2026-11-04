import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['test/**/*.integration-spec.ts'],
    globalSetup: ['test/integration-setup.mjs'],
    fileParallelism: false,
    testTimeout: 20000,
    hookTimeout: 60000,
    env: {
      DB_NAME: 'farmaerp_integration',
      TERMINAL_TOKEN_SECRET: 'segredo-de-teste-com-mais-de-32-caracteres',
    },
  },
});
