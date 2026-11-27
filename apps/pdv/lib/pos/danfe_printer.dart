import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// O que aconteceu com o DANFE A4: impresso (mandado à impressora padrão), aberto na tela para
/// imprimir à mão, ou só guardado (fora do Windows, ou nem abrir deu certo).
enum DanfeResult { printed, opened, saved }

/// Imprime o DANFE A4 da NF-e de venda. Separado para os testes.
abstract class DanfePrinter {
  /// Guarda uma cópia e manda imprimir. O caminho da cópia volta junto.
  Future<({DanfeResult result, File file})> print(String accessKey, Uint8List pdf);
}

/// Pede ao Windows para imprimir o PDF com o programa de PDF instalado (o verbo "print" do
/// ShellExecute, na impressora padrão), sem pacote novo. Se o Windows não tiver programa para
/// imprimir PDF, abre o arquivo para o operador imprimir. A cópia fica na pasta do caixa.
class WindowsDanfePrinter implements DanfePrinter {
  WindowsDanfePrinter(this.directory, {this.shell = _shellExecute});

  final Directory directory;

  /// Chamada ao Windows (verbo e arquivo); devolve se deu certo. Trocável nos testes.
  final bool Function(String verb, String path) shell;

  @override
  Future<({DanfeResult result, File file})> print(String accessKey, Uint8List pdf) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}DANFE-$accessKey.pdf');
    await file.writeAsBytes(pdf, flush: true);
    if (!Platform.isWindows && shell == _shellExecute) return (result: DanfeResult.saved, file: file);
    if (shell('print', file.path)) return (result: DanfeResult.printed, file: file);
    if (shell('open', file.path)) return (result: DanfeResult.opened, file: file);
    return (result: DanfeResult.saved, file: file);
  }
}

/// ShellExecute: acima de 32 é sucesso.
bool _shellExecute(String verb, String path) => using((arena) {
  // Imprimir não mostra janela; abrir mostra o PDF para o operador.
  final show = verb == 'open' ? SW_SHOWNORMAL : SW_HIDE;
  final result = ShellExecute(null, verb.toPcwstr(allocator: arena), path.toPcwstr(allocator: arena), null, null, show);
  return result.address > 32;
});
