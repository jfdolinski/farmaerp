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
import 'local/local_database.dart';
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
  runApp(FarmaErpPdvApp(controller: controller));
  unawaited(controller.start());
}

LocalLogger _createLogger(Directory dataDirectory) => LocalLogger(
  directory: Directory(
    '${dataDirectory.path}${Platform.pathSeparator}logs',
  ),
  version: _appVersion,
);

class FarmaErpPdvApp extends StatelessWidget {
  const FarmaErpPdvApp({super.key, required this.controller});

  final TerminalController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FarmaERP PDV',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => EnvironmentBanner(
        environment: appEnvironment,
        child: child ?? const SizedBox.shrink(),
      ),
      home: TerminalScreen(controller: controller),
    );
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
