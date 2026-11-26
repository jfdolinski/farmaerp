import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart' hide Text, TextField, InputDecoration;
import 'package:path_provider/path_provider.dart';

import 'core/app_environment.dart';
import 'core/error_display.dart';
import 'core/local_logger.dart';
import 'core/secret_store.dart';
import 'core/trace_id.dart';
import 'customers/customer_service.dart';
import 'face/face_camera.dart';
import 'face/face_engine.dart';
import 'face/face_service.dart';
import 'fiscal/nfce_credentials.dart';
import 'fiscal/nfce_emitter.dart';
import 'fiscal/sefaz.dart';
import 'local/local_database.dart';
import 'pos/display_settings.dart';
import 'pos/pdv_home.dart';
import 'pos/pos_auth.dart';
import 'pos/pos_controller.dart';
import 'sync/sync_service.dart';
import 'terminal/terminal_api.dart';
import 'terminal/terminal_controller.dart';
import 'terminal/terminal_screen.dart';
import 'ui/caps.dart';
import 'update/update_api.dart';
import 'update/update_service.dart';
import 'update/update_signature.dart';

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
  final databaseFile = File('${dataDirectory.path}${Platform.pathSeparator}farmaerp.db');
  // Atualização automática: só no PDV instalado (build de release). O token vem do terminal,
  // criado mais abaixo.
  TerminalController? terminal;
  final updates = UpdateService(
    api: HttpUpdateApi(baseUrl: _apiUrl),
    accessToken: () => terminal == null ? Future.error(StateError('Terminal ainda não iniciado')) : terminal.accessToken(),
    directory: Directory('${dataDirectory.path}${Platform.pathSeparator}updates'),
    databaseFile: databaseFile,
    currentVersion: _appVersion,
    platform: kReleaseMode ? Platform.operatingSystem : 'desenvolvimento',
    publicKeys: configuredUpdateKeys(),
    installerCache: File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}installer${Platform.pathSeparator}FarmaERP-PDV-Setup.exe',
    ),
    launch: (installer, arguments) async {
      await Process.start(installer, arguments, mode: ProcessStartMode.detached);
    },
    logger: logger,
  );
  await updates.load();

  final LocalDatabase database;
  try {
    database = await LocalDatabase.open(file: databaseFile, store: store, logger: logger);
  } catch (error, stack) {
    // Versão nova recém-instalada que não abriu o banco: volta para a anterior.
    if (updates.verifyingNewVersion) {
      if (await updates.rollback(error)) exit(0);
      runApp(const InvalidConfigurationApp(code: 'FA879'));
      return;
    }
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

  await updates.confirmApplied();
  // Próxima abertura: a versão já baixada é aplicada antes de começar a vender.
  if (updates.hasReady) {
    database.close();
    await updates.apply();
    exit(0);
  }

  // Avisos e erros sobem para a central pela outbox.
  logger.onEntry = (entry) => database.enqueueLog(entry, now: DateTime.now());

  // NFC-e: o certificado e o CSC chegam cifrados para a chave deste caixa.
  final nfceCredentials = NfceCredentialService(api: api, database: database, store: store, logger: logger);

  final controller = terminal = TerminalController(
    api: api,
    store: store,
    sync: SyncService(api: api, database: database, logger: logger),
    afterSync: (accessToken, terminalId, sign) async {
      await nfceCredentials.refresh(accessToken: accessToken, terminalId: terminalId, sign: sign);
      // Ao abrir, a primeira verificação de versão roda aqui, com o terminal já pronto.
      unawaited(updates.tickIfDue());
    },
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
    nfce: NfceEmitter(
      database: database,
      credentials: nfceCredentials,
      sefaz: SefazClient(),
      terminalId: () => controller.terminalId,
      appVersion: _appVersion,
      logger: logger,
    ),
    database: database,
    auth: PosAuth(database: database, logger: logger),
    printer: () => configuredPrinter(database, pdfDirectory),
    terminalNumber: () => controller.terminalNumber,
    // A venda sobe logo, sem esperar o próximo sinal de vida.
    onSaleSaved: () => unawaited(controller.tick()),
    // Fechamento de caixa: momento seguro para aplicar a atualização já baixada.
    onShiftClosed: () async {
      if (!updates.hasReady) return;
      database.close();
      await updates.apply();
      exit(0);
    },
    customers: CustomerService(api: api, database: database, accessToken: controller.accessToken, logger: logger),
    networkStock: (productId) async => api.networkStock(accessToken: await controller.accessToken(), productId: productId),
    openQuotes: () async => api.openQuotes(accessToken: await controller.accessToken()),
    saleForReturn: (code) async => api.saleForReturn(accessToken: await controller.accessToken(), code: code),
    returnDocument: (code) async => api.returnDocument(accessToken: await controller.accessToken(), code: code),
    returnCredit: (code) async => api.returnCredit(accessToken: await controller.accessToken(), code: code),
    cashbackBalance: (customerId) async => api.cashback(accessToken: await controller.accessToken(), customerId: customerId),
    cashbackReserve: (customerId, amount, saleTotal) async => api.cashbackReserve(
      accessToken: await controller.accessToken(),
      customerId: customerId,
      amount: amount,
      saleTotal: saleTotal,
    ),
    cashbackRelease: (reservationId) async => api.cashbackRelease(accessToken: await controller.accessToken(), reservationId: reservationId),
    findQuote: (key) async => api.quote(accessToken: await controller.accessToken(), key: key),
    logger: logger,
  );
  // Rosto: por enquanto só no Windows (no Linux, PIN e liberação do gerente).
  final face = Platform.isWindows ? FaceService(camera: LiteFaceCamera.new, engine: OnnxFaceEngine.open) : null;
  pos.face = face;
  runApp(FarmaErpPdvApp(
    controller: controller,
    pos: pos,
    database: database,
    display: DisplaySettings(database),
    appVersion: _appVersion,
    face: face,
  ));
  unawaited(controller.start());
  updates.start();
}

LocalLogger _createLogger(Directory dataDirectory) => LocalLogger(
  directory: Directory(
    '${dataDirectory.path}${Platform.pathSeparator}logs',
  ),
  version: _appVersion,
);

class FarmaErpPdvApp extends StatelessWidget {
  const FarmaErpPdvApp({super.key, required this.controller, this.pos, this.database, this.display, this.appVersion, this.face});

  final TerminalController controller;

  /// Fonte do terminal (tamanho e tipo): vale em todas as telas, na hora.
  final DisplaySettings? display;
  final String? appVersion;

  /// Sem o caixa (testes da tela do terminal), fica só a tela do terminal.
  final PosController? pos;
  final LocalDatabase? database;

  /// Rosto no PDV (câmera e modelos), quando o sistema tem.
  final FaceService? face;

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
          : PdvHome(terminal: controller, pos: pos!, database: database!, display: settings, appVersion: appVersion, face: face),
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
