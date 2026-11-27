import { MiddlewareConsumer, Module, NestModule, RequestMethod } from '@nestjs/common';
import express from 'express';
import { APP_FILTER, APP_GUARD } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AuthController } from './auth/auth.controller.js';
import { PlatformController } from './auth/platform.controller.js';
import { LoginImageController } from './auth/login-image.controller.js';
import { RolesController } from './auth/roles.controller.js';
import { SessionGuard } from './auth/session.guard.js';
import { UsersController } from './auth/users.controller.js';
import { AgreementInvoicesController, AgreementsController } from './customers/agreements.controller.js';
import { CashbackController } from './customers/cashback.controller.js';
import { CreditController } from './customers/credit.controller.js';
import { CustomersController } from './customers/customers.controller.js';
import { DatabaseService } from './database.service.js';
import { FiscalController } from './fiscal/fiscal.controller.js';
import { HealthController } from './health.controller.js';
import { PurchaseContentService } from './purchases/purchase-content.service.js';
import { PurchaseInvoicesController } from './purchases/purchase-invoices.controller.js';
import { ServiceInvoicesController } from './purchases/service-invoices.controller.js';
import { DfeController } from './sefaz/dfe.controller.js';
import { DfeService } from './sefaz/dfe.service.js';
import { SngpcService } from './sngpc/sngpc.service.js';
import { AbcController } from './customers/abc.controller.js';
import { AbcService } from './customers/abc.service.js';
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
import { SngpcController } from './sales/sngpc.controller.js';
import { PlatformReleasesController, ReleasesController, TerminalUpdatesController } from './releases/releases.controller.js';
import { CashSessionsController } from './sales/cash-sessions.controller.js';
import { QuotesController } from './sales/quotes.controller.js';
import { TerminalQuotesController } from './terminals/terminal-quotes.controller.js';
import { TerminalReturnsController } from './terminals/terminal-returns.controller.js';
import { ReturnsController } from './sales/returns.controller.js';
import { PdvAuthEventsController } from './auth/pdv-auth-events.controller.js';
import { SalesController } from './sales/sales.controller.js';
import { ImportedSalesController } from './sales/imported-sales.controller.js';
import { ImportedNotesController } from './purchases/imported-notes.controller.js';
import { StockCountsController } from './stock/stock-counts.controller.js';
import { CentralNfeController } from './fiscal/central-nfe.controller.js';
import { CentralNfeService } from './fiscal/central-nfe.service.js';
import { FiscalDocumentsController } from './fiscal/fiscal-documents.controller.js';
import { TerminalFiscalController } from './terminals/terminal-fiscal.controller.js';
import { NfceActionsService } from './fiscal/nfce-actions.service.js';
import { OfflineRulesController, TerminalStockController } from './terminals/offline-rules.controller.js';
import { TerminalNfceController } from './terminals/terminal-nfce.controller.js';
import { HealthProfessionalsController } from './sales/health-professionals.controller.js';
import { ImportIssuersController } from './imports/import-issuers.controller.js';
import { ImportsController } from './imports/imports.controller.js';
import { ImportsService } from './imports/imports.service.js';
import { TerminalCashbackController } from './terminals/terminal-cashback.controller.js';
import { TerminalCustomersController } from './terminals/terminal-customers.controller.js';
import { TerminalSyncController } from './terminals/terminal-sync.controller.js';
import { TerminalGuard } from './terminals/terminal.guard.js';

@Module({
  imports: [
    // Limite padrão por IP; as rotas sensíveis definem limites menores.
    ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: 600 }]),
  ],
  controllers: [
    AbcController,
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
    CashbackController,
    PlatformController,
    LoginImageController,
    AgreementsController,
    AgreementInvoicesController,
    SuppliersController,
    PurchaseInvoicesController,
    ServiceInvoicesController,
    DfeController,
    FiscalController,
    StructureController,
    TerminalDeviceController,
    TerminalSyncController,
    TerminalCustomersController,
    TerminalCashbackController,
    SalesController,
    ImportedSalesController,
    ImportedNotesController,
    StockCountsController,
    FiscalDocumentsController,
    CentralNfeController,
    TerminalFiscalController,
    ControlledController,
    SngpcController,
    ReleasesController,
    PlatformReleasesController,
    TerminalUpdatesController,
    CashSessionsController,
    QuotesController,
    TerminalQuotesController,
    TerminalReturnsController,
    PdvAuthEventsController,
    ReturnsController,
    OfflineRulesController,
    TerminalStockController,
    TerminalNfceController,
    HealthProfessionalsController,
    ImportsController,
    ImportIssuersController,
    SyncConflictsController,
    TerminalAdminController,
  ],
  providers: [
    DatabaseService,
    DfeService,
    SngpcService,
    AbcService,
    PurchaseContentService,
    ImportsService,
    NfceActionsService,
    CentralNfeService,
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
    // A planilha do inventário chega como texto (CSV), com limite próprio.
    consumer
      .apply(express.text({ type: ['text/csv', 'text/plain'], limit: '5mb' }))
      .forRoutes({ path: 'admin/stock-counts/:id/file', method: RequestMethod.POST });
  }
}
