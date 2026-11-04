import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'core/local_logger.dart';
import 'core/trace_id.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final logger = await _createLogger();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logger?.error(
      'Erro na interface',
      traceId: newTraceId(),
      errorCode: 'FA000',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logger?.error(
      'Erro inesperado',
      traceId: newTraceId(),
      errorCode: 'FA000',
      error: error,
      stackTrace: stack,
    );
    return true;
  };

  logger?.info('PDV iniciado');
  runApp(const FarmaErpPdvApp());
}

// Sem pasta de logs, o PDV abre mesmo assim.
Future<LocalLogger?> _createLogger() async {
  try {
    final support = await getApplicationSupportDirectory();
    return LocalLogger(
      directory: Directory(
        '${support.path}${Platform.pathSeparator}logs',
      ),
    );
  } catch (_) {
    return null;
  }
}

class FarmaErpPdvApp extends StatelessWidget {
  const FarmaErpPdvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'FarmaERP PDV',
      home: Scaffold(body: Center(child: Text('FarmaERP PDV'))),
    );
  }
}
