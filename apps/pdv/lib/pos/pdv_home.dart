import 'dart:io';

import 'package:flutter/material.dart';

import '../face/face_service.dart';
import '../local/local_database.dart';
import '../terminal/terminal_controller.dart';
import '../terminal/terminal_screen.dart';
import 'display_settings.dart';
import 'pos_controller.dart';
import 'pos_screen.dart';
import 'receipt.dart';
import 'windows_printer.dart';

/// Configuração da impressora guardada no banco local: `pdf` ou `escpos:` + o nome da impressora no Windows.
const printerSetting = 'printer';

/// Impressora configurada neste terminal. Sem configuração, o comprovante vai para PDF.
ReceiptPrinter configuredPrinter(LocalDatabase database, Directory pdfDirectory) {
  final value = database.setting(printerSetting);
  if (value != null && value.startsWith('escpos:')) return WindowsEscPosPrinter(value.substring('escpos:'.length));
  return PdfReceiptPrinter(pdfDirectory);
}

/// Tela inicial: o caixa abre quando o terminal está aprovado e a carga inicial terminou. Antes
/// disso (ou se o terminal for bloqueado), fica a tela do terminal.
class PdvHome extends StatelessWidget {
  const PdvHome({
    super.key,
    required this.terminal,
    required this.pos,
    required this.database,
    this.listPrinters = windowsPrinters,
    this.display,
    this.appVersion,
    this.face,
  });

  final TerminalController terminal;
  final PosController pos;
  final LocalDatabase database;
  final DisplaySettings? display;
  final String? appVersion;
  final List<String> Function() listPrinters;

  /// Rosto (só no Windows por enquanto).
  final FaceService? face;

  @override
  Widget build(BuildContext context) {
    final sync = terminal.sync;
    return ListenableBuilder(
      listenable: Listenable.merge([terminal, ?sync]),
      builder: (context, _) {
        final ready = terminal.phase == TerminalPhase.ready && (sync?.initialLoadDone ?? false);
        if (!ready) return TerminalScreen(controller: terminal);
        return PosScreen(
          controller: pos,
          online: terminal.online,
          appVersion: appVersion,
          face: face,
          onDisplaySettings: display == null ? null : () => showDisplaySettings(context, display!),
          onPrinterSettings: () async {
            final choice = await choosePrinter(context, printers: listPrinters(), current: database.setting(printerSetting));
            if (choice != null) database.setSetting(printerSetting, choice);
          },
        );
      },
    );
  }
}
