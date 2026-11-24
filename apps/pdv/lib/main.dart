import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/app_environment.dart';
import 'core/error_display.dart';
import 'core/local_logger.dart';
import 'core/secret_store.dart';
import 'core/trace_id.dart';
import 'customers/customer_service.dart';
import 'local/local_database.dart';
import 'pos/display_settings.dart';
import 'pos/pdv_home.dart';
import 'pos/pos_auth.dart';
import 'pos/pos_controller.dart';
import 'sync/sync_service.dart';
import 'terminal/terminal_api.dart';
import 'terminal/terminal_controller.dart';
import 'terminal/terminal_screen.dart';

const _apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://localhost:3001',
);
const _appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.1.0',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dataDirectory = await getApplicationSupportDirectory();
  final logger = _createLogger(dataDirectory);
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logger.error(
      'Erro na interface',
      traceId: newTraceId(),
      errorCode: 'FA000',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logger.error(
      'Erro inesperado',
      traceId: newTraceId(),
      errorCode: 'FA000',
      error: error,
      stackTrace: stack,
    );
    return true;
  };

  logger.info(
    'PDV iniciado',
    fields: {'app_version': _appVersion, 'env': appEnvironment},
  );

  if (!isApiUrlAllowed(appEnvironment, _apiUrl)) {
    logger.error('Endereço da API não permitido', errorCode: 'FA010');
    runApp(const InvalidConfigurationApp());
    return;
  }

  final api = HttpTerminalApi(baseUrl: _apiUrl, logger: logger);
  final store = await createSecretStore(
    dataDirectory: dataDirectory,
    logger: logger,
  );
  final LocalDatabase database;
  try {
    database = await LocalDatabase.open(
      file: File(
        '${dataDirectory.path}${Platform.pathSeparator}farmaerp.db',
      ),
      store: store,
      logger: logger,
    );
  } catch (error, stack) {
    logger.error(
      'Banco local indisponível',
      traceId: newTraceId(),
      errorCode: 'FA957',
      error: error,
      stackTrace: stack,
    );
    runApp(const InvalidConfigurationApp(code: 'FA957'));
    return;
  }

  // Avisos e erros sobem para a central pela outbox.
  logger.onEntry = (entry) => database.enqueueLog(entry, now: DateTime.now());

  final controller = TerminalController(
    api: api,
    store: store,
    sync: SyncService(api: api, database: database, logger: logger),
    platform: Platform.operatingSystem,
    deviceName: Platform.localHostname,
    appVersion: _appVersion,
    logger: logger,
  );
  // Comprovante em PDF (sem impressora configurada) vai para os documentos do usuário.
  final documents = await getApplicationDocumentsDirectory();
  final pdfDirectory = Directory(
    '${documents.path}${Platform.pathSeparator}FarmaERP${Platform.pathSeparator}comprovantes',
  );
  final pos = PosController(
    database: database,
    auth: PosAuth(database: database, logger: logger),
    printer: () => configuredPrinter(database, pdfDirectory),
    terminalNumber: () => controller.terminalNumber,
    // A venda sobe logo, sem esperar o próximo sinal de vida.
    onSaleSaved: () => unawaited(controller.tick()),
    customers: CustomerService(api: api, database: database, accessToken: controller.accessToken, logger: logger),
    networkStock: (productId) async => api.networkStock(accessToken: await controller.accessToken(), productId: productId),
    openQuotes: () async => api.openQuotes(accessToken: await controller.accessToken()),
    saleForReturn: (code) async => api.saleForReturn(accessToken: await controller.accessToken(), code: code),
    returnDocument: (code) async => api.returnDocument(accessToken: await controller.accessToken(), code: code),
    returnCredit: (code) async => api.returnCredit(accessToken: await controller.accessToken(), code: code),
    findQuote: (key) async => api.quote(accessToken: await controller.accessToken(), key: key),
    logger: logger,
  );
  runApp(FarmaErpPdvApp(
    controller: controller,
    pos: pos,
    database: database,
    display: DisplaySettings(database),
    appVersion: _appVersion,
  ));
  unawaited(controller.start());
}

LocalLogger _createLogger(Directory dataDirectory) => LocalLogger(
  directory: Directory(
    '${dataDirectory.path}${Platform.pathSeparator}logs',
  ),
  version: _appVersion,
);

class FarmaErpPdvApp extends StatelessWidget {
  const FarmaErpPdvApp({super.key, required this.controller, this.pos, this.database, this.display, this.appVersion});

  final TerminalController controller;

  /// Fonte do terminal (tamanho e tipo): vale em todas as telas, na hora.
  final DisplaySettings? display;
  final String? appVersion;

  /// Sem o caixa (testes da tela do terminal), fica só a tela do terminal.
  final PosController? pos;
  final LocalDatabase? database;

  @override
  Widget build(BuildContext context) {
    final settings = display;
    Widget app(BuildContext context) => MaterialApp(
      title: 'FarmaERP PDV',
      debugShowCheckedModeBanner: false,
      theme: settings?.theme(),
      builder: (context, child) {
        final banner = EnvironmentBanner(environment: appEnvironment, child: child ?? const SizedBox.shrink());
        return settings == null ? banner : settings.apply(context, banner);
      },
      home: pos == null || database == null
          ? TerminalScreen(controller: controller)
          : PdvHome(terminal: controller, pos: pos!, database: database!, display: settings, appVersion: appVersion),
    );
    return settings == null ? app(context) : ListenableBuilder(listenable: settings, builder: (context, _) => app(context));
  }
}

/// Aparece quando o PDV não pode funcionar: endereço inseguro da API (FA010) ou banco local
/// que não abre (FA957).
class InvalidConfigurationApp extends StatelessWidget {
  const InvalidConfigurationApp({super.key, this.code = 'FA010'});

  final String code;

  @override
  Widget build(BuildContext context) {
    final error = ErrorDisplay.fromCode(code);
    return MaterialApp(
      title: 'FarmaERP PDV',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error.message, textAlign: TextAlign.center),
                Text(error.action, textAlign: TextAlign.center),
                Text(error.reference, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
