import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module.js';

async function bootstrap() {
  try {
    // Só em desenvolvimento: em produção as variáveis vêm do EasyPanel.
    process.loadEnvFile('../../.env');
  } catch {
    // Sem arquivo .env, valem as variáveis do ambiente.
  }

  const app = await NestFactory.create(AppModule);
  await app.listen(process.env.PORT ?? 3001);
}
await bootstrap();
