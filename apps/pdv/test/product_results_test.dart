import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:farmaerp_pdv/pos/product_results.dart';

/// Lista da busca por nome: 10 linhas e a escolhida sempre à vista.
void main() {
  final products = [
    for (var i = 1; i <= 25; i += 1)
      SaleProduct(id: 'p$i', code: i, name: 'Produto $i', status: 'active', priceCents: 1000, stockMilli: 1000, fractionMilli: 1000),
  ];

  Widget host(int highlight, {int visibleRows = 10, List<SaleProduct>? results}) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ProductResults(
          results: results ?? products,
          highlight: highlight,
          visibleRows: visibleRows,
          onPick: (_) {},
          onInfo: (_) {},
          onNetwork: (_) {},
        ),
      ),
    ),
  );

  /// A linha aparece inteira dentro da lista.
  bool shown(WidgetTester tester, int code) {
    final row = find.byKey(Key('result-$code'));
    if (row.evaluate().isEmpty) return false;
    final list = tester.getRect(find.byType(ListView));
    final rect = tester.getRect(row);
    return rect.top >= list.top - 0.5 && rect.bottom <= list.bottom + 0.5;
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('mostra 10 linhas; com menos resultados, só o que tem', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(0));
    expect(tester.getSize(find.byType(ListView)).height, 10 * ProductResults.rowHeight);
    for (var code = 1; code <= 10; code += 1) {
      expect(shown(tester, code), isTrue, reason: 'linha $code');
    }
    expect(shown(tester, 11), isFalse);

    await tester.pumpWidget(host(0, results: products.take(4).toList()));
    expect(tester.getSize(find.byType(ListView)).height, 4 * ProductResults.rowHeight);
  });

  testWidgets('busca nova volta a lista para o começo', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(0));
    await tester.pumpWidget(host(20));
    await tester.pump();
    expect(shown(tester, 21), isTrue);
    await tester.pumpWidget(host(0, results: products.reversed.toList()));
    await tester.pump();
    expect(shown(tester, 25), isTrue);
  });

  testWidgets('descendo e subindo com as setas, a linha escolhida não some', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (var index = 0; index < products.length; index += 1) {
      await tester.pumpWidget(host(index));
      await tester.pump();
      expect(shown(tester, index + 1), isTrue, reason: 'descendo até ${index + 1}');
    }
    for (var index = products.length - 1; index >= 0; index -= 1) {
      await tester.pumpWidget(host(index));
      await tester.pump();
      expect(shown(tester, index + 1), isTrue, reason: 'subindo até ${index + 1}');
    }
  });
}
