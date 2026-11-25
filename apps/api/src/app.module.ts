import { MiddlewareConsumer, Module, NestModule, RequestMethod } from '@nestjs/common';
import express from 'express';
import { APP_FILTER, APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AuthController } from './auth/auth.controller.js';
import { RolesController } from './auth/roles.controller.js';
import { SessionGuard } from './auth/session.guard.js';
import { UsersController } from './auth/users.controller.js';
import { AgreementsController } from './customers/agreements.controller.js';
import { CreditController } from './customers/credit.controller.js';
import { CustomersController } from './customers/customers.controller.js';
import { DatabaseService } from './database.service.js';
import { FiscalController } from './fiscal/fiscal.controller.js';
import { HealthController } from './health.controller.js';
import { PurchaseInvoicesController } from './purchases/purchase-invoices.controller.js';
import { ServiceInvoicesController } from './purchases/service-invoices.controller.js';
import { DfeController } from './sefaz/dfe.controller.js';
import { DfeService } from './sefaz/dfe.service.js';
import { SuppliersController } from './purchases/suppliers.controller.js';
import { AllExceptionsFilter } from './observability/all-exceptions.filter.js';
import { AppLogger, createPinoLogger } from './observability/app-logger.js';
import { CatalogImagesController } from './products/catalog-images.js';
import { ProductsController } from './products/products.controller.js';
import { RulesController } from './products/rules.controller.js';
import { DiscountsController } from './products/discounts.controller.js';
import { StockController } from './products/stock.controller.js';
import { TraceMiddleware } from './observability/trace.middleware.js';
import { StructureController } from './structure/structure.controller.js';
import { TerminalAdminController } from './terminals/terminal-admin.controller.js';
import { TerminalDeviceController } from './terminals/terminal-device.controller.js';
import { SyncConflictsController } from './terminals/sync-conflicts.controller.js';
import { ControlledController } from './sales/controlled.controller.js';
import { CashSessionsController } from './sales/cash-sessions.controller.js';
import { QuotesController } from './sales/quotes.controller.js';
import { TerminalQuotesController } from './terminals/terminal-quotes.controller.js';
import { TerminalReturnsController } from './terminals/terminal-returns.controller.js';
import { ReturnsController } from './sales/returns.controller.js';
import { PdvAuthEventsController } from './auth/pdv-auth-events.controller.js';
import { SalesController } from './sales/sales.controller.js';
import { OfflineRulesController, TerminalStockController } from './terminals/offline-rules.controller.js';
import { TerminalCustomersController } from './terminals/terminal-customers.controller.js';
import { TerminalSyncController } from './terminals/terminal-sync.controller.js';
import { TerminalGuard } from './terminals/terminal.guard.js';

@Module({
  imports: [
    // Limite padrão por IP; as rotas sensíveis definem limites menores.
    ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: 600 }]),
  ],
  controllers: [
    HealthController,
    AuthController,
    UsersController,
    RolesController,
    ProductsController,
    CatalogImagesController,
    RulesController,
    DiscountsController,
    StockController,
    CustomersController,
    CreditController,
    AgreementsController,
    SuppliersController,
    PurchaseInvoicesController,
    ServiceInvoicesController,
    DfeController,
    FiscalController,
    StructureController,
    TerminalDeviceController,
    TerminalSyncController,
    TerminalCustomersController,
    SalesController,
    ControlledController,
    CashSessionsController,
    QuotesController,
    TerminalQuotesController,
    TerminalReturnsController,
    PdvAuthEventsController,
    ReturnsController,
    OfflineRulesController,
    TerminalStockController,
    SyncConflictsController,
    TerminalAdminController,
  ],
  providers: [
    DatabaseService,
    DfeService,
    SessionGuard,
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
    // O XML da nota chega como texto, só nesta rota e com limite próprio; o resto segue no limite padrão.
    consumer
      .apply(express.text({ type: ['application/xml', 'text/xml'], limit: '5mb' }))
      .forRoutes({ path: 'admin/purchase-invoices', method: RequestMethod.POST });
  }
}
