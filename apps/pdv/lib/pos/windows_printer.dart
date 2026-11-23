import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'receipt.dart';

/// Impressoras instaladas no Windows (fila de impressão). Fora do Windows, lista vazia.
List<String> windowsPrinters() {
  if (!Platform.isWindows) return const [];
  return using((arena) {
    final needed = arena<Uint32>();
    final returned = arena<Uint32>();
    const flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;
    EnumPrinters(flags, null, 4, null, 0, needed, returned);
    if (needed.value == 0) return const <String>[];
    final buffer = arena<Uint8>(needed.value);
    if (!EnumPrinters(flags, null, 4, buffer, needed.value, needed, returned).value) return const <String>[];
    final infos = buffer.cast<PRINTER_INFO_4>();
    return [for (var i = 0; i < returned.value; i += 1) (infos + i).ref.pPrinterName.toDartString()];
  });
}

/// Manda os comandos ESC/POS direto para a fila da impressora térmica (tipo RAW).
class WindowsEscPosPrinter implements ReceiptPrinter {
  WindowsEscPosPrinter(this.printerName);

  final String printerName;

  @override
  String get description => printerName;

  @override
  Future<void> print(String saleCode, List<ReceiptLine> lines) async {
    final data = encodeEscPos(lines);
    using((arena) {
      final handlePointer = arena<Pointer>();
      if (!OpenPrinter(printerName.toPcwstr(allocator: arena), handlePointer, null).value) {
        throw StateError('Impressora não encontrada: $printerName');
      }
      final handle = PRINTER_HANDLE(handlePointer.value);
      try {
        final info = arena<DOC_INFO_1>();
        info.ref
          ..pDocName = PWSTR('Venda $saleCode'.toNativeUtf16(allocator: arena))
          ..pOutputFile = PWSTR(nullptr)
          ..pDatatype = PWSTR('RAW'.toNativeUtf16(allocator: arena));
        if (StartDocPrinter(handle, 1, info) == 0) throw StateError('Falha ao abrir o trabalho de impressão');
        try {
          if (!StartPagePrinter(handle)) throw StateError('Falha ao abrir a página');
          final bytes = arena<Uint8>(data.length);
          bytes.asTypedList(data.length).setAll(0, data);
          final written = arena<Uint32>();
          if (!WritePrinter(handle, bytes, data.length, written) || written.value != data.length) {
            throw StateError('A impressora não recebeu o comprovante inteiro');
          }
          EndPagePrinter(handle);
        } finally {
          EndDocPrinter(handle);
        }
      } finally {
        ClosePrinter(handle);
      }
    });
  }
}
