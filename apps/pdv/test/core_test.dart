import 'dart:convert';
import 'dart:io';

import 'package:farmaerp_pdv/core/error_catalog.g.dart';
import 'package:farmaerp_pdv/core/error_display.dart';
import 'package:farmaerp_pdv/core/human_code.dart';
import 'package:farmaerp_pdv/core/local_logger.dart';
import 'package:farmaerp_pdv/core/trace_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatSaleCode', () {
    test('combina o número do terminal com o contador', () {
      expect(formatSaleCode(terminalNumber: 2, counter: 123), '2-000123');
      expect(formatSaleCode(terminalNumber: 999, counter: 1), '999-000001');
    });

    test('não corta um contador maior que seis dígitos', () {
      expect(formatSaleCode(terminalNumber: 1, counter: 1234567), '1-1234567');
    });

    test('rejeita valores abaixo de 1', () {
      expect(
        () => formatSaleCode(terminalNumber: 0, counter: 1),
        throwsArgumentError,
      );
      expect(
        () => formatSaleCode(terminalNumber: 1, counter: 0),
        throwsArgumentError,
      );
    });
  });

  group('newTraceId', () {
    test('gera UUID v7 ordenado por tempo', () async {
      final first = newTraceId();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = newTraceId();

      final v7 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(first, matches(v7));
      expect(second, matches(v7));
      expect(first.compareTo(second), lessThan(0));
    });
  });

  group('ErrorDisplay', () {
    test('monta a mensagem, a ação e a referência', () {
      final display = ErrorDisplay.fromCode(
        'FA203',
        traceId: '019a0000-0000-7000-8000-0000a1b2c3d4',
      );

      expect(display.message, errorCatalog['FA203']!.message);
      expect(display.action, errorCatalog['FA203']!.action);
      expect(display.reference, 'Código FA203 · Ref. a1b2c3d4');
      expect(display.retryable, isFalse);
    });

    test('código desconhecido vira o erro genérico', () {
      final display = ErrorDisplay.fromCode('FA999');
      expect(display.message, errorCatalog['FA000']!.message);
      expect(display.reference, 'Código FA000');
    });

    test('catálogo contém os códigos usados pelo PDV', () {
      expect(errorCatalog.keys, containsAll(['FA000', 'FA001']));
    });
  });

  group('sanitizeLogValue', () {
    for (final key in [
      'cpf',
      'CPF',
      'senha',
      'pin',
      'token',
      'accessToken',
      'authorization',
      'certificado',
      'face_code',
      'biometria',
    ]) {
      test('mascara o campo $key em qualquer nível', () {
        final result = jsonEncode(
          sanitizeLogValue({
            'a': {
              'b': [
                {key: 'segredo'},
              ],
            },
          }),
        );
        expect(result, isNot(contains('segredo')));
        expect(result, contains('[protegido]'));
      });
    }

    test('mascara CPF dentro de textos, mas não CNPJ', () {
      expect(
        sanitizeLogValue('cliente 123.456.789-09 e 12345678909'),
        'cliente [protegido] e [protegido]',
      );
      expect(sanitizeLogValue('filial 11222333000181'), 'filial 11222333000181');
    });
  });

  group('LocalLogger', () {
    late Directory directory;
    late DateTime now;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('farmaerp_log_');
      now = DateTime(2026, 11, 4, 12);
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    LocalLogger logger({
      int maxFileBytes = 1024 * 1024,
      int maxTotalBytes = 10 * 1024 * 1024,
    }) => LocalLogger(
      directory: directory,
      maxFileBytes: maxFileBytes,
      maxTotalBytes: maxTotalBytes,
      clock: () => now,
    );

    List<String> files() {
      final names = directory
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toList();
      return names..sort();
    }

    test('grava JSON por linha com o rastreio e sem dados sensíveis', () {
      logger().info(
        'venda iniciada',
        traceId: 'abc',
        fields: {'cpf': '12345678909', 'itens': 2},
      );

      final line = File(
        '${directory.path}/${files().single}',
      ).readAsLinesSync().single;
      final json = jsonDecode(line) as Map<String, dynamic>;

      expect(json['level'], 'info');
      expect(json['msg'], 'venda iniciada');
      expect(json['trace_id'], 'abc');
      expect(json['service'], 'pdv');
      expect(json['itens'], 2);
      expect(line, isNot(contains('12345678909')));
    });

    test('um campo do chamador não sobrescreve os campos padrão', () {
      logger().info('mensagem', traceId: 'real', fields: {'trace_id': 'falso'});
      final line = File(
        '${directory.path}/${files().single}',
      ).readAsLinesSync().single;
      expect(
        (jsonDecode(line) as Map<String, dynamic>)['trace_id'],
        'real',
      );
    });

    test('registra o código e o erro técnico', () {
      logger().error(
        'falhou',
        errorCode: 'FA000',
        error: StateError('detalhe técnico'),
      );
      final line = File(
        '${directory.path}/${files().single}',
      ).readAsLinesSync().single;
      final json = jsonDecode(line) as Map<String, dynamic>;
      expect(json['error_code'], 'FA000');
      expect(json['err'], contains('detalhe técnico'));
    });

    test('roda o arquivo ao passar do tamanho máximo', () {
      final log = logger(maxFileBytes: 300);
      for (var i = 0; i < 10; i += 1) {
        log.info('mensagem $i');
      }
      expect(files().length, greaterThan(1));
      expect(files().first, 'pdv-20261104-0000.jsonl');
    });

    test('abre um arquivo novo na virada do dia', () {
      final log = logger();
      log.info('hoje');
      now = DateTime(2026, 11, 5, 0, 1);
      log.info('amanhã');
      expect(files(), [
        'pdv-20261104-0000.jsonl',
        'pdv-20261105-0000.jsonl',
      ]);
    });

    test('continua do último arquivo ao reabrir no mesmo dia', () {
      final first = logger(maxFileBytes: 300);
      for (var i = 0; i < 10; i += 1) {
        first.info('mensagem $i');
      }
      final count = files().length;

      logger(maxFileBytes: 1024 * 1024).info('depois de reabrir');
      expect(files().length, count);
    });

    test('apaga arquivos com mais de 14 dias', () {
      final old = File('${directory.path}/pdv-20261001-0000.jsonl')
        ..writeAsStringSync('velho\n')
        ..setLastModifiedSync(now.subtract(const Duration(days: 15)));
      final recent = File('${directory.path}/pdv-20261025-0000.jsonl')
        ..writeAsStringSync('recente\n')
        ..setLastModifiedSync(now.subtract(const Duration(days: 13)));

      logger().info('nova');

      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
    });

    test('passando do limite total, apaga primeiro os mais antigos', () {
      final oldest = File('${directory.path}/pdv-20261101-0000.jsonl')
        ..writeAsStringSync('a' * 600)
        ..setLastModifiedSync(now);
      final middle = File('${directory.path}/pdv-20261102-0000.jsonl')
        ..writeAsStringSync('b' * 600)
        ..setLastModifiedSync(now);

      logger(maxTotalBytes: 800).info('nova');

      expect(oldest.existsSync(), isFalse);
      expect(middle.existsSync(), isTrue);
    });

    test('não apaga arquivos que não são de log', () {
      final other = File('${directory.path}/config.json')
        ..writeAsStringSync('{}')
        ..setLastModifiedSync(now.subtract(const Duration(days: 100)));
      logger().info('nova');
      expect(other.existsSync(), isTrue);
    });

    test('não lança erro quando não consegue gravar', () {
      final blocked = File('${directory.path}/bloqueio')..writeAsStringSync('x');
      final log = LocalLogger(directory: Directory('${blocked.path}/logs'));
      expect(() => log.info('mensagem'), returnsNormally);
      expect(log.prune, returnsNormally);
    });
  });
}
