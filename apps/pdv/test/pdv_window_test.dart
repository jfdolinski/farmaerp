import 'dart:io';

import 'package:farmaerp_pdv/ui/caps.dart' as pdv;
import 'package:farmaerp_pdv/ui/keys_hint.dart';
import 'package:farmaerp_pdv/ui/pdv_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Moldura única das janelas internas do PDV.
void main() {
  Future<void> open(WidgetTester tester, WidgetBuilder builder, {Size surface = const Size(1500, 1000)}) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(onPressed: () => showDialog<void>(context: context, builder: builder), child: const Text('abrir')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  final frame = find.byKey(const Key('pdv-window-frame'));

  testWidgets('grande: 80% da largura e da altura, centralizada, com título, apoio e etiquetas', (tester) async {
    await open(tester, (_) => const PdvWindow(title: 'Extrato', subtitle: 'Maria', tags: ['Código 7'], content: Text('corpo')));
    expect(tester.getSize(frame), const Size(1200, 800));
    expect(tester.getCenter(frame), const Offset(750, 500));
    expect(find.text('EXTRATO'), findsOneWidget);
    expect(find.text('MARIA'), findsOneWidget);
    expect(find.text('CÓDIGO 7'), findsOneWidget);

    await open(tester, (_) => const PdvWindow(title: 'Extrato', content: Text('corpo')), surface: const Size(1000, 700));
    expect(tester.getSize(frame), const Size(800, 560));
  });

  testWidgets('compacta: largura fixa e altura do conteúdo', (tester) async {
    await open(tester, (_) => const PdvWindow(size: PdvWindowSize.compact, title: 'Cancelar', content: Text('pergunta')));
    final size = tester.getSize(frame);
    expect(size.width, PdvWindow.compactWidth);
    expect(size.height, lessThan(300));
  });

  testWidgets('conteúdo comprido rola dentro da janela, sem passar dos 80%', (tester) async {
    await open(
      tester,
      (_) => PdvWindow(
        size: PdvWindowSize.compact,
        title: 'Lista',
        content: Column(children: [for (var i = 0; i < 80; i += 1) Text('linha $i')]),
      ),
    );
    expect(tester.getSize(frame).height, 800);
    expect(tester.takeException(), isNull);
  });

  testWidgets('o X e o Esc fecham', (tester) async {
    await open(tester, (_) => const PdvWindow(title: 'Consulta', content: Text('corpo')));
    await tester.tap(find.byKey(const Key('pdv-window-close')));
    await tester.pumpAndSettle();
    expect(frame, findsNothing);

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
  });

  testWidgets('rodapé: as teclas à esquerda, os botões à direita e o principal por último', (tester) async {
    await open(
      tester,
      (context) => PdvWindow(
        title: 'Sangria',
        content: const Text('corpo'),
        actions: [
          const KeysHint(),
          TextButton(key: const Key('cancel'), onPressed: () {}, child: const Text('Cancelar')),
          FilledButton(key: const Key('confirm'), onPressed: () {}, child: const Text('Confirmar')),
        ],
      ),
    );
    final box = tester.getRect(frame);
    final hint = tester.getRect(find.byKey(const Key('keys-hint')));
    final cancel = tester.getRect(find.byKey(const Key('cancel')));
    final confirm = tester.getRect(find.byKey(const Key('confirm')));
    expect(hint.left - box.left, lessThan(60));
    expect(box.right - confirm.right, lessThan(60));
    expect(cancel.right, lessThanOrEqualTo(confirm.left));
    expect(hint.right, lessThan(cancel.left));
  });

  testWidgets('Enter no último campo aciona o botão principal', (tester) async {
    var confirmed = 0;
    await open(
      tester,
      (context) => PdvWindow(
        title: 'Lançamento',
        content: Column(children: [
          pdv.TextField(key: const Key('a'), autofocus: true, controller: TextEditingController()),
          pdv.TextField(key: const Key('b'), controller: TextEditingController()),
        ]),
        actions: [FilledButton(onPressed: () => confirmed += 1, child: const Text('Salvar'))],
      ),
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(confirmed, 1);
  });

  test('toda janela do PDV usa a moldura padrão', () {
    final others = RegExp(r'\b(AlertDialog|SimpleDialog|Dialog\.fullscreen)\(');
    final found = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart') || entity.path.endsWith('pdv_window.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i += 1) {
        if (others.hasMatch(lines[i])) found.add('${entity.path}:${i + 1}');
      }
    }
    expect(found, isEmpty, reason: 'Use PdvWindow nas janelas do PDV.');
  });
}
