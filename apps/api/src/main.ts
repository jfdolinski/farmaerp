import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';
import { AppLogger } from './observability/app-logger.js';

async function bootstrap() {
  try {
    // Só em desenvolvimento: em produção as variáveis vêm do EasyPanel.
    process.loadEnvFile('../../.env');
  } catch {
    // Sem arquivo .env, valem as variáveis do ambiente.
  }

  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  app.useLogger(app.get(AppLogger));
  await app.listen(process.env.PORT ?? 3001);
}
await bootstrap();
