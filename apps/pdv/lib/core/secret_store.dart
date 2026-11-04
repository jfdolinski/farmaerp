import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_logger.dart';

/// Guarda segredos do aparelho, como a chave privada do terminal.
abstract class SecretStore {
  /// Como o segredo é protegido: `system` (guarda do sistema) ou `file`.
  String get kind;

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SystemSecretStore implements SecretStore {
  SystemSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  String get kind => 'system';

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Alternativa para Linux sem chaveiro do sistema: arquivo legível só pelo usuário.
/// A proteção é menor, e por isso o aparelho avisa a retaguarda no pareamento.
class FileSecretStore implements SecretStore {
  FileSecretStore(this.file);

  final File file;

  @override
  String get kind => 'file';

  Map<String, dynamic> _load() {
    if (!file.existsSync()) return {};
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  Future<void> _save(Map<String, dynamic> values) async {
    file.parent.createSync(recursive: true);
    // A permissão é ajustada antes de o conteúdo ser gravado.
    final temporary = File('${file.path}.tmp')..writeAsStringSync('');
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['600', temporary.path]);
      if (result.exitCode != 0) {
        temporary.deleteSync();
        throw FileSystemException('Falha ao proteger o arquivo', temporary.path);
      }
    }
    temporary.writeAsStringSync(jsonEncode(values), flush: true);
    temporary.renameSync(file.path);
  }

  @override
  Future<String?> read(String key) async => _load()[key] as String?;

  @override
  Future<void> write(String key, String value) =>
      _save({..._load(), key: value});

  @override
  Future<void> delete(String key) => _save(_load()..remove(key));
}

const _probeKey = 'farmaerp_probe';

/// Usa a guarda do sistema. Só no Linux sem chaveiro recorre ao arquivo.
Future<SecretStore> createSecretStore({
  required Directory dataDirectory,
  SecretStore? systemStore,
  bool? isLinux,
  LocalLogger? logger,
}) async {
  final system = systemStore ?? SystemSecretStore();
  if (!(isLinux ?? Platform.isLinux)) {
    return system;
  }
  try {
    await system.write(_probeKey, 'ok');
    final works = await system.read(_probeKey) == 'ok';
    await system.delete(_probeKey);
    if (works) return system;
  } catch (error) {
    logger?.warn(
      'Chaveiro do sistema indisponível',
      fields: {'err': error.toString()},
    );
  }
  logger?.warn('Chave do terminal guardada em arquivo, com proteção menor');
  return FileSecretStore(
    File('${dataDirectory.path}${Platform.pathSeparator}terminal.secret'),
  );
}
