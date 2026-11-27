import 'package:farmaerp_pdv/local/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unidade de medida do produto: desce da central, fica no banco local e vai para a NFC-e.
void main() {
  PullItem product(String id, int code, Object? unit) => PullItem(
    type: 'product',
    id: id,
    data: {
      'code': code, 'name': 'Produto $code', 'status': 'active', 'price': 10, 'fraction_quantity': 1, 'batch_required': false,
      'ncm': '30049099',
      'unit': ?unit,
      'barcodes': const [],
      'taxes': const [],
    },
  );

  test('a unidade desce com o produto; central antiga ou sigla estranha ficam UN', () {
    final database = LocalDatabase.inMemory();
    const kg = '019a0000-0000-7000-8000-000000000101';
    const none = '019a0000-0000-7000-8000-000000000102';
    const odd = '019a0000-0000-7000-8000-000000000103';
    database.applyPage(PullPage(format: 3, until: '1', items: [product(kg, 101, ' kg '), product(none, 102, null), product(odd, 103, 'X-1')]),
        now: DateTime(2026, 11, 27));
    final day = DateTime(2026, 11, 27);
    expect(database.nfceProductData(kg, day)!.unit, 'KG');
    expect(database.nfceProductData(none, day)!.unit, 'UN');
    expect(database.nfceProductData(odd, day)!.unit, 'UN');
    expect(database.productDetails(kg)!['unit'], 'KG');

    // Mudou a unidade na central: a próxima carga troca.
    database.applyPage(PullPage(format: 3, until: '2', items: [product(kg, 101, 'CX')]), now: DateTime(2026, 11, 27));
    expect(database.nfceProductData(kg, day)!.unit, 'CX');
    database.close();
  });
}
