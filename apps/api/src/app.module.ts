import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { APP_FILTER } from '@nestjs/core';
import { DatabaseService } from './database.service.js';
import { HealthController } from './health.controller.js';
import { AllExceptionsFilter } from './observability/all-exceptions.filter.js';
import { AppLogger, createPinoLogger } from './observability/app-logger.js';
import { TraceMiddleware } from './observability/trace.middleware.js';

@Module({
  controllers: [HealthController],
  providers: [
    DatabaseService,
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
