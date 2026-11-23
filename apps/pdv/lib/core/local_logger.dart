import 'dart:convert';
import 'dart:io';

/// Níveis de log, na mesma nomenclatura da API.
enum LogLevel { debug, info, warn, error }

const _mask = '[protegido]';
const _maxDepth = 8;

// Dados que nunca podem ir para o log (LGPD e segurança).
final _sensitiveKey = RegExp(
  r'^(cpf|cnh|rg|senha|password|passwd|pass|pin|token|access_?token|refresh_?token|secret|authorization|cookie|set-cookie|api_?key|private_?key|cert|certificate|certificado|csc|biometric|biometria|face|face_?code|fingerprint|digital|card|cartao|cvv|body)$',
  caseSensitive: false,
);
final _cpfInText = RegExp(r'\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b');

/// Copia um valor mascarando campos sensíveis e CPFs dentro de textos.
Object? sanitizeLogValue(Object? value, [int depth = 0]) {
  if (value is String) {
    return value.replaceAll(_cpfInText, _mask);
  }
  if (value == null || value is num || value is bool) {
    return value;
  }
  if (depth >= _maxDepth) {
    return _mask;
  }
  if (value is Map) {
    return value.map((key, item) {
      final name = key.toString();
      return MapEntry(
        name,
        _sensitiveKey.hasMatch(name)
            ? _mask
            : sanitizeLogValue(item, depth + 1),
      );
    });
  }
  if (value is Iterable) {
    return value.map((item) => sanitizeLogValue(item, depth + 1)).toList();
  }
  return sanitizeLogValue(value.toString(), depth + 1);
}

/// Grava logs em arquivos JSON por linha, com rotação por tamanho e retenção.
///
/// Um problema no log nunca pode atrapalhar uma venda: nenhum método lança erro.
class LocalLogger {
  LocalLogger({
    required this.directory,
    this.retention = const Duration(days: 14),
    this.maxTotalBytes = 50 * 1024 * 1024,
    this.maxFileBytes = 5 * 1024 * 1024,
    this.service = 'pdv',
    this.version = 'dev',
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Directory directory;
  final Duration retention;
  final int maxTotalBytes;
  final int maxFileBytes;
  final String service;
  final String version;
  final DateTime Function() _clock;

  static final _fileName = RegExp(r'^pdv-\d{8}-\d{4}\.jsonl$');

  /// Recebe cada registro já sem dados sensíveis (o PDV põe avisos e erros na outbox).
  /// Uma falha aqui é ignorada: o log nunca atrapalha o caixa.
  void Function(Map<String, Object?> entry)? onEntry;

  File? _current;
  String? _currentDay;
  int _sequence = 0;
  bool _pruned = false;

  void debug(String message, {String? traceId, Map<String, Object?>? fields}) =>
      log(LogLevel.debug, message, traceId: traceId, fields: fields);

  void info(String message, {String? traceId, Map<String, Object?>? fields}) =>
      log(LogLevel.info, message, traceId: traceId, fields: fields);

  void warn(String message, {String? traceId, Map<String, Object?>? fields}) =>
      log(LogLevel.warn, message, traceId: traceId, fields: fields);

  void error(
    String message, {
    String? traceId,
    String? errorCode,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? fields,
  }) => log(
    LogLevel.error,
    message,
    traceId: traceId,
    fields: {
      ...?fields,
      'error_code': ?errorCode,
      'err': ?error?.toString(),
      'stack': ?stackTrace?.toString(),
    },
  );

  void log(
    LogLevel level,
    String message, {
    String? traceId,
    Map<String, Object?>? fields,
  }) {
    try {
      final now = _clock();
      final entry = sanitizeLogValue({
          ...?fields,
          'level': level.name,
          'time': now.toUtc().toIso8601String(),
          'service': service,
          'version': version,
          'trace_id': ?traceId,
          'msg': message,
        }) as Map<String, Object?>;
      final line = jsonEncode(entry);
      try {
        onEntry?.call(entry);
      } catch (_) {
        // A fila de envio falhou: o registro continua no arquivo local.
      }
      _fileFor(now, line.length + 1).writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Sem disco ou sem permissão: segue sem log.
    }
  }

  /// Apaga arquivos vencidos e, se passar do limite, os mais antigos primeiro.
  void prune() {
    try {
      final files = _logFiles()..sort((a, b) => _name(a).compareTo(_name(b)));
      final cutoff = _clock().subtract(retention);
      final kept = <File>[];
      for (final file in files) {
        if (file.lastModifiedSync().isBefore(cutoff)) {
          file.deleteSync();
        } else {
          kept.add(file);
        }
      }

      var total = kept.fold<int>(0, (sum, file) => sum + file.lengthSync());
      for (final file in kept) {
        if (total <= maxTotalBytes) break;
        final size = file.lengthSync();
        // O arquivo em uso continua, mesmo que seja o único.
        if (file.path == _current?.path) continue;
        file.deleteSync();
        total -= size;
      }
    } catch (_) {
      // A limpeza é tentada de novo na próxima rotação.
    }
  }

  File _fileFor(DateTime now, int nextBytes) {
    final day = _day(now);
    final current = _current;
    final needsRotation =
        current == null ||
        day != _currentDay ||
        (current.existsSync() &&
            current.lengthSync() + nextBytes > maxFileBytes);

    if (needsRotation) {
      directory.createSync(recursive: true);
      if (day != _currentDay) {
        _currentDay = day;
        _sequence = _lastSequence(day);
      } else {
        _sequence += 1;
      }
      _current = _pathFor(day, _sequence);
      if (_current!.existsSync() &&
          _current!.lengthSync() + nextBytes > maxFileBytes) {
        _sequence += 1;
        _current = _pathFor(day, _sequence);
      }
      prune();
      _pruned = true;
    } else if (!_pruned) {
      prune();
      _pruned = true;
    }
    return _current!;
  }

  File _pathFor(String day, int sequence) {
    final number = sequence.toString().padLeft(4, '0');
    return File('${directory.path}${Platform.pathSeparator}pdv-$day-$number.jsonl');
  }

  // Ao reabrir no mesmo dia, continua do último arquivo.
  int _lastSequence(String day) {
    var last = 0;
    for (final file in _logFiles()) {
      final name = _name(file);
      if (name.startsWith('pdv-$day-')) {
        final sequence = int.parse(name.substring(13, 17));
        if (sequence > last) last = sequence;
      }
    }
    return last;
  }

  List<File> _logFiles() => directory
      .listSync()
      .whereType<File>()
      .where((file) => _fileName.hasMatch(_name(file)))
      .toList();

  String _name(File file) => file.uri.pathSegments.last;

  String _day(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}'
      '${time.month.toString().padLeft(2, '0')}'
      '${time.day.toString().padLeft(2, '0')}';
}
