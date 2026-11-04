// Roda no início do contêiner: um ambiente errado não pode chegar a aplicar migrations.
import { assertEnvironment } from './environment.js';

try {
  assertEnvironment();
} catch (error) {
  console.error((error as Error).message);
  process.exit(1);
}
