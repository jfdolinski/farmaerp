import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['**/*.e2e-spec.ts'],
    env: {
      TERMINAL_TOKEN_SECRET: 'segredo-de-teste-com-mais-de-32-caracteres',
    },
  },
});
