import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../core/local_logger.dart';
import 'update_api.dart';
import 'update_signature.dart';

/// Abre o instalador (no Windows, sem perguntas e com a barra de progresso).
typedef InstallerLauncher = Future<void> Function(String installer, List<String> arguments);

/// Argumentos do Inno Setup: sem perguntas, sem reiniciar o Windows; o próprio instalador abre o PDV no fim.
const silentInstallArguments = ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'];

/// Atualização automática do PDV.
///
/// - Verifica e baixa em segundo plano ([tick], a cada [interval]), retomando o download se cair.
/// - Só aceita o arquivo com o tamanho, o SHA-256 e a assinatura certos.
/// - Aplica só em momento seguro ([apply]): depois do fechamento de caixa ou na abertura do PDV.
///   Antes, copia o banco local e guarda o instalador da versão atual.
/// - Na abertura da versão nova, se o banco local não abrir (migração), devolve a cópia, reinstala
///   a versão anterior ([rollback]) e não tenta mais essa versão.
///
/// O estado fica num arquivo próprio (não no banco), porque precisa existir mesmo quando o banco falha.
class UpdateService {
  UpdateService({
    required this.api,
    required this.accessToken,
    required this.directory,
    required this.databaseFile,
    required this.currentVersion,
    required this.platform,
    required this.publicKeys,
    required this.installerCache,
    required this.launch,
    this.logger,
    this.interval = const Duration(minutes: 30),
  });

  final UpdateApi api;
  final Future<String> Function() accessToken;
  final Directory directory;
  final File databaseFile;
  final String currentVersion;
  final String platform;
  final List<String> publicKeys;

  /// Instalador da versão instalada, que o próprio instalador guarda na pasta do PDV.
  final File installerCache;
  final InstallerLauncher launch;
  final LocalLogger? logger;
  final Duration interval;

  Map<String, dynamic> _state = {};
  Timer? _timer;
  bool _running = false;

  File get _stateFile => File(_join(directory.path, 'state.json'));

  /// Só o Windows tem instalador por enquanto (o pacote do Linux vem depois).
  bool get supported => platform == 'windows';

  /// Versão baixada e conferida, esperando o momento seguro.
  String? get readyVersion => (_state['ready'] as Map?)?['version'] as String?;
  bool get hasReady => supported && _state['ready'] != null;

  /// A versão nova acabou de ser instalada e o banco ainda vai ser aberto por ela.
  bool get verifyingNewVersion => (_state['applying'] as Map?)?['version'] == currentVersion;

  Future<void> load() async {
    try {
      if (_stateFile.existsSync()) _state = jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
    } catch (error) {
      logger?.warn('Estado da atualização ilegível; começando de novo', fields: {'err': error.toString()});
      _state = {};
    }
    // A versão instalada não é a que estava sendo aplicada: o instalador falhou.
    final applying = _state['applying'] as Map?;
    if (applying != null && applying['version'] != currentVersion) {
      logger?.error('A atualização não foi instalada', errorCode: 'FA879', fields: {'version': applying['version']});
      _refuse(applying['id'] as String);
      _queueReport(applying['id'] as String, 'failed', 'O instalador não concluiu; o PDV continua na versão ${applying['from']}.');
      _state.remove('applying');
      await _save();
    }
  }

  Future<void> _save() async {
    directory.createSync(recursive: true);
    final temporary = File('${_stateFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(_state), flush: true);
    await temporary.rename(_stateFile.path);
  }

  void _refuse(String releaseId) {
    final refused = ((_state['refused'] as List?) ?? const []).cast<String>().toSet()..add(releaseId);
    _state['refused'] = refused.toList();
  }

  void _queueReport(String releaseId, String status, [String? detail]) {
    final reports = ((_state['reports'] as List?) ?? const []).cast<Map<String, dynamic>>().toList()
      ..add({'id': releaseId, 'status': status, 'detail': detail});
    _state['reports'] = reports;
  }

  /// O banco abriu na versão nova: a atualização deu certo.
  Future<void> confirmApplied() async {
    final applying = _state['applying'] as Map?;
    if (applying == null || applying['version'] != currentVersion) return;
    _queueReport(applying['id'] as String, 'applied');
    _state.remove('applying');
    await _save();
    logger?.info('Atualização aplicada', fields: {'version': currentVersion, 'from': applying['from']});
    _deleteQuietly(Directory(_join(directory.path, 'backup')));
    _deleteQuietly(Directory(_join(directory.path, 'rollback')));
    _deleteQuietly(Directory(_join(directory.path, 'downloads')));
  }

  /// O banco não abriu na versão nova: devolve a cópia e reinstala a anterior.
  /// Falso quando não há como voltar (sem o instalador anterior): o PDV mostra FA879.
  Future<bool> rollback(Object error) async {
    final applying = _state['applying'] as Map?;
    if (applying == null || applying['version'] != currentVersion) return false;
    logger?.error('Versão nova não abriu o banco local; voltando à anterior', errorCode: 'FA879', error: error,
        fields: {'version': currentVersion, 'from': applying['from']});
    final backup = Directory(applying['backup'] as String);
    final name = _baseName(databaseFile.path);
    for (final suffix in ['', '-wal', '-shm']) {
      final current = File('${databaseFile.path}$suffix');
      if (current.existsSync()) current.deleteSync();
      final copy = File(_join(backup.path, '$name$suffix'));
      if (copy.existsSync()) copy.copySync(current.path);
    }
    _refuse(applying['id'] as String);
    _queueReport(applying['id'] as String, 'rolled_back', 'O banco local não abriu na versão $currentVersion; voltou para a ${applying['from']}.');
    final installer = applying['rollback'] as String?;
    _state.remove('applying');
    await _save();
    if (installer == null || !File(installer).existsSync()) return false;
    await launch(installer, silentInstallArguments);
    return true;
  }

  /// Aplica a versão baixada. O chamador fecha o banco antes e encerra o PDV depois.
  Future<void> apply() async {
    final ready = (_state['ready'] as Map?)?.cast<String, dynamic>();
    if (ready == null || !supported) return;
    final installer = File(ready['path'] as String);
    if (!installer.existsSync()) {
      _state.remove('ready');
      await _save();
      return;
    }
    final backup = Directory(_join(directory.path, 'backup', currentVersion));
    _deleteQuietly(backup);
    backup.createSync(recursive: true);
    final name = _baseName(databaseFile.path);
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${databaseFile.path}$suffix');
      if (file.existsSync()) file.copySync(_join(backup.path, '$name$suffix'));
    }
    String? rollbackInstaller;
    if (installerCache.existsSync()) {
      final target = File(_join(directory.path, 'rollback', 'FarmaERP-PDV-Setup-$currentVersion.exe'));
      target.parent.createSync(recursive: true);
      installerCache.copySync(target.path);
      rollbackInstaller = target.path;
    }
    _state['applying'] = {
      'id': ready['id'],
      'version': ready['version'],
      'from': currentVersion,
      'backup': backup.path,
      'rollback': rollbackInstaller,
    };
    _state.remove('ready');
    await _save();
    logger?.info('Aplicando a atualização', fields: {'version': ready['version'], 'from': currentVersion});
    await launch(installer.path, silentInstallArguments);
  }

  void start() {
    if (!supported) return;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
    unawaited(tick());
  }

  void stop() => _timer?.cancel();

  /// Envia o que ficou pendente, pergunta pela versão nova e baixa.
  Future<void> tick() async {
    if (!supported || _running) return;
    _running = true;
    try {
      final token = await accessToken();
      await _flushReports(token);
      if (_state['ready'] != null || _state['applying'] != null) return;
      final release = await api.check(accessToken: token, platform: platform, current: currentVersion);
      if (release == null) return;
      final refused = ((_state['refused'] as List?) ?? const []).cast<String>();
      if (refused.contains(release.id)) return;
      await _download(token, release);
      await _flushReports(token);
    } catch (error) {
      // Sem internet ou sem terminal pareado: tenta de novo no próximo ciclo.
      logger?.warn('Verificação de atualização não concluída', fields: {'err': error.toString()});
    } finally {
      _running = false;
    }
  }

  Future<void> _flushReports(String token) async {
    final reports = ((_state['reports'] as List?) ?? const []).cast<Map<String, dynamic>>().toList();
    if (reports.isEmpty) return;
    while (reports.isNotEmpty) {
      final report = reports.first;
      await api.report(
        accessToken: token,
        releaseId: report['id'] as String,
        status: report['status'] as String,
        detail: report['detail'] as String?,
      );
      reports.removeAt(0);
      _state['reports'] = reports;
      await _save();
    }
  }

  Future<void> _download(String token, AvailableRelease release) async {
    final folder = Directory(_join(directory.path, 'downloads'))..createSync(recursive: true);
    final part = File(_join(folder.path, '${release.id}.part'));
    if (part.existsSync() && part.lengthSync() > release.size) part.deleteSync();
    if (!part.existsSync() || part.lengthSync() < release.size) {
      await api.download(accessToken: token, releaseId: release.id, target: part);
    }
    // A conexão terminou antes do fim: a parte fica guardada e o próximo ciclo continua dela.
    if (part.lengthSync() < release.size) return;
    final problem = await _verify(part, release);
    if (problem != null) {
      part.deleteSync();
      _refuse(release.id);
      _queueReport(release.id, 'failed', problem);
      await _save();
      logger?.error('Arquivo da atualização não confere', errorCode: 'FA869', fields: {'version': release.version, 'problem': problem});
      return;
    }
    final installer = File(_join(folder.path, release.fileName));
    if (installer.existsSync()) installer.deleteSync();
    part.renameSync(installer.path);
    _state['ready'] = {...release.toJson(), 'path': installer.path};
    _queueReport(release.id, 'downloaded');
    await _save();
    logger?.info('Atualização baixada', fields: {'version': release.version});
  }

  /// Tamanho, resumo e assinatura. Devolve o problema, ou null quando está tudo certo.
  Future<String?> _verify(File file, AvailableRelease release) async {
    if (release.app != 'pdv' || release.platform != platform) return 'Versão de outro aplicativo ou sistema.';
    if (file.lengthSync() != release.size) return 'Tamanho diferente do publicado.';
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final digest = (await sink.hash()).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (digest != release.sha256) return 'Resumo (SHA-256) diferente do publicado.';
    final manifest = ReleaseManifest(
      app: release.app,
      platform: release.platform,
      version: release.version,
      sha256: release.sha256,
      size: release.size,
    );
    if (!await verifyReleaseSignature(manifest, release.signature, publicKeys)) return 'Assinatura não confere.';
    return null;
  }

  static void _deleteQuietly(Directory folder) {
    try {
      if (folder.existsSync()) folder.deleteSync(recursive: true);
    } catch (_) {
      // Sobra de arquivo não atrapalha: é apagada na próxima vez.
    }
  }

  static String _join(String first, [String? a, String? b]) =>
      [first, ?a, ?b].join(Platform.pathSeparator);

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;
}
