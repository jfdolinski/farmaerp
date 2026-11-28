import 'dart:io';
import 'dart:typed_data';

import 'package:farmaerp_pdv/pos/danfe_printer.dart';
import 'package:flutter_test/flutter_test.dart';

// DANFE A4 pela impressora padrão do Windows: guarda a cópia; imprime pelo programa de PDF; se não
// der, abre o PDF; se nem isso, fica só guardado.
void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('danfe-');
    addTearDown(() => directory.delete(recursive: true));
  });
  final pdf = Uint8List.fromList('%PDF-1.4 teste'.codeUnits);

  test('imprime pelo verbo "print" e guarda a cópia com a chave no nome', () async {
    final calls = <String>[];
    final printer = WindowsDanfePrinter(Directory('${directory.path}/danfe'), shell: (verb, path) {
      calls.add(verb);
      return true;
    });
    final result = await printer.print('35261111222333000181550010000000011000000019', pdf);
    expect(result.result, DanfeResult.printed);
    expect(calls, ['print']);
    expect(result.file.path, endsWith('DANFE-35261111222333000181550010000000011000000019.pdf'));
    expect(await result.file.readAsBytes(), pdf);
  });

  test('sem programa para imprimir PDF, abre o arquivo; sem nada, fica guardado', () async {
    final opened = await WindowsDanfePrinter(directory, shell: (verb, path) => verb == 'open').print('1', pdf);
    expect(opened.result, DanfeResult.opened);
    final saved = await WindowsDanfePrinter(directory, shell: (verb, path) => false).print('2', pdf);
    expect(saved.result, DanfeResult.saved);
    expect(saved.file.existsSync(), isTrue);
  });
}
