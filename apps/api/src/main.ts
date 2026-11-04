import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';
import { assertEnvironment } from './config/environment.js';
import { AppLogger } from './observability/app-logger.js';

async function bootstrap() {
  try {
    // Só em desenvolvimento: em produção as variáveis vêm do EasyPanel.
    process.loadEnvFile('../../.env');
  } catch {
    // Sem arquivo .env, valem as variáveis do ambiente.
  }

  assertEnvironment();

  const app = await NestFactory.create(AppModule, { bufferLogs: true });
  app.useLogger(app.get(AppLogger));
  if (process.env.TRUST_PROXY === 'true') {
    // Atrás do proxy do EasyPanel, o IP real do limite de tentativas vem do cabeçalho.
    app.getHttpAdapter().getInstance().set('trust proxy', 1);
  }
  await app.listen(process.env.PORT ?? 3001);
}
await bootstrap();
