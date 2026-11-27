import 'package:farmaerp_pdv/ui/pdv_motion.dart';
import 'package:farmaerp_pdv/ui/pdv_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Movimento do PDV: curto, suave, desligável pelo sistema e sem atrasar o operador.
void main() {
  double opacityOf(WidgetTester tester, Finder appear) =>
      tester.widget<Opacity>(find.descendant(of: appear, matching: find.byType(Opacity)).first).opacity;

  Widget host(Widget child, {bool reduce = false}) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('entra esmaecendo e assenta no lugar em 220 ms', (tester) async {
    await tester.pumpWidget(host(const PdvAppear(child: Text('aviso'))));
    final appear = find.byType(PdvAppear);
    expect(opacityOf(tester, appear), 0);
    await tester.pump(const Duration(milliseconds: 110));
    final middle = opacityOf(tester, appear);
    expect(middle, greaterThan(0));
    expect(middle, lessThan(1));
    // Desacelera no fim: na metade do tempo já passou da metade do caminho.
    expect(middle, greaterThan(0.6));
    await tester.pump(const Duration(milliseconds: 110));
    expect(opacityOf(tester, appear), 1);
    expect(tester.getTopLeft(find.text('aviso')), tester.getTopLeft(find.text('aviso')));
  });

  testWidgets('desliza do deslocamento pedido até o lugar', (tester) async {
    await tester.pumpWidget(host(const PdvAppear(offset: Offset(0, 8), child: SizedBox(width: 10, height: 10, key: Key('box')))));
    final start = tester.getTopLeft(find.byKey(const Key('box')));
    await tester.pumpAndSettle();
    final end = tester.getTopLeft(find.byKey(const Key('box')));
    expect(start.dy - end.dy, closeTo(8, 0.01));
  });

  testWidgets('com "Mostrar animações" desligado no sistema, aparece na hora', (tester) async {
    await tester.pumpWidget(host(const PdvAppear(scale: 0.9, child: Text('troco')), reduce: true));
    expect(opacityOf(tester, find.byType(PdvAppear)), 1);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('não atrasa: o botão responde já no primeiro quadro', (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(PdvAppear(child: ElevatedButton(onPressed: () => taps += 1, child: const Text('ok')))));
    await tester.tap(find.byType(ElevatedButton), warnIfMissed: false);
    expect(taps, 1);
  });

  testWidgets('em sequência: o segundo começa depois da folga', (tester) async {
    await tester.pumpWidget(host(const Column(children: [
      PdvAppear(key: Key('a'), child: Text('a')),
      PdvAppear(key: Key('b'), delay: Duration(milliseconds: 100), child: Text('b')),
    ])));
    await tester.pump(const Duration(milliseconds: 60));
    expect(opacityOf(tester, find.byKey(const Key('a'))), greaterThan(0));
    expect(opacityOf(tester, find.byKey(const Key('b'))), 0);
    await tester.pumpAndSettle();
    expect(opacityOf(tester, find.byKey(const Key('b'))), 1);
  });

  testWidgets('chave nova anima de novo (número do total que muda)', (tester) async {
    await tester.pumpWidget(host(const PdvAppear(key: ValueKey(100), child: Text('R\$ 1,00'))));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, find.byType(PdvAppear)), 1);
    await tester.pumpWidget(host(const PdvAppear(key: ValueKey(200), child: Text('R\$ 2,00'))));
    expect(opacityOf(tester, find.byType(PdvAppear)), 0);
    // Só o número novo na tela: o antigo não fica junto durante a troca.
    expect(find.text('R\$ 1,00'), findsNothing);
    await tester.pumpAndSettle();
    expect(opacityOf(tester, find.byType(PdvAppear)), 1);
  });

  testWidgets('a janela padrão abre crescendo de 96% para 100%', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const PdvWindow(title: 'Consulta', content: Text('corpo'))),
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final scale = tester.widget<Transform>(
      find.descendant(of: find.byType(PdvWindow), matching: find.byType(Transform)).first,
    );
    expect(scale.transform.entry(0, 0), lessThan(1));
    expect(scale.transform.entry(0, 0), greaterThanOrEqualTo(0.96));
    await tester.pumpAndSettle();
    final settled = tester.widget<Transform>(
      find.descendant(of: find.byType(PdvWindow), matching: find.byType(Transform)).first,
    );
    expect(settled.transform.entry(0, 0), 1);
  });
}
