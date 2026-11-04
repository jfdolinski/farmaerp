import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { APP_FILTER, APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { DatabaseService } from './database.service.js';
import { HealthController } from './health.controller.js';
import { AllExceptionsFilter } from './observability/all-exceptions.filter.js';
import { AppLogger, createPinoLogger } from './observability/app-logger.js';
import { TraceMiddleware } from './observability/trace.middleware.js';
import { DevUserGuard } from './terminals/dev-user.guard.js';
import { TerminalAdminController } from './terminals/terminal-admin.controller.js';
import { TerminalDeviceController } from './terminals/terminal-device.controller.js';
import { TerminalGuard } from './terminals/terminal.guard.js';

@Module({
  imports: [
    // Limite padrão por IP; as rotas sensíveis definem limites menores.
    ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: 600 }]),
  ],
  controllers: [
    HealthController,
    TerminalDeviceController,
    TerminalAdminController,
  ],
  providers: [
    DatabaseService,
    DevUserGuard,
    TerminalGuard,
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    {
      provide: AppLogger,
      useFactory: () => new AppLogger(createPinoLogger()),
    },
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
  ],
  exports: [DatabaseService, AppLogger],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(TraceMiddleware).forRoutes('{*splat}');
  }
}
