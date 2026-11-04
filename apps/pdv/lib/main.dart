import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/local_logger.dart';
import 'core/secret_store.dart';
import 'core/trace_id.dart';
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

  logger.info('PDV iniciado', fields: {'app_version': _appVersion});

  final controller = TerminalController(
    api: HttpTerminalApi(baseUrl: _apiUrl, logger: logger),
    store: await createSecretStore(dataDirectory: dataDirectory, logger: logger),
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
      home: TerminalScreen(controller: controller),
    );
  }
}
